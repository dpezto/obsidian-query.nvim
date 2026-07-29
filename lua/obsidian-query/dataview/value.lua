-- DQL value system: scalars are native Lua; structured values are tagged
-- tables (dv field + per-type metatable). Lua nil normalizes to value.NULL
-- at every eval boundary so nulls survive inside arrays.
local M = {}

M.NULL = setmetatable({}, {
  __tostring = function()
    return "null"
  end,
})

---------------------------------------------------------------- constructors

local date_mt, dur_mt, link_mt, array_mt, task_mt

-- lazy date components via os.date; ts canonical (fast ordering)
date_mt = {
  dv = "date",
  __index = function(self, key)
    local t = rawget(self, "_t")
    if not t then
      t = os.date("*t", math.floor(self.ts))
      rawset(self, "_t", t)
    end
    local map = {
      year = t.year,
      month = t.month,
      day = t.day,
      hour = t.hour,
      minute = t.min,
      second = t.sec,
      weekday = (t.wday + 5) % 7 + 1, -- 1 = Monday
      dayofyear = t.yday,
      quarter = math.ceil(t.month / 3),
      week = tonumber(os.date("%V", math.floor(self.ts))),
    }
    return map[key]
  end,
}

-- greedy decomposition, fixed factors (y=365d, mo=30d, w=7d — deviates from
-- Luxon's calendar-aware shifting; fine for note queries)
local DUR_MS = {
  years = 365 * 24 * 3600 * 1000,
  months = 30 * 24 * 3600 * 1000,
  weeks = 7 * 24 * 3600 * 1000,
  days = 24 * 3600 * 1000,
  hours = 3600 * 1000,
  minutes = 60 * 1000,
  seconds = 1000,
  milliseconds = 1,
}
dur_mt = {
  dv = "dur",
  __index = function(self, key)
    if DUR_MS[key] then
      return math.floor(self.ms / DUR_MS[key])
    end
  end,
}

link_mt = { dv = "link" }
array_mt = { dv = "array" }
task_mt = { dv = "task" }

function M.date(ts, prec)
  return setmetatable({ ts = ts, prec = prec or "datetime" }, date_mt)
end

function M.dur(ms)
  return setmetatable({ ms = ms }, dur_mt)
end

---@param path string vault-relative or bare note name
function M.link(path, opts)
  opts = opts or {}
  return setmetatable({
    path = path,
    subpath = opts.subpath,
    kind = opts.kind or "file",
    display = opts.display,
    embed = opts.embed or false,
  }, link_mt)
end

function M.array(list)
  return setmetatable(list or {}, array_mt)
end

function M.task(t)
  return setmetatable(t, task_mt)
end

M.task_mt = task_mt

---------------------------------------------------------------- typeof

function M.typeof(v)
  if v == M.NULL or v == nil then
    return "null"
  end
  local t = type(v)
  if t == "boolean" or t == "number" or t == "string" or t == "function" then
    return t == "function" and "function" or t
  end
  if t == "table" then
    local mt = getmetatable(v)
    local dv = mt and mt.dv
    if dv == "date" then
      return "date"
    elseif dv == "dur" then
      return "duration"
    elseif dv == "link" then
      return "link"
    elseif dv == "array" then
      return "array"
    elseif dv == "task" then
      return "object"
    end
    return vim.islist(v) and #v > 0 and "array" or "object"
  end
  return "null"
end

---------------------------------------------------------------- parsing

local DATE_PAT = "^(%d%d%d%d)%-(%d%d)%-(%d%d)"
local TIME_PAT = "^T(%d%d):(%d%d):?(%d?%d?)"

---ISO 8601 (naive local): yyyy-MM-dd[THH:mm[:ss]]
function M.parse_date(s)
  if type(s) ~= "string" then
    return M.NULL
  end
  local y, mo, d = s:match(DATE_PAT)
  if not y then
    return M.NULL
  end
  local rest = s:sub(11)
  local h, mi, sec = rest:match(TIME_PAT)
  local ts = os.time({
    year = tonumber(y),
    month = tonumber(mo),
    day = tonumber(d),
    hour = tonumber(h) or 0,
    min = tonumber(mi) or 0,
    sec = tonumber(sec) or 0,
  })
  if not ts then
    return M.NULL
  end
  return M.date(ts, h and "datetime" or "date")
end

local DUR_UNITS = {
  y = "years", yr = "years", yrs = "years", year = "years", years = "years",
  mo = "months", month = "months", months = "months",
  w = "weeks", wk = "weeks", wks = "weeks", week = "weeks", weeks = "weeks",
  d = "days", day = "days", days = "days",
  h = "hours", hr = "hours", hrs = "hours", hour = "hours", hours = "hours",
  m = "minutes", min = "minutes", mins = "minutes", minute = "minutes", minutes = "minutes",
  s = "seconds", sec = "seconds", secs = "seconds", second = "seconds", seconds = "seconds",
}

---"1 day, 2 hours" / "3h" / "7 days"
function M.parse_dur(s)
  if type(s) ~= "string" then
    return M.NULL
  end
  local ms, found = 0, false
  for num, unit in s:gmatch("(%d+%.?%d*)%s*(%a+)") do
    local u = DUR_UNITS[unit:lower()]
    if u then
      ms = ms + tonumber(num) * DUR_MS[u]
      found = true
    end
  end
  return found and M.dur(ms) or M.NULL
end

---------------------------------------------------------------- comparison

local function norm_link_path(l)
  return (l.path:lower():gsub("%.md$", "")) .. "\0" .. (l.subpath or "")
end

local TYPE_RANK = {
  null = 0,
  boolean = 1,
  number = 2,
  string = 3,
  date = 4,
  duration = 5,
  link = 6,
  array = 7,
  object = 8,
  ["function"] = 9,
}

function M.eq(a, b)
  local ta, tb = M.typeof(a), M.typeof(b)
  if ta ~= tb then
    return false
  end
  if ta == "null" then
    return true
  elseif ta == "date" then
    return a.ts == b.ts
  elseif ta == "duration" then
    return a.ms == b.ms
  elseif ta == "link" then
    return norm_link_path(a) == norm_link_path(b)
  elseif ta == "array" then
    if #a ~= #b then
      return false
    end
    for i = 1, #a do
      if not M.eq(a[i], b[i]) then
        return false
      end
    end
    return true
  elseif ta == "object" then
    for k, v in pairs(a) do
      if not M.eq(v, b[k]) then
        return false
      end
    end
    for k in pairs(b) do
      if rawget(a, k) == nil then
        return false
      end
    end
    return true
  end
  return a == b
end

---Total order (never errors) — the SORT comparator.
---@return -1|0|1
function M.cmp(a, b)
  local ta, tb = M.typeof(a), M.typeof(b)
  if ta ~= tb then
    return TYPE_RANK[ta] < TYPE_RANK[tb] and -1 or 1
  end
  local function scalar(x, y)
    if x == y then
      return 0
    end
    return x < y and -1 or 1
  end
  if ta == "null" then
    return 0
  elseif ta == "boolean" then
    return scalar(a and 1 or 0, b and 1 or 0)
  elseif ta == "number" or ta == "string" then
    return scalar(a, b)
  elseif ta == "date" then
    return scalar(a.ts, b.ts)
  elseif ta == "duration" then
    return scalar(a.ms, b.ms)
  elseif ta == "link" then
    return scalar(norm_link_path(a), norm_link_path(b))
  elseif ta == "array" then
    for i = 1, math.min(#a, #b) do
      local c = M.cmp(a[i], b[i])
      if c ~= 0 then
        return c
      end
    end
    return scalar(#a, #b)
  elseif ta == "object" then
    local ka, kb = vim.tbl_keys(a), vim.tbl_keys(b)
    table.sort(ka)
    table.sort(kb)
    for i = 1, math.min(#ka, #kb) do
      local c = M.cmp(ka[i], kb[i])
      if c == 0 then
        c = M.cmp(a[ka[i]], b[kb[i]])
      end
      if c ~= 0 then
        return c
      end
    end
    return scalar(#ka, #kb)
  end
  return 0
end

---WHERE comparison; `<' family with NULL -> NULL (row filtered as falsy)
---@return boolean|table
function M.compare_op(op, a, b)
  if op == "=" then
    return M.eq(a, b)
  elseif op == "!=" then
    return not M.eq(a, b)
  end
  if M.typeof(a) == "null" or M.typeof(b) == "null" then
    return M.NULL
  end
  local c = M.cmp(a, b)
  if op == "<" then
    return c < 0
  elseif op == "<=" then
    return c <= 0
  elseif op == ">" then
    return c > 0
  elseif op == ">=" then
    return c >= 0
  end
  return M.NULL
end

---------------------------------------------------------------- arithmetic

function M.arith(op, a, b)
  local ta, tb = M.typeof(a), M.typeof(b)
  if op == "+" then
    -- string concat is the most forgiving branch (matches Dataview)
    if ta == "string" or tb == "string" then
      return M.to_display(a) .. M.to_display(b)
    end
    if ta == "null" or tb == "null" then
      return M.NULL
    end
    if ta == "number" and tb == "number" then
      return a + b
    elseif ta == "date" and tb == "duration" then
      return M.date(a.ts + b.ms / 1000, a.prec)
    elseif ta == "duration" and tb == "date" then
      return M.date(b.ts + a.ms / 1000, b.prec)
    elseif ta == "duration" and tb == "duration" then
      return M.dur(a.ms + b.ms)
    elseif ta == "array" and tb == "array" then
      local out = {}
      vim.list_extend(out, a)
      vim.list_extend(out, b)
      return M.array(out)
    end
  elseif op == "-" then
    if ta == "null" or tb == "null" then
      return M.NULL
    end
    if ta == "number" and tb == "number" then
      return a - b
    elseif ta == "date" and tb == "date" then
      return M.dur((a.ts - b.ts) * 1000)
    elseif ta == "date" and tb == "duration" then
      return M.date(a.ts - b.ms / 1000, a.prec)
    elseif ta == "duration" and tb == "duration" then
      return M.dur(a.ms - b.ms)
    end
  elseif op == "*" then
    if ta == "number" and tb == "number" then
      return a * b
    elseif ta == "duration" and tb == "number" then
      return M.dur(a.ms * b)
    elseif ta == "number" and tb == "duration" then
      return M.dur(b.ms * a)
    end
  elseif op == "/" then
    if tb == "number" and b == 0 then
      return M.NULL
    end
    if ta == "number" and tb == "number" then
      return a / b
    elseif ta == "duration" and tb == "number" then
      return M.dur(a.ms / b)
    end
  elseif op == "%" then
    if ta == "number" and tb == "number" and b ~= 0 then
      return a % b
    end
  end
  return M.NULL
end

---------------------------------------------------------------- display

function M.truthy(v)
  local t = M.typeof(v)
  if t == "null" then
    return false
  elseif t == "boolean" then
    return v
  elseif t == "string" then
    return v ~= ""
  elseif t == "array" then
    return #v > 0
  elseif t == "number" then
    return v ~= 0
  end
  return true
end

function M.to_display(v)
  local t = M.typeof(v)
  if t == "null" then
    return ""
  elseif t == "string" then
    return v
  elseif t == "number" then
    return v % 1 == 0 and tostring(math.floor(v)) or tostring(v)
  elseif t == "boolean" then
    return tostring(v)
  elseif t == "date" then
    return os.date(v.prec == "date" and "%Y-%m-%d" or "%Y-%m-%d %H:%M", math.floor(v.ts)) --[[@as string]]
  elseif t == "duration" then
    local parts, rem = {}, v.ms
    for _, u in ipairs({ "years", "months", "days", "hours", "minutes", "seconds" }) do
      local n = math.floor(rem / DUR_MS[u])
      if n > 0 then
        parts[#parts + 1] = n .. " " .. (n == 1 and u:sub(1, -2) or u)
        rem = rem - n * DUR_MS[u]
      end
    end
    return #parts > 0 and table.concat(parts, ", ") or "0 seconds"
  elseif t == "link" then
    return v.display or vim.fn.fnamemodify(v.path, ":t:r")
  elseif t == "array" then
    local parts = {}
    for _, x in ipairs(v) do
      parts[#parts + 1] = M.to_display(x)
    end
    return table.concat(parts, ", ")
  elseif t == "object" then
    if getmetatable(v) == task_mt then
      return v.text or ""
    end
    return vim.inspect(v, { newline = " ", indent = "" })
  end
  return tostring(v)
end

return M
