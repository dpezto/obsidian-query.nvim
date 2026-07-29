-- PCRE-ish -> vim very-magic translator, shared by the search engine's
-- /regex/ leaves and the dataview regex functions. Gets alternation,
-- quantifiers, {n,m}, character classes, \d\w\s\b, non-capturing groups and
-- all four lookarounds ((?=/?!/?<=/?<!) -> (...)@=/@!/@<=/@<!). Not full
-- PCRE: backrefs inside the pattern, inline flags and named groups are out.
local M = {}

---@param pat string PCRE-ish pattern
---@return string? vimpat very-magic body (no \v prefix), nil if untranslatable
function M.to_vim(pat)
  local out, i, n = {}, 1, #pat
  local stack = {} ---@type string[] "(" | lookaround suffix
  while i <= n do
    local c = pat:sub(i, i)
    if c == "\\" then
      local nxt = pat:sub(i + 1, i + 1)
      if nxt == "b" then
        out[#out + 1] = "(<|>)" -- either word boundary
      elseif nxt == "B" then
        return nil
      else
        -- \d \w \s \S \W \D \n \t and escaped literals pass through
        out[#out + 1] = "\\" .. nxt
      end
      i = i + 2
    elseif c == "[" then
      -- copy the class verbatim (handle leading ^/] and escapes)
      local j = i + 1
      if pat:sub(j, j) == "^" then
        j = j + 1
      end
      if pat:sub(j, j) == "]" then
        j = j + 1
      end
      while j <= n and pat:sub(j, j) ~= "]" do
        j = j + (pat:sub(j, j) == "\\" and 2 or 1)
      end
      if j > n then
        return nil
      end
      out[#out + 1] = pat:sub(i, j)
      i = j + 1
    elseif c == "(" then
      local look = pat:match("^%(%?(<?[=!])", i)
      if look then
        local suffix = ({ ["="] = ")@=", ["!"] = ")@!", ["<="] = ")@<=", ["<!"] = ")@<!" })[look]
        stack[#stack + 1] = suffix
        out[#out + 1] = "("
        i = i + 2 + #look
      elseif pat:sub(i, i + 2) == "(?:" then
        stack[#stack + 1] = ")"
        out[#out + 1] = "%("
        i = i + 3
      elseif pat:sub(i + 1, i + 1) == "?" then
        return nil -- named groups / inline flags
      else
        stack[#stack + 1] = ")"
        out[#out + 1] = "("
        i = i + 1
      end
    elseif c == ")" then
      local suffix = table.remove(stack)
      if not suffix then
        return nil
      end
      out[#out + 1] = suffix
      i = i + 1
    elseif c:match("[@%%&<>=]") then
      -- special in very-magic, literal in PCRE
      out[#out + 1] = "\\" .. c
      i = i + 1
    else
      out[#out + 1] = c
      i = i + 1
    end
  end
  if #stack > 0 then
    return nil
  end
  return table.concat(out)
end

local cache = {} ---@type table<string, vim.regex|false>

---Compiled vim.regex for a PCRE-ish pattern; nil if untranslatable/invalid.
---@param pat string
---@param ignore_case boolean?
---@return vim.regex?
function M.compile(pat, ignore_case)
  local key = pat .. "\0" .. (ignore_case and "i" or "")
  local hit = cache[key]
  if hit ~= nil then
    return hit or nil
  end
  local body = M.to_vim(pat)
  local re
  if body then
    local ok, compiled = pcall(vim.regex, "\\v" .. (ignore_case and "\\c" or "") .. body)
    re = ok and compiled or nil
  end
  if not re then
    vim.notify_once("obsidian-query: unsupported regex: " .. pat, vim.log.levels.WARN)
  end
  cache[key] = re or false
  return re
end

---gsub-style replace via :substitute semantics ($1 -> \1). nil on failure.
---@param s string
---@param pat string
---@param rep string
---@return string?
function M.replace(s, pat, rep)
  local body = M.to_vim(pat)
  if not body then
    vim.notify_once("obsidian-query: unsupported regex: " .. pat, vim.log.levels.WARN)
    return nil
  end
  local vrep = rep:gsub("%$(%d)", "\\%1"):gsub("[&~]", "\\%0")
  local ok, res = pcall(vim.fn.substitute, s, "\\v" .. body, vrep, "g")
  return ok and res or nil
end

return M
