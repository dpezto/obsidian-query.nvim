-- DQL function library. Contract: wrong arity / unsupported type -> NULL,
-- never an error. Single-value string/number fns auto-vectorize over arrays.
local value = require("obsidian-query.dataview.value")

local NULL = value.NULL
local T = value.typeof

local M = {}
local R = {}
M.registry = R

local function vectorize(f, positions)
  positions = positions or { 1 }
  local call
  call = function(env, args)
    local length
    for _, pos in ipairs(positions) do
      if T(args[pos]) == "array" then
        length = math.min(length or math.huge, #args[pos])
      end
    end
    if length then
      local out = {}
      for i = 1, length do
        local sub = vim.list_slice(args)
        for _, pos in ipairs(positions) do
          if T(args[pos]) == "array" then
            sub[pos] = args[pos][i]
          end
        end
        out[i] = call(env, sub)
      end
      return value.array(out)
    end
    return f(env, args)
  end
  return call
end

local function str_fn(f)
  return vectorize(function(_, args)
    if T(args[1]) ~= "string" then
      return NULL
    end
    return f(unpack(args))
  end, { 1, 2, 3 })
end

---------------------------------------------------------------- core

R.typeof = function(_, args)
  return T(args[1])
end

R.default = vectorize(function(_, args)
  return args[T(args[1]) == "null" and 2 or 1]
end, { 1, 2 })

R.choice = vectorize(function(_, args)
  return args[value.truthy(args[1]) and 2 or 3]
end)

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

R.contains = vectorize(function(env, args)
  local hay, needle = args[1], args[2]
  if T(hay) == "array" then
    for _, el in ipairs(hay) do
      if R.contains(env, { el, needle }) then
        return true
      end
    end
    return false
  elseif T(hay) == "string" and T(needle) == "string" then
    return hay:find(needle, 1, true) ~= nil
  elseif T(hay) == "object" and T(needle) == "string" then
    return hay[needle] ~= nil
  end
  return value.eq(hay, needle)
end, { 2 })

R.econtains = vectorize(function(_, args)
  local hay, needle = args[1], args[2]
  if T(hay) == "array" then
    for _, el in ipairs(hay) do
      if value.eq(el, needle) then
        return true
      end
    end
    return false
  elseif T(hay) == "string" and T(needle) == "string" then
    return hay:find(needle, 1, true) ~= nil
  elseif T(hay) == "object" and T(needle) == "string" then
    return hay[needle] ~= nil
  end
  return value.eq(hay, needle)
end, { 2 })

R.icontains = function(env, args)
  local hay, needle = args[1], args[2]
  if T(needle) == "array" then
    local out = {}
    for i, el in ipairs(needle) do
      out[i] = R.icontains(env, { hay, el })
    end
    return value.array(out)
  elseif T(hay) == "array" then
    for _, el in ipairs(hay) do
      if R.icontains(env, { el, needle }) then
        return true
      end
    end
    return false
  elseif T(hay) == "string" and T(needle) == "string" then
    return vim.fn.tolower(hay):find(vim.fn.tolower(needle), 1, true) ~= nil
  elseif T(hay) == "object" and T(needle) == "string" then
    return hay[needle] ~= nil
  end
  return value.eq(hay, needle)
end

R.ldefault = function(_, args)
  if T(args[1]) == "null" then
    return args[2]
  end
  return args[1]
end

R.firstvalue = function(_, args)
  if T(args[1]) == "array" then
    for _, el in ipairs(args[1]) do
      if T(el) ~= "null" then
        return el
      end
    end
  end
  return NULL
end

R.reduce = function(env, args)
  local arr, op = args[1], args[2]
  if T(arr) ~= "array" or #arr == 0 then
    return NULL
  end
  if T(op) == "array" then
    local out = {}
    for i, el in ipairs(op) do
      out[i] = R.reduce(env, { arr, el })
    end
    return value.array(out)
  end
  if type(op) ~= "function" and not vim.tbl_contains({ "+", "-", "*", "/", "&", "|" }, op) then
    return NULL
  end
  local acc = arr[1]
  for i = 2, #arr do
    if type(op) == "function" then
      if T(arr[i]) ~= "null" then
        acc = op({ acc, arr[i] })
      end
    elseif op == "&" then
      acc = value.truthy(acc) and value.truthy(arr[i])
    elseif op == "|" then
      acc = value.truthy(acc) or value.truthy(arr[i])
    else
      acc = value.arith(op, acc, arr[i])
    end
  end
  return acc
end

R.product = function(env, args)
  if T(args[1]) ~= "array" then
    return args[1]
  end
  return R.reduce(env, { args[1], "*" })
end

R.display = function(env, args)
  local v = args[1]
  if T(v) == "null" then
    return ""
  end
  if T(v) == "array" then
    local out = {}
    for i, el in ipairs(v) do
      out[i] = R.display(env, { el })
    end
    return table.concat(out, ", ")
  end
  local text = value.to_display(v, env.settings)
  if T(v) ~= "link" and T(v) ~= "string" then
    return text
  end
  text = text:gsub("%[%[([^%]]-)|([^%]]-)%]%]", "%2"):gsub("%[%[([^%]]-)%]%]", "%1")
  text = text:gsub("!?%[([^%]]-)%]%([^%)]-%)", "%1"):gsub("<[^>]->", "")
  text = text:gsub("%*%*(.-)%*%*", "%1"):gsub("__(.-)__", "%1"):gsub("~~(.-)~~", "%1")
  text = text:gsub("%*([^*]-)%*", "%1"):gsub("_([^_]-)_", "%1"):gsub("`([^`]-)`", "%1")
  return text
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

R.string = function(env, args)
  return value.to_display(args[1], env.settings)
end

R.list = function(_, args)
  return value.array(vim.list_slice(args))
end
R.array = R.list

R.link = vectorize(function(env, args)
  local t = T(args[1])
  if t == "link" then
    local l = args[1]
    return T(args[2]) == "string" and value.link(l.path, vim.tbl_extend("force", {}, l, { display = args[2] })) or l
  elseif t == "string" then
    local link = value.link(args[1], { display = T(args[2]) == "string" and args[2] or nil, embed = args[3] == true })
    return env.normalize_link and env.normalize_link(link) or link
  end
  return NULL
end)

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

R.lower = str_fn(string.lower)
R.upper = str_fn(string.upper)
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

-- shared PCRE-ish -> vim very-magic translator (lookarounds, alternation)
local regex = require("obsidian-query.regex")

R.regextest = vectorize(function(_, args)
  if T(args[1]) == "null" or T(args[2]) == "null" then
    return false
  end
  if T(args[1]) ~= "string" or T(args[2]) ~= "string" then
    return NULL
  end
  local re = regex.compile(args[1])
  return re and re:match_str(args[2]) ~= nil or false
end, { 1, 2 })
R.regexmatch = vectorize(function(env, args)
  if T(args[1]) ~= "string" then
    return R.regextest(env, args)
  end
  local pat = args[1]
  if pat:sub(1, 1) ~= "^" and pat:sub(-1) ~= "$" then
    pat = "^" .. pat .. "$"
  end
  return R.regextest(env, { pat, args[2] })
end, { 1, 2 })

R.regexreplace = str_fn(function(s, pat, rep)
  if T(pat) ~= "string" or T(rep) ~= "string" then
    return NULL
  end
  local res = regex.replace(s, pat, rep)
  return res == nil and NULL or res
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
  return #a == 0 and NULL or a[1]
end
R.last = function(_, args)
  local a = as_array(args[1])
  return #a == 0 and NULL or a[#a]
end
R.reverse = function(_, args)
  local kind = T(args[1])
  if kind ~= "array" and kind ~= "string" then
    return args[1]
  end
  local a, out = kind == "string" and vim.fn.split(args[1], "\\zs") or args[1], {}
  for i = #a, 1, -1 do
    out[#out + 1] = a[i]
  end
  return kind == "string" and table.concat(out) or value.array(out)
end
R.sort = function(_, args)
  local a = vim.list_slice(as_array(args[1]))
  local keyfn = type(args[2]) == "function" and args[2]
  local decorated = {}
  for i, el in ipairs(a) do
    local key = el
    if keyfn then
      key = keyfn({ el })
    end
    decorated[i] = { el = el, key = key, i = i }
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
  -- scalars, dates and links hash on their eq identity; only arrays/objects
  -- (and NaN) fall back to pairwise eq, so common inputs stay linear
  local out, seen, rest = {}, {}, {}
  for _, el in ipairs(as_array(args[1])) do
    local t = T(el)
    local key
    if t == "string" or t == "number" or t == "boolean" then
      key = el
    elseif t == "null" then
      key = true
    elseif t == "date" then
      key = el.ts
    elseif t == "link" then
      key = value.link_key(el)
    end
    local dup = false
    if key ~= nil and key == key then
      seen[t] = seen[t] or {}
      dup = seen[t][key] or false
      seen[t][key] = true
    else
      for _, prev in ipairs(rest) do
        if value.eq(el, prev) then
          dup = true
          break
        end
      end
      if not dup then
        rest[#rest + 1] = el
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
R.join = function(env, args)
  local sep = T(args[2]) == "string" and args[2] or ", "
  local parts = {}
  for _, el in ipairs(as_array(args[1])) do
    parts[#parts + 1] = value.to_display(el, env.settings)
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
  if T(args[1]) ~= "array" then
    return NULL
  end
  local a = args[1]
  local function bound(n, default)
    if T(n) ~= "number" then
      return default
    end
    n = n < 0 and math.ceil(n) or math.floor(n)
    return math.max(0, math.min(#a, n < 0 and #a + n or n))
  end
  local out = {}
  for i = bound(args[2], 0) + 1, bound(args[3], #a) do
    out[#out + 1] = a[i]
  end
  return value.array(out)
end

R.nonnull = function(_, args)
  local out = {}
  for _, el in ipairs(#args == 1 and T(args[1]) == "array" and args[1] or args) do
    if T(el) ~= "null" then
      out[#out + 1] = el
    end
  end
  return value.array(out)
end
local function predicate_args(args)
  if T(args[1]) == "array" and (#args == 1 or (#args == 2 and type(args[2]) == "function")) then
    return args[1], args[2]
  end
  return args
end
R.any = function(_, args)
  local array, predicate = predicate_args(args)
  for _, el in ipairs(array) do
    local v = el
    if predicate then
      v = predicate({ el })
    end
    if value.truthy(v) then
      return true
    end
  end
  return false
end
R.none = function(env, args)
  return not R.any(env, args)
end
R.all = function(_, args)
  local array, predicate = predicate_args(args)
  for _, el in ipairs(array) do
    local v = el
    if predicate then
      v = predicate({ el })
    end
    if not value.truthy(v) then
      return false
    end
  end
  return true
end
R.sum = function(env, args)
  if T(args[1]) ~= "array" then
    return args[1]
  end
  return R.reduce(env, { args[1], "+" })
end
R.average = function(env, args)
  if T(args[1]) ~= "array" then
    return args[1]
  end
  if #args[1] == 0 then
    return NULL
  end
  return value.arith("/", R.sum(env, args), #args[1])
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
  if best == NULL and T(args[1]) == "array" and #args[1] > 0 then
    return args[1][1]
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
  if best == NULL and T(args[1]) == "array" and #args[1] > 0 then
    return args[1][1]
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
  { "yyyy", "%Y" },
  { "yy", "%y" },
  { "MMMM", "%B" },
  { "MMM", "%b" },
  { "MM", "%m" },
  { "dd", "%d" },
  { "HH", "%H" },
  { "hh", "%I" },
  { "mm", "%M" },
  { "ss", "%S" },
  { "EEEE", "%A" },
  { "EEE", "%a" },
  { "ccc", "%a" },
  { "a", "%p" },
  { "X", nil },
  { "x", nil }, -- epoch handled inline
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
        local single =
          { M = "month", d = "day", H = "hour", h = "hour", m = "minute", s = "second", q = "quarter", o = "dayofyear" }
        local ch = fmt:sub(i, i)
        if single[ch] then
          out[#out + 1] = tostring(ch == "h" and ((d.hour + 11) % 12 + 1) or d[single[ch]])
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

-- Luxon Duration.toFormat token subset: y M d h m s S, '...' literals,
-- token length = zero padding
R.durationformat = function(_, args)
  if T(args[1]) ~= "duration" or T(args[2]) ~= "string" then
    return NULL
  end
  local d, fmt = args[1], args[2]
  local comp = {
    y = d.years,
    M = d.months - d.years * 12,
    d = d.days,
    h = d.hours - d.days * 24,
    m = d.minutes - d.hours * 60,
    s = d.seconds - d.minutes * 60,
    S = math.floor(d.ms % 1000),
  }
  local out, i = {}, 1
  while i <= #fmt do
    local c = fmt:sub(i, i)
    if c == "'" then
      local close = fmt:find("'", i + 1, true) or #fmt + 1
      out[#out + 1] = fmt:sub(i + 1, close - 1)
      i = close + 1
    elseif comp[c] ~= nil then
      local j = i
      while fmt:sub(j + 1, j + 1) == c do
        j = j + 1
      end
      out[#out + 1] = ("%0" .. (j - i + 1) .. "d"):format(comp[c])
      i = j + 1
    else
      out[#out + 1] = c
      i = i + 1
    end
  end
  return table.concat(out)
end

local CURRENCY = { USD = "$", EUR = "\u{20ac}", GBP = "\u{a3}", JPY = "\u{a5}", MXN = "$" }
R.currencyformat = vectorize(function(_, args)
  if T(args[1]) ~= "number" then
    return NULL
  end
  local code = T(args[2]) == "string" and args[2]:upper() or "USD"
  local sym = CURRENCY[code] or (code .. " ")
  local n = args[1]
  local decimals = code == "JPY" and 0 or 2
  local int = ("%d"):format(math.floor(math.abs(n)))
  local grouped = int:reverse():gsub("(%d%d%d)", "%1,"):reverse():gsub("^,", "")
  local frac = decimals > 0 and ("%." .. decimals .. "f"):format(math.abs(n) % 1):sub(2) or ""
  return (n < 0 and "-" or "") .. sym .. grouped .. frac
end)

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
R.embed = vectorize(function(_, args)
  if T(args[1]) ~= "link" then
    return NULL
  end
  return value.link(args[1].path, vim.tbl_extend("force", {}, args[1], { embed = args[2] == nil or args[2] == true }))
end)
R.containsword = str_fn(function(s, w)
  if T(w) ~= "string" then
    return NULL
  end
  return s:lower():find("%f[%w]" .. vim.pesc(w:lower()) .. "%f[%W]") ~= nil
end)
R.extract = vectorize(function(env, args)
  local out = {}
  for i = 2, #args do
    if T(args[i]) == "string" then
      out[args[i]] = require("obsidian-query.dataview.eval").index(args[1], args[i], env)
    end
  end
  return out
end)
R.hash = function(_, args)
  return vim.fn.sha256(value.to_display(args[1])):sub(1, 8)
end

return M
