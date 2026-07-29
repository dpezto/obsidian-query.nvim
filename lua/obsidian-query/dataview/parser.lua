-- DQL recursive-descent parser.
--
-- query    := header command*
-- header   := TABLE [WITHOUT ID] [field ("," field)*] | LIST [WITHOUT ID] [expr]
--           | TASK | CALENDAR
-- field    := expr [AS (STRING|IDENT)]
-- command  := FROM source | WHERE expr | SORT key ("," key)* | GROUP BY expr [AS x]
--           | FLATTEN expr [AS x] | LIMIT expr        (kept in written order)
-- source   := s_or ; s_or := s_and (OR s_and)* ; s_and := s_un (AND s_un)*
-- s_un     := ("-"|"!")? s_atom
-- s_atom   := TAG | STRING | LINK | outgoing "(" source ")" | "(" source ")"
--
-- expr     := or ; or := and ("|" and)* ; and := cmp ("&" cmp)*
-- cmp      := add (op add)* ; add := mul (("+"|"-") mul)*
-- mul      := un (("*"|"/"|"%") un)* ; un := ("!"|"-") un | postfix
-- postfix  := primary ("." IDENT | "[" expr "]" | "(" args ")")*
-- primary  := NUMBER | STRING | true|false|null | LINK | "[" list "]"
--           | lambda | "(" expr ")" | IDENT
local lexer = require("obsidian-query.dataview.lexer")

local M = {}

local KEYWORDS = {
  TABLE = true, LIST = true, TASK = true, CALENDAR = true,
  WITHOUT = true, ID = true, FROM = true, WHERE = true, SORT = true,
  GROUP = true, BY = true, FLATTEN = true, LIMIT = true, AS = true,
  ASC = true, DESC = true, AND = true, OR = true,
}

local P = {}
P.__index = P

function P:tok()
  return self.toks[self.pos]
end

function P:kw()
  local t = self:tok()
  if t.type == "IDENT" and KEYWORDS[t.text:upper()] then
    return t.text:upper()
  end
end

function P:advance()
  local t = self.toks[self.pos]
  if t.type ~= "EOF" then
    self.pos = self.pos + 1
  end
  return t
end

function P:expect(type_)
  local t = self:tok()
  if t.type ~= type_ then
    self:err(("expected %s, got %q"):format(type_, t.text ~= "" and t.text or t.type))
  end
  return self:advance()
end

function P:err(msg)
  error({ msg = msg, pos = self:tok().pos }, 0)
end

---------------------------------------------------------------- sources

function P:source()
  return self:src_or()
end

function P:src_or()
  local kids = { self:src_and() }
  while self:kw() == "OR" do
    self:advance()
    kids[#kids + 1] = self:src_and()
  end
  return #kids == 1 and kids[1] or { k = "s_or", kids = kids }
end

function P:src_and()
  local kids = { self:src_unary() }
  while self:kw() == "AND" do
    self:advance()
    kids[#kids + 1] = self:src_unary()
  end
  return #kids == 1 and kids[1] or { k = "s_and", kids = kids }
end

function P:src_unary()
  local t = self:tok()
  if t.type == "-" or t.type == "!" then
    self:advance()
    return { k = "s_not", kid = self:src_unary() }
  end
  return self:src_atom()
end

function P:src_atom()
  local t = self:tok()
  if t.type == "TAG" then
    self:advance()
    return { k = "s_tag", tag = t.text:lower() }
  elseif t.type == "STRING" then
    self:advance()
    return { k = "s_folder", folder = t.text }
  elseif t.type == "LINK" then
    self:advance()
    return { k = "s_link", raw = t.text }
  elseif t.type == "IDENT" and t.text:lower() == "outgoing" then
    self:advance()
    self:expect("(")
    local inner = self:expect("LINK")
    self:expect(")")
    return { k = "s_outgoing", raw = inner.text }
  elseif t.type == "(" then
    self:advance()
    local s = self:source()
    self:expect(")")
    return s
  end
  self:err("expected a FROM source (#tag, \"folder\", [[link]], outgoing(...))")
end

---------------------------------------------------------------- expressions

local CMP_OPS = { ["="] = true, ["!="] = true, ["<"] = true, ["<="] = true, [">"] = true, [">="] = true }

function P:expr()
  return self:or_e()
end

function P:or_e()
  local l = self:and_e()
  while self:tok().type == "|" or self:kw() == "OR" do
    self:advance()
    l = { k = "or", l = l, r = self:and_e() }
  end
  return l
end

function P:and_e()
  local l = self:cmp_e()
  while self:tok().type == "&" or self:kw() == "AND" do
    self:advance()
    l = { k = "and", l = l, r = self:cmp_e() }
  end
  return l
end

function P:cmp_e()
  local l = self:add_e()
  while CMP_OPS[self:tok().type] do
    local op = self:advance().type
    l = { k = "cmp", op = op, l = l, r = self:add_e() }
  end
  return l
end

function P:add_e()
  local l = self:mul_e()
  while self:tok().type == "+" or self:tok().type == "-" do
    local op = self:advance().type
    l = { k = "bin", op = op, l = l, r = self:mul_e() }
  end
  return l
end

function P:mul_e()
  local l = self:unary()
  while self:tok().type == "*" or self:tok().type == "/" or self:tok().type == "%" do
    local op = self:advance().type
    l = { k = "bin", op = op, l = l, r = self:unary() }
  end
  return l
end

function P:unary()
  local t = self:tok()
  if t.type == "!" then
    self:advance()
    return { k = "not", e = self:unary() }
  elseif t.type == "-" then
    self:advance()
    return { k = "neg", e = self:unary() }
  end
  return self:postfix()
end

function P:postfix()
  local e = self:primary()
  while true do
    local t = self:tok()
    if t.type == "." then
      self:advance()
      local id = self:expect("IDENT")
      e = { k = "index", obj = e, key = { k = "lit", v = id.text } }
    elseif t.type == "[" then
      self:advance()
      local key = self:expr()
      self:expect("]")
      e = { k = "index", obj = e, key = key }
    elseif t.type == "(" then
      e = self:call(e)
    else
      return e
    end
  end
end

function P:call(fn)
  self:expect("(")
  -- contextual date/dur literal
  if fn.k == "ident" and (fn.name == "date" or fn.name == "dur") then
    local lit, nxt = lexer.try_date_literal(self.toks, self.pos)
    if lit then
      self.pos = nxt
      self:expect(")")
      return { k = "datelit", fn = fn.name, lit = lit }
    end
    if fn.name == "dur" then
      -- bare duration literal: NUMBER IDENT (","? NUMBER IDENT)* — dur(30 days)
      local save, buf = self.pos, {}
      while self:tok().type == "NUMBER" do
        buf[#buf + 1] = self:advance().text
        if self:tok().type ~= "IDENT" then
          buf = nil
          break
        end
        buf[#buf + 1] = self:advance().text
        if self:tok().type == "," then
          self:advance()
        end
      end
      if buf and #buf > 0 and self:tok().type == ")" then
        self:advance()
        return { k = "datelit", fn = "dur", lit = table.concat(buf, " ") }
      end
      self.pos = save
    end
  end
  local args = {}
  if self:tok().type ~= ")" then
    args[#args + 1] = self:expr()
    while self:tok().type == "," do
      self:advance()
      args[#args + 1] = self:expr()
    end
  end
  self:expect(")")
  return { k = "call", fn = fn, args = args }
end

---Lambda disambiguation: "(" IDENT ("," IDENT)* ")" "=>"
function P:try_lambda()
  local save = self.pos
  if self:tok().type ~= "(" then
    return nil
  end
  self:advance()
  local params = {}
  if self:tok().type == "IDENT" then
    params[#params + 1] = self:advance().text
    while self:tok().type == "," and self.toks[self.pos + 1].type == "IDENT" do
      self:advance()
      params[#params + 1] = self:advance().text
    end
  end
  if self:tok().type == ")" and self.toks[self.pos + 1].type == "=>" then
    self:advance()
    self:advance()
    return { k = "lambda", params = params, body = self:expr() }
  end
  self.pos = save
  return nil
end

function P:primary()
  local t = self:tok()
  if t.type == "NUMBER" then
    self:advance()
    return { k = "lit", v = tonumber(t.text) }
  elseif t.type == "STRING" then
    self:advance()
    return { k = "lit", v = t.text }
  elseif t.type == "LINK" then
    self:advance()
    return { k = "link", raw = t.text }
  elseif t.type == "[" then
    self:advance()
    local items = {}
    if self:tok().type ~= "]" then
      items[#items + 1] = self:expr()
      while self:tok().type == "," do
        self:advance()
        items[#items + 1] = self:expr()
      end
    end
    self:expect("]")
    return { k = "list", items = items }
  elseif t.type == "(" then
    local lambda = self:try_lambda()
    if lambda then
      return lambda
    end
    self:advance()
    local e = self:expr()
    self:expect(")")
    return e
  elseif t.type == "IDENT" then
    self:advance()
    local low = t.text:lower()
    if low == "true" then
      return { k = "lit", v = true }
    elseif low == "false" then
      return { k = "lit", v = false }
    elseif low == "null" then
      return { k = "null" }
    end
    return { k = "ident", name = t.text }
  end
  self:err(("expected expression, got %q"):format(t.text ~= "" and t.text or t.type))
end

---------------------------------------------------------------- query

function P:alias()
  if self:kw() == "AS" then
    self:advance()
    local t = self:tok()
    if t.type == "STRING" or t.type == "IDENT" then
      self:advance()
      return t.text
    end
    self:err("expected alias after AS")
  end
end

function P:header()
  local kw = self:kw()
  if kw == "TABLE" then
    self:advance()
    local without_id = false
    if self:kw() == "WITHOUT" then
      self:advance()
      if self:kw() ~= "ID" then
        self:err("expected ID after WITHOUT")
      end
      self:advance()
      without_id = true
    end
    local fields = {}
    if not self:kw() and self:tok().type ~= "EOF" then
      repeat
        local start = self:tok().pos
        local e = self:expr()
        local stop = self:tok().pos
        fields[#fields + 1] = { expr = e, alias = self:alias(), src = vim.trim(self.src:sub(start, stop - 1)) }
      until self:tok().type ~= "," or not self:advance()
    end
    return { kind = "table", without_id = without_id, fields = fields }
  elseif kw == "LIST" then
    self:advance()
    local without_id = false
    if self:kw() == "WITHOUT" then
      self:advance()
      self:advance() -- ID
      without_id = true
    end
    local e
    if not self:kw() and self:tok().type ~= "EOF" then
      e = self:expr()
    end
    return { kind = "list", without_id = without_id, expr = e }
  elseif kw == "TASK" then
    self:advance()
    return { kind = "task" }
  elseif kw == "CALENDAR" then
    self:advance()
    local e
    if not self:kw() and self:tok().type ~= "EOF" then
      e = self:expr() -- date expression; defaults to file.day downstream
    end
    return { kind = "calendar", expr = e }
  end
  self:err("query must start with TABLE, LIST, TASK or CALENDAR")
end

function P:commands()
  local cmds = {}
  while self:tok().type ~= "EOF" do
    local kw = self:kw()
    if kw == "FROM" then
      self:advance()
      cmds[#cmds + 1] = { cmd = "from", src = self:source() }
    elseif kw == "WHERE" then
      self:advance()
      cmds[#cmds + 1] = { cmd = "where", expr = self:expr() }
    elseif kw == "SORT" then
      self:advance()
      local keys = {}
      repeat
        local e = self:expr()
        local dir = "asc"
        local d = self:kw()
        if d == "ASC" or d == "DESC" then
          self:advance()
          dir = d:lower()
        end
        keys[#keys + 1] = { expr = e, dir = dir }
      until self:tok().type ~= "," or not self:advance()
      cmds[#cmds + 1] = { cmd = "sort", keys = keys }
    elseif kw == "GROUP" then
      self:advance()
      if self:kw() ~= "BY" then
        self:err("expected BY after GROUP")
      end
      self:advance()
      cmds[#cmds + 1] = { cmd = "group", expr = self:expr(), alias = self:alias() }
    elseif kw == "FLATTEN" then
      self:advance()
      local start = self:tok().pos
      local e = self:expr()
      local stop = self:tok().pos
      cmds[#cmds + 1] =
        { cmd = "flatten", expr = e, alias = self:alias(), src = vim.trim(self.src:sub(start, stop - 1)) }
    elseif kw == "LIMIT" then
      self:advance()
      cmds[#cmds + 1] = { cmd = "limit", expr = self:expr() }
    else
      self:err(("unexpected %q — expected FROM/WHERE/SORT/GROUP BY/FLATTEN/LIMIT"):format(self:tok().text))
    end
  end
  return cmds
end

---Bare expression (inline `= expr` queries). nil on any error/trailing input.
---@param src string
---@return table? ast
function M.parse_expr(src)
  local toks = lexer.tokenize(src)
  if not toks then
    return nil
  end
  local p = setmetatable({ toks = toks, pos = 1, src = src }, P)
  local ok, ast = pcall(function()
    local e = p:expr()
    if p:tok().type ~= "EOF" then
      error({ msg = "trailing input" }, 0)
    end
    return e
  end)
  return ok and ast or nil
end

---@param src string
---@return table? query {header, commands}
---@return {msg: string, pos: integer}? err
function M.parse(src)
  local toks, lerr = lexer.tokenize(src)
  if not toks then
    return nil, { msg = lerr, pos = 1 }
  end
  local p = setmetatable({ toks = toks, pos = 1, src = src }, P)
  local ok, res = pcall(function()
    local header = p:header()
    local commands = p:commands()
    return { header = header, commands = commands }
  end)
  if not ok then
    if type(res) == "table" and res.msg then
      return nil, res
    end
    return nil, { msg = tostring(res), pos = 1 }
  end
  return res
end

return M
