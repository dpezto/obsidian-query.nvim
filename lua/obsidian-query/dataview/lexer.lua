-- DQL tokenizer. Emits IDENT for keywords (parser classifies case-insensitively
-- so `where` stays usable as a field name). Contextual date/dur literals are
-- handled by the parser via M.try_date_literal.
local M = {}

---@class dv.Token
---@field type string
---@field text string
---@field pos integer 1-based byte offset

local TWO = { ["!="] = true, ["<="] = true, [">="] = true, ["=>"] = true }
local ONE = {
  ["+"] = true, ["-"] = true, ["*"] = true, ["/"] = true, ["%"] = true,
  ["="] = true, ["<"] = true, [">"] = true, ["&"] = true, ["|"] = true,
  ["!"] = true, ["("] = true, [")"] = true, ["["] = true, ["]"] = true,
  [","] = true, ["."] = true,
  -- only meaningful inside date(...) time literals; a stray ':' elsewhere
  -- becomes a parse error, which is the right message anyway
  [":"] = true,
}

-- word chars incl. multibyte UTF-8 (accented tags/fields: #día, café)
local function is_word(ch)
  return ch ~= "" and (ch:match("[%w_]") ~= nil or ch:byte() >= 0x80)
end

---@param src string
---@return dv.Token[]? toks
---@return string? err
function M.tokenize(src)
  local toks, i, n = {}, 1, #src
  local function push(type_, text, pos, fin)
    toks[#toks + 1] = { type = type_, text = text, pos = pos, fin = fin or pos }
  end
  while i <= n do
    local c = src:sub(i, i)
    local two = src:sub(i, i + 1)
    if c:match("%s") then
      i = i + 1
    elseif two == "[[" then
      local close = src:find("]]", i + 2, true)
      if not close then
        return nil, "unterminated [[link]] at " .. i
      end
      push("LINK", src:sub(i + 2, close - 1), i, close + 1)
      i = close + 2
    elseif c == '"' or c == "'" then
      local j, buf = i + 1, {}
      while j <= n do
        local ch = src:sub(j, j)
        if ch == "\\" then
          local nxt = src:sub(j + 1, j + 1)
          local esc = ({ n = "\n", t = "\t", ["\\"] = "\\", ['"'] = '"', ["'"] = "'" })[nxt]
          buf[#buf + 1] = esc or nxt
          j = j + 2
        elseif ch == c then
          break
        else
          buf[#buf + 1] = ch
          j = j + 1
        end
      end
      if j > n then
        return nil, "unterminated string at " .. i
      end
      push("STRING", table.concat(buf), i, j)
      i = j + 1
    elseif c == "#" then
      local j = i + 1
      while j <= n and (is_word(src:sub(j, j)) or src:sub(j, j) == "/" or src:sub(j, j) == "-") do
        j = j + 1
      end
      if j == i + 1 then
        return nil, "bad tag at " .. i
      end
      push("TAG", src:sub(i + 1, j - 1), i, j - 1)
      i = j
    elseif c:match("%d") then
      local num = src:match("^%d+%.?%d*", i)
      push("NUMBER", num, i, i + #num - 1)
      i = i + #num
    elseif is_word(c) then
      -- kebab identifiers: '-' consumed only when followed by a word char,
      -- so `due-date` is one IDENT but `a - b` / `a -b` stay subtraction
      local j = i
      while j <= n do
        local ch = src:sub(j, j)
        if is_word(ch) then
          j = j + 1
        elseif ch == "-" and is_word(src:sub(j + 1, j + 1)) then
          j = j + 2
        else
          break
        end
      end
      push("IDENT", src:sub(i, j - 1), i, j - 1)
      i = j
    elseif TWO[two] then
      push(two, two, i, i + 1)
      i = i + 2
    elseif ONE[c] then
      push(c, c, i, i)
      i = i + 1
    else
      return nil, ("unexpected character %q at %d"):format(c, i)
    end
  end
  push("EOF", "", n + 1)
  return toks
end

local DATE_KEYWORDS = {
  now = true, today = true, tomorrow = true, yesterday = true,
  sow = true, eow = true, som = true, eom = true, soy = true, eoy = true,
}

---Contextual date literal: called by the parser inside date(...) / dur(...).
---Returns the literal text when the tokens starting at `pos` form one.
---@param toks dv.Token[]
---@param pos integer index into toks
---@return string? literal, integer? next_pos
function M.try_date_literal(toks, pos)
  local t = toks[pos]
  if t.type == "IDENT" and DATE_KEYWORDS[t.text:lower()] and toks[pos + 1].type == ")" then
    return t.text:lower(), pos + 1
  end
  -- yyyy-MM-dd[THH:mm[:ss]] lexes as NUMBER("yyyy") IDENT?/-... — easiest is
  -- to re-scan the raw source region; instead match the common shapes:
  -- NUMBER "-" NUMBER "-" NUMBER, optionally IDENT starting with T…
  if t.type == "NUMBER" and #t.text == 4 and toks[pos + 1].type == "-" then
    -- reconstruct from token texts until ")"
    local buf, j = {}, pos
    while toks[j] and toks[j].type ~= ")" and toks[j].type ~= "EOF" do
      buf[#buf + 1] = toks[j].text
      j = j + 1
    end
    local lit = table.concat(buf)
    if lit:match("^%d%d%d%d%-%d%d%-%d%d") then
      return lit, j
    end
  end
  return nil
end

return M
