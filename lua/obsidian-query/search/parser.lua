-- Obsidian core-Search query grammar -> AST.
--
--   expr    := or ; or := and ("OR" and)* ; and := unary+   (implicit AND)
--   unary   := "-" unary | atom
--   atom    := "(" expr ")" | operator | [prop] | [prop:value]
--            | /regex/flags | "phrase" | word
--   operator:= name ":" ( "(" expr ")" | /regex/ | "phrase" | word )
--
-- AST nodes: {k="and"|"or", kids}, {k="not", kid},
--   {k="word"|"phrase", text}, {k="regex", pat, flags},
--   {k="op", name, arg}, {k="prop", name, value?}
local M = {}

local OPS = {
  file = true,
  path = true,
  content = true,
  tag = true,
  line = true,
  section = true,
  block = true,
  task = true,
  ["task-todo"] = true,
  ["task-done"] = true,
  ["match-case"] = true,
  ["ignore-case"] = true,
}

---Tokens carry byte spans (pos/fin, 1-based inclusive) for the highlighter.
---@return table[]? toks
---@return string? err
local function lex(src)
  local toks, i, n = {}, 1, #src
  while i <= n do
    local c = src:sub(i, i)
    if c:match("%s") then
      i = i + 1
    elseif c == "(" or c == ")" then
      toks[#toks + 1] = { t = c, pos = i, fin = i }
      i = i + 1
    elseif c == "-" then
      toks[#toks + 1] = { t = "-", pos = i, fin = i }
      i = i + 1
    elseif c == '"' then
      local j, buf = i + 1, {}
      while j <= n do
        local ch = src:sub(j, j)
        if ch == "\\" and src:sub(j + 1, j + 1) == '"' then
          buf[#buf + 1] = '"'
          j = j + 2
        elseif ch == '"' then
          break
        else
          buf[#buf + 1] = ch
          j = j + 1
        end
      end
      if j > n then
        return nil, "unterminated phrase"
      end
      toks[#toks + 1] = { t = "phrase", s = table.concat(buf), pos = i, fin = j }
      i = j + 1
    elseif c == "/" then
      local j, buf = i + 1, {}
      while j <= n do
        local ch = src:sub(j, j)
        if ch == "\\" and src:sub(j + 1, j + 1) == "/" then
          buf[#buf + 1] = "/"
          j = j + 2
        elseif ch == "/" then
          break
        else
          buf[#buf + 1] = ch
          j = j + 1
        end
      end
      if j > n then
        return nil, "unterminated /regex/"
      end
      local flags = src:match("^%a*", j + 1)
      toks[#toks + 1] = { t = "regex", s = table.concat(buf), flags = flags, pos = i, fin = j + #flags }
      i = j + 1 + #flags
    elseif c == "[" then
      local inner, rest = src:match("^%[([^%]]*)%]()", i)
      if not inner then
        return nil, "unterminated [property]"
      end
      local name, value = inner:match("^([^:]+):(.*)$")
      name = name or inner
      if value then
        value = value:gsub('^"(.*)"$', "%1")
      end
      toks[#toks + 1] = { t = "prop", name = vim.trim(name), value = value, pos = i, fin = rest - 1 }
      i = rest
    else
      -- word: everything up to whitespace/parens/quote; '/' stays word-internal
      -- (regex only when a token *starts* with '/'), so path:Journal/sub works
      local start = i
      local w = src:match('^[^%s%(%)"]+', i)
      i = i + #w
      local op = w:match("^([%w%-]+):$")
      local opname, rest = w:match("^([%w%-]+):(.+)$")
      if op and OPS[op:lower()] then
        toks[#toks + 1] = { t = "op", name = op:lower(), pos = start, fin = i - 1 }
      elseif opname and OPS[opname:lower()] then
        toks[#toks + 1] = { t = "op", name = opname:lower(), pos = start, fin = start + #opname }
        toks[#toks + 1] = { t = "word", s = rest, pos = start + #opname + 1, fin = i - 1 }
      elseif w == "OR" then
        toks[#toks + 1] = { t = "OR", pos = start, fin = i - 1 }
      else
        toks[#toks + 1] = { t = "word", s = w, pos = start, fin = i - 1 }
      end
    end
  end
  return toks
end

local Parser = {}
Parser.__index = Parser

function Parser:peek()
  return self.toks[self.pos]
end

function Parser:next()
  local tok = self.toks[self.pos]
  self.pos = self.pos + 1
  return tok
end

function Parser:expr()
  local kids = { self:and_expr() }
  while self:peek() and self:peek().t == "OR" do
    self:next()
    kids[#kids + 1] = self:and_expr()
  end
  return #kids == 1 and kids[1] or { k = "or", kids = kids }
end

function Parser:and_expr()
  local kids = {}
  while true do
    local tok = self:peek()
    if not tok or tok.t == ")" or tok.t == "OR" then
      break
    end
    kids[#kids + 1] = self:unary()
  end
  if #kids == 0 then
    error("expected a term", 0)
  end
  return #kids == 1 and kids[1] or { k = "and", kids = kids }
end

function Parser:unary()
  if self:peek().t == "-" then
    self:next()
    return { k = "not", kid = self:unary() }
  end
  return self:atom()
end

function Parser:atom()
  local tok = self:next()
  if not tok then
    error("unexpected end of query", 0)
  elseif tok.t == "(" then
    local e = self:expr()
    local close = self:next()
    if not close or close.t ~= ")" then
      error("missing )", 0)
    end
    return e
  elseif tok.t == "word" then
    return { k = "word", text = tok.s }
  elseif tok.t == "phrase" then
    return { k = "phrase", text = tok.s }
  elseif tok.t == "regex" then
    return { k = "regex", pat = tok.s, flags = tok.flags }
  elseif tok.t == "prop" then
    return { k = "prop", name = tok.name, value = tok.value }
  elseif tok.t == "op" then
    local nxt = self:peek()
    if not nxt then
      error(tok.name .. ": missing argument", 0)
    end
    local arg
    if nxt.t == "(" then
      self:next()
      -- empty group (task:()) or immediate ')' -> match-anything argument
      if self:peek() and self:peek().t == ")" then
        self:next()
        arg = { k = "phrase", text = "" }
      else
        arg = self:expr()
        local close = self:next()
        if not close or close.t ~= ")" then
          error("missing ) after " .. tok.name .. ":(", 0)
        end
      end
    else
      arg = self:atom()
    end
    return { k = "op", name = tok.name, arg = arg }
  end
  error("unexpected " .. tok.t, 0)
end

M.lex = lex -- consumed by obsidian-query.highlight

---@param src string query fence body
---@return table? ast
---@return string? err
function M.parse(src)
  local toks, lerr = lex(src)
  if not toks then
    return nil, lerr
  end
  if #toks == 0 then
    return nil, "empty query"
  end
  local p = setmetatable({ toks = toks, pos = 1 }, Parser)
  local ok, ast = pcall(p.expr, p)
  if not ok then
    return nil, ast:gsub("^.-: ", "")
  end
  if p:peek() then
    return nil, "unexpected " .. (p:peek().s or p:peek().t)
  end
  return ast
end

---Does the AST contain content-matching leaves (drives matched-line display)?
function M.has_content(ast)
  if ast.k == "word" or ast.k == "phrase" or ast.k == "regex" then
    return true
  elseif ast.k == "and" or ast.k == "or" then
    for _, kid in ipairs(ast.kids) do
      if M.has_content(kid) then
        return true
      end
    end
  elseif ast.k == "not" then
    return false -- negated terms produce no display lines
  elseif ast.k == "op" then
    local n = ast.name
    return n == "content" or n == "line" or n == "section" or n == "block"
      or n == "task" or n == "task-todo" or n == "task-done"
      or n == "match-case" or n == "ignore-case"
  end
  return false
end

return M
