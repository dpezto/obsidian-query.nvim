-- DQL function library. Contract: wrong arity / unsupported type -> NULL,
-- never an error. Single-value string/number fns auto-vectorize over arrays.
local value = require("obsidian-query.dataview.value")

local NULL = value.NULL
local T = value.typeof

local M = {}
local R = {}
M.registry = R

local function vectorize(f)
  return function(env, args)
    if T(args[1]) == "array" then
      local out = {}
      for i, el in ipairs(args[1]) do
        local sub = { el }
        for j = 2, #args do
          sub[j] = args[j]
        end
        out[i] = f(env, sub)
      end
      return value.array(out)
    end
    return f(env, args)
  end
end

local function str_fn(f)
  return vectorize(function(_, args)
    if T(args[1]) ~= "string" then
      return NULL
    end
    return f(unpack(args))
  end)
end

---------------------------------------------------------------- core

R.typeof = function(_, args)
  return T(args[1])
end

R.default = vectorize(function(_, args)
  return T(args[1]) == "null" and args[2] or args[1]
end)

R.choice = function(_, args)
  return value.truthy(args[1]) and args[2] or args[3]
end

R.length = function(_, args)
  local t = T(args[1])
  if t == "array" then
    return #args[1]
  elseif t == "string" then
    return vim.fn.strchars(args[1])
  elseif t == "object" then
    return #vim.tbl_keys(args[1])
  end
  return 0
end

R.contains = function(_, args)
  local hay, needle = args[1], args[2]
  local t = T(hay)
  if t == "string" then
    return T(needle) == "string" and hay:lower():find(needle:lower(), 1, true) ~= nil
  elseif t == "array" then
    for _, el in ipairs(hay) do
      if value.eq(el, needle) or (T(el) == "string" and T(needle) == "string" and el:lower():find(needle:lower(), 1, true)) then
        return true
      end
    end
    return false
  elseif t == "object" then
    return T(needle) == "string" and hay[needle] ~= nil
  elseif t == "link" then
    return T(needle) == "string" and value.to_display(hay):lower():find(needle:lower(), 1, true) ~= nil
  end
  return false
end

R.econtains = function(_, args)
  local hay, needle = args[1], args[2]
  local t = T(hay)
  if t == "string" then
    return T(needle) == "string" and hay:find(needle, 1, true) ~= nil
  elseif t == "array" then
    for _, el in ipairs(hay) do
      if value.eq(el, needle) then
        return true
      end
    end
    return false
  elseif t == "object" then
    return T(needle) == "string" and hay[needle] ~= nil
  end
  return false
end

---------------------------------------------------------------- constructors

R.date = vectorize(function(_, args)
  local t = T(args[1])
  if t == "date" then
    return args[1]
  elseif t == "string" then
    return value.parse_date(args[1])
  end
  return NULL
end)

R.dur = function(_, args)
  local t = T(args[1])
  if t == "duration" then
    return args[1]
  elseif t == "string" then
    return value.parse_dur(args[1])
  end
  return NULL
end

R.number = vectorize(function(_, args)
  local t = T(args[1])
  if t == "number" then
    return args[1]
  elseif t == "string" then
    local n = args[1]:match("%-?%d+%.?%d*")
    return n and tonumber(n) or NULL
  end
  return NULL
end)

R.string = function(_, args)
  return value.to_display(args[1])
end

R.list = function(_, args)
  return value.array(vim.list_slice(args))
end
R.array = R.list

R.link = function(_, args)
  local t = T(args[1])
  if t == "link" then
    local l = args[1]
    return T(args[2]) == "string" and value.link(l.path, { subpath = l.subpath, display = args[2] }) or l
  elseif t == "string" then
    return value.link(args[1], { display = T(args[2]) == "string" and args[2] or nil })
  end
  return NULL
end

R.object = function(_, args)
  local out = {}
  for i = 1, #args - 1, 2 do
    if T(args[i]) == "string" then
      out[args[i]] = args[i + 1]
    end
  end
  return out
end

---------------------------------------------------------------- strings

R.lower = str_fn(function(s)
  return s:lower()
end)
R.upper = str_fn(function(s)
  return s:upper()
end)
R.trim = str_fn(function(s)
  return vim.trim(s)
end)
R.startswith = str_fn(function(s, pre)
  return T(pre) == "string" and vim.startswith(s, pre)
end)
R.endswith = str_fn(function(s, suf)
  return T(suf) == "string" and vim.endswith(s, suf)
end)
R.padleft = str_fn(function(s, n, ch)
  return string.rep(T(ch) == "string" and ch or " ", math.max(0, (n or 0) - #s)) .. s
end)
R.padright = str_fn(function(s, n, ch)
  return s .. string.rep(T(ch) == "string" and ch or " ", math.max(0, (n or 0) - #s))
end)
R.substring = str_fn(function(s, from, to)
  return s:sub((from or 0) + 1, to or #s) -- dataview substrings are 0-based
end)
R.truncate = str_fn(function(s, n, suffix)
  suffix = T(suffix) == "string" and suffix or "…"
  if vim.fn.strchars(s) <= (n or 0) then
    return s
  end
  return vim.fn.strcharpart(s, 0, math.max(0, (n or 0) - vim.fn.strchars(suffix))) .. suffix
end)
R.replace = str_fn(function(s, pat, rep)
  if T(pat) ~= "string" or T(rep) ~= "string" then
    return NULL
  end
  local out = s:gsub(vim.pesc(pat), (rep:gsub("%%", "%%%%")))
  return out
end)
R.split = function(_, args)
  if T(args[1]) ~= "string" or T(args[2]) ~= "string" then
    return NULL
  end
  return value.array(vim.split(args[1], args[2], { plain = true }))
end

-- PCRE -> Lua pattern shim for the common atoms; unsupported constructs -> NULL
local function to_lua_pat(pat)
  if pat:find("(?", 1, true) or pat:find("|", 1, true) then
    vim.notify_once("obsidian-query dataview: unsupported regex " .. pat, vim.log.levels.WARN)
    return nil
  end
  local out = pat
    :gsub("%%", "%%%%")
    :gsub("\\d", "%%d")
    :gsub("\\w", "%%w")
    :gsub("\\s", "%%s")
    :gsub("\\b", "%%f[%%w]")
    :gsub("\\%.", "%%.")
  return out
end

R.regexmatch = str_fn(function(s, pat)
  if T(pat) ~= "string" then
    return NULL
  end
  local lp = to_lua_pat(pat)
  if not lp then
    return NULL
  end
  local ok, res = pcall(string.find, s, lp)
  return ok and res ~= nil or false
end)
R.regextest = R.regexmatch

R.regexreplace = str_fn(function(s, pat, rep)
  if T(pat) ~= "string" or T(rep) ~= "string" then
    return NULL
  end
  local lp = to_lua_pat(pat)
  if not lp then
    return NULL
  end
  local ok, res = pcall(string.gsub, s, lp, (rep:gsub("%$(%d)", "%%%1")))
  return ok and res or NULL
end)

---------------------------------------------------------------- arrays

local function as_array(v)
  local t = T(v)
  if t == "array" then
    return v
  elseif t == "null" then
    return value.array({})
  end
  return value.array({ v })
end

R.first = function(_, args)
  local a = as_array(args[1])
  return #a > 0 and a[1] or NULL
end
R.last = function(_, args)
  local a = as_array(args[1])
  return #a > 0 and a[#a] or NULL
end
R.reverse = function(_, args)
  local a, out = as_array(args[1]), {}
  for i = #a, 1, -1 do
    out[#out + 1] = a[i]
  end
  return value.array(out)
end
R.sort = function(_, args)
  local a = vim.list_slice(as_array(args[1]))
  local keyfn = type(args[2]) == "function" and args[2]
  local decorated = {}
  for i, el in ipairs(a) do
    decorated[i] = { el = el, key = keyfn and keyfn({ el }) or el, i = i }
  end
  table.sort(decorated, function(x, y)
    local c = value.cmp(x.key, y.key)
    if c ~= 0 then
      return c < 0
    end
    return x.i < y.i
  end)
  local out = {}
  for i, d in ipairs(decorated) do
    out[i] = d.el
  end
  return value.array(out)
end
R.unique = function(_, args)
  local out = {}
  for _, el in ipairs(as_array(args[1])) do
    local dup = false
    for _, seen in ipairs(out) do
      if value.eq(el, seen) then
        dup = true
        break
      end
    end
    if not dup then
      out[#out + 1] = el
    end
  end
  return value.array(out)
end
R.flat = function(_, args)
  local depth = T(args[2]) == "number" and args[2] or 1
  local function go(a, d)
    local out = {}
    for _, el in ipairs(a) do
      if T(el) == "array" and d > 0 then
        vim.list_extend(out, go(el, d - 1))
      else
        out[#out + 1] = el
      end
    end
    return out
  end
  return value.array(go(as_array(args[1]), depth))
end
R.join = function(_, args)
  local sep = T(args[2]) == "string" and args[2] or ", "
  local parts = {}
  for _, el in ipairs(as_array(args[1])) do
    parts[#parts + 1] = value.to_display(el)
  end
  return table.concat(parts, sep)
end
R.map = function(_, args)
  if type(args[2]) ~= "function" then
    return NULL
  end
  local out = {}
  for _, el in ipairs(as_array(args[1])) do
    out[#out + 1] = args[2]({ el })
  end
  return value.array(out)
end
R.filter = function(_, args)
  if type(args[2]) ~= "function" then
    return NULL
  end
  local out = {}
  for _, el in ipairs(as_array(args[1])) do
    if value.truthy(args[2]({ el })) then
      out[#out + 1] = el
    end
  end
  return value.array(out)
end
R.slice = function(_, args)
  local a = as_array(args[1])
  local from = (T(args[2]) == "number" and args[2] or 0) + 1
  local to = T(args[3]) == "number" and args[3] or #a
  return value.array(vim.list_slice(a, from, to))
end
R.nonnull = function(_, args)
  local out = {}
  for _, el in ipairs(as_array(args[1])) do
    if T(el) ~= "null" then
      out[#out + 1] = el
    end
  end
  return value.array(out)
end
R.any = function(_, args)
  for _, el in ipairs(as_array(args[1])) do
    local v = type(args[2]) == "function" and args[2]({ el }) or el
    if value.truthy(v) then
      return true
    end
  end
  return false
end
R.all = function(_, args)
  for _, el in ipairs(as_array(args[1])) do
    local v = type(args[2]) == "function" and args[2]({ el }) or el
    if not value.truthy(v) then
      return false
    end
  end
  return true
end
R.sum = function(_, args)
  local acc = NULL
  for _, el in ipairs(as_array(args[1])) do
    acc = T(acc) == "null" and el or value.arith("+", acc, el)
  end
  return acc
end
R.average = function(_, args)
  local a = as_array(args[1])
  if #a == 0 then
    return NULL
  end
  local s = R.sum(_, { a })
  return value.arith("/", s, #a)
end
R.min = function(_, args)
  local a = #args > 1 and args or as_array(args[1])
  local best = NULL
  for _, el in ipairs(a) do
    if T(el) ~= "null" and (T(best) == "null" or value.cmp(el, best) < 0) then
      best = el
    end
  end
  return best
end
R.max = function(_, args)
  local a = #args > 1 and args or as_array(args[1])
  local best = NULL
  for _, el in ipairs(a) do
    if T(el) ~= "null" and (T(best) == "null" or value.cmp(el, best) > 0) then
      best = el
    end
  end
  return best
end
R.minby = function(_, args)
  if type(args[2]) ~= "function" then
    return NULL
  end
  local best, bestkey = NULL, NULL
  for _, el in ipairs(as_array(args[1])) do
    local k = args[2]({ el })
    if T(k) ~= "null" and (T(bestkey) == "null" or value.cmp(k, bestkey) < 0) then
      best, bestkey = el, k
    end
  end
  return best
end
R.maxby = function(_, args)
  if type(args[2]) ~= "function" then
    return NULL
  end
  local best, bestkey = NULL, NULL
  for _, el in ipairs(as_array(args[1])) do
    local k = args[2]({ el })
    if T(k) ~= "null" and (T(bestkey) == "null" or value.cmp(k, bestkey) > 0) then
      best, bestkey = el, k
    end
  end
  return best
end

---------------------------------------------------------------- numbers

R.round = vectorize(function(_, args)
  if T(args[1]) ~= "number" then
    return NULL
  end
  local digits = T(args[2]) == "number" and args[2] or 0
  local mul = 10 ^ digits
  return math.floor(args[1] * mul + 0.5) / mul
end)
R.floor = vectorize(function(_, args)
  return T(args[1]) == "number" and math.floor(args[1]) or NULL
end)
R.ceil = vectorize(function(_, args)
  return T(args[1]) == "number" and math.ceil(args[1]) or NULL
end)
R.trunc = vectorize(function(_, args)
  if T(args[1]) ~= "number" then
    return NULL
  end
  return args[1] >= 0 and math.floor(args[1]) or math.ceil(args[1])
end)

---------------------------------------------------------------- dates

R.striptime = vectorize(function(_, args)
  if T(args[1]) ~= "date" then
    return NULL
  end
  local t = os.date("*t", math.floor(args[1].ts))
  return value.date(os.time({ year = t.year, month = t.month, day = t.day, hour = 0 }), "date")
end)

-- Luxon token subset, longest-match scan; '...' quotes literals
local FMT = {
  { "yyyy", "%Y" }, { "yy", "%y" },
  { "MMMM", "%B" }, { "MMM", "%b" }, { "MM", "%m" },
  { "dd", "%d" },
  { "HH", "%H" }, { "hh", "%I" },
  { "mm", "%M" }, { "ss", "%S" },
  { "EEEE", "%A" }, { "EEE", "%a" }, { "ccc", "%a" },
  { "a", "%p" },
  { "X", nil }, { "x", nil }, -- epoch handled inline
}
R.dateformat = vectorize(function(_, args)
  if T(args[1]) ~= "date" or T(args[2]) ~= "string" then
    return NULL
  end
  local d, fmt = args[1], args[2]
  local out, i = {}, 1
  while i <= #fmt do
    if fmt:sub(i, i) == "'" then
      local close = fmt:find("'", i + 1, true) or #fmt + 1
      out[#out + 1] = fmt:sub(i + 1, close - 1)
      i = close + 1
    else
      local matched = false
      for _, pair in ipairs(FMT) do
        local tok = pair[1]
        if fmt:sub(i, i + #tok - 1) == tok then
          if tok == "X" then
            out[#out + 1] = tostring(math.floor(d.ts))
          elseif tok == "x" then
            out[#out + 1] = tostring(math.floor(d.ts * 1000))
          else
            out[#out + 1] = os.date(pair[2], math.floor(d.ts)) --[[@as string]]
          end
          i = i + #tok
          matched = true
          break
        end
      end
      if not matched then
        local single = { M = "month", d = "day", H = "hour", h = "hour", m = "minute", s = "second", q = "quarter", o = "dayofyear" }
        local ch = fmt:sub(i, i)
        if single[ch] then
          out[#out + 1] = tostring(d[single[ch]])
        elseif ch == "W" then
          out[#out + 1] = tostring(d.week)
        else
          out[#out + 1] = ch
        end
        i = i + 1
      end
    end
  end
  return table.concat(out)
end)

R.durationformat = function(_, args)
  return T(args[1]) == "duration" and value.to_display(args[1]) or NULL
end

R.localtime = function(_, args)
  return args[1] -- naive local time throughout
end

---------------------------------------------------------------- misc

R.meta = function(_, args)
  if T(args[1]) == "link" then
    local l = args[1]
    return { path = l.path, subpath = l.subpath, display = l.display, embed = l.embed, type = l.kind }
  end
  return NULL
end
R.elink = function(_, args)
  if T(args[1]) ~= "string" then
    return NULL
  end
  return value.link(args[1], { display = T(args[2]) == "string" and args[2] or args[1] })
end
R.embed = function(_, args)
  return args[1]
end
R.containsword = str_fn(function(s, w)
  if T(w) ~= "string" then
    return NULL
  end
  return s:lower():find("%f[%w]" .. vim.pesc(w:lower()) .. "%f[%W]") ~= nil
end)
R.extract = function(_, args)
  if T(args[1]) ~= "object" then
    return NULL
  end
  local out = {}
  for i = 2, #args do
    if T(args[i]) == "string" then
      out[args[i]] = args[1][args[i]]
    end
  end
  return out
end
R.hash = function(_, args)
  return vim.fn.sha256(value.to_display(args[1])):sub(1, 8)
end

return M
