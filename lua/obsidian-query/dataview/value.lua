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
local widget_mt = { dv = "widget" }

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
      millisecond = math.floor((self.ts - math.floor(self.ts)) * 1000 + 0.5),
      weekday = (t.wday + 5) % 7 + 1, -- 1 = Monday
      dayofyear = t.yday,
      quarter = math.ceil(t.month / 3),
      week = tonumber(os.date("%V", math.floor(self.ts))),
    }
    return map[key]
  end,
}

-- Durations are hybrid: `ms` for the clock part plus symbolic `months`
-- (months/years), so date arithmetic can shift calendar months like Luxon
-- instead of adding a fixed 30 days. DUR_MS keeps approximate factors for
-- ordering/comparison of mixed durations only.
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
    local months = rawget(self, "months") or 0
    if key == "years" then
      return math.floor(months / 12)
    elseif key == "months" then
      return months
    elseif DUR_MS[key] then
      return math.floor(self.ms / DUR_MS[key])
    end
  end,
}

---Approximate total ms (for cmp/eq only — arithmetic keeps parts separate)
local function dur_approx_ms(d)
  return d.ms + (rawget(d, "months") or 0) * DUR_MS.months
end

---Luxon-style month shift with day clamping (Jan 31 + 1 month = Feb 28)
local function shift_months(ts, months)
  local t = os.date("*t", math.floor(ts)) --[[@as osdate]]
  local total = (t.year * 12 + (t.month - 1)) + months
  local year, month = math.floor(total / 12), (total % 12) + 1
  local last = os.date("*t", os.time({ year = year, month = month + 1, day = 0 })).day
  return os.time({
    year = year,
    month = month,
    day = math.min(t.day, last),
    hour = t.hour,
    min = t.min,
    sec = t.sec,
  })
end

link_mt = { dv = "link" }
array_mt = { dv = "array" }
task_mt = { dv = "task" }

function M.date(ts, prec)
  return setmetatable({ ts = ts, prec = prec or "datetime" }, date_mt)
end

---Local midnight of `ts`'s day, `days` calendar days later. Built from date
---components (os.time normalizes overflow), so DST days never drift by an hour.
---@param ts number
---@param days integer?
---@return integer
function M.day_start(ts, days)
  local t = os.date("*t", math.floor(ts))
  return os.time({ year = t.year, month = t.month, day = t.day + (days or 0), hour = 0, min = 0, sec = 0 })
end

---@param ms number clock part
---@param months? number symbolic calendar part (months; years fold into it)
function M.dur(ms, months)
  return setmetatable({ ms = ms, months = months or 0 }, dur_mt)
end

---@param path string vault-relative or bare note name
function M.link(path, opts)
  opts = vim.tbl_extend("force", {}, opts or {})
  local base, sub = path:match("^(.-)#(.*)$")
  if base then
    path = base
    opts.subpath = opts.subpath or sub:gsub("^%^", "")
    opts.kind = sub:sub(1, 1) == "^" and "block" or "header"
  end
  return setmetatable({
    path = path,
    subpath = opts.subpath,
    kind = opts.kind or "file",
    display = opts.display,
    embed = opts.embed or false,
  }, link_mt)
end

function M.normalize_link(link, ctx, source, relative)
  local path = ctx and ctx.resolve and ctx.resolve(link.path, ctx.root, source, relative)
  if not path then
    return link
  end
  return M.link(vim.fs.relpath(ctx.root, path) or path, link)
end

function M.external_link(url, display)
  return setmetatable({ url = url, display = display or url }, widget_mt)
end

function M.array(list)
  return setmetatable(list or {}, array_mt)
end

function M.task(t)
  return setmetatable(t, task_mt)
end

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
    elseif dv == "widget" then
      return "widget"
    elseif dv == "task" then
      return "object"
    end
    return vim.islist(v) and #v > 0 and "array" or "object"
  end
  return "null"
end

---------------------------------------------------------------- parsing

local DATE_PAT = "^(%d%d%d%d)%-(%d%d)%-(%d%d)"
---ISO dates and timestamps; file names may carry trailing prose.
function M.parse_date(s, exact)
  if type(s) ~= "string" then
    return M.NULL
  end
  local y, mo, d = s:match(DATE_PAT)
  if not y then
    return M.NULL
  end
  y, mo, d = tonumber(y), tonumber(mo), tonumber(d)
  local ok, noon = pcall(os.time, { year = y, month = mo, day = d, hour = 12, min = 0, sec = 0 })
  if not ok or not noon then
    return M.NULL
  end
  local checked = os.date("*t", noon)
  if checked.year ~= y or checked.month ~= mo or checked.day ~= d then
    return M.NULL
  end
  local rest = s:sub(11)
  local h, mi, tail = rest:match("^[T ](%d%d):(%d%d)(.*)$")
  local sec, fraction, zone = 0, 0, nil
  if h then
    h, mi = tonumber(h), tonumber(mi)
    if tail:sub(1, 1) == ":" then
      local seconds, remaining = tail:match("^:(%d%d)(.*)$")
      if not seconds then
        return M.NULL
      end
      sec, tail = tonumber(seconds), remaining
    end
    if tail:sub(1, 1) == "." then
      local digits, remaining = tail:match("^%.(%d+)(.*)$")
      if not digits then
        return M.NULL
      end
      fraction, tail = tonumber("0." .. digits), remaining
    end
    if tail == "Z" or tail == "z" then
      zone, tail = 0, ""
    elseif tail:match("^[+-]") then
      local sign, zh, zm = tail:match("^([+-])(%d%d):?(%d%d)$")
      if not sign or tonumber(zh) > 23 or tonumber(zm) > 59 then
        return M.NULL
      end
      zone, tail = (tonumber(zh) * 3600 + tonumber(zm) * 60) * (sign == "+" and 1 or -1), ""
    end
    if h > 23 or mi > 59 or sec > 59 or (exact and tail ~= "") then
      return M.NULL
    end
  elseif exact and rest ~= "" then
    return M.NULL
  end
  local ts
  if zone ~= nil then
    local offset = os.date("%z", noon)
    local sign, oh, om = offset:match("^([+-])(%d%d)(%d%d)$")
    local local_offset = (tonumber(oh) * 3600 + tonumber(om) * 60) * (sign == "+" and 1 or -1)
    ts = noon + local_offset - 12 * 3600 + h * 3600 + mi * 60 + sec - zone + fraction
  else
    ts = os.time({ year = y, month = mo, day = d, hour = h or 0, min = mi or 0, sec = sec }) + fraction
  end
  return M.date(ts, h and "datetime" or "date")
end

local DUR_UNITS = {
  y = "years",
  yr = "years",
  yrs = "years",
  year = "years",
  years = "years",
  mo = "months",
  month = "months",
  months = "months",
  w = "weeks",
  wk = "weeks",
  wks = "weeks",
  week = "weeks",
  weeks = "weeks",
  d = "days",
  day = "days",
  days = "days",
  h = "hours",
  hr = "hours",
  hrs = "hours",
  hour = "hours",
  hours = "hours",
  m = "minutes",
  min = "minutes",
  mins = "minutes",
  minute = "minutes",
  minutes = "minutes",
  s = "seconds",
  sec = "seconds",
  secs = "seconds",
  ms = "milliseconds",
  millisecond = "milliseconds",
  milliseconds = "milliseconds",
  second = "seconds",
  seconds = "seconds",
}

---"1 day, 2 hours" / "3h" / "7 days"
function M.parse_dur(s)
  if type(s) ~= "string" then
    return M.NULL
  end
  local ms, months, found, valid = 0, 0, false, true
  local rest = s:gsub("([+-]?%d*%.?%d+)%s*(%a+)", function(num, unit)
    local u = DUR_UNITS[unit:lower()]
    if not u then
      valid = false
      return ""
    end
    if u == "months" then
      months = months + tonumber(num)
    elseif u == "years" then
      months = months + tonumber(num) * 12
    else
      ms = ms + tonumber(num) * DUR_MS[u]
    end
    found = true
    return ""
  end)
  return found and valid and rest:gsub("[,%s]", "") == "" and M.dur(ms, months) or M.NULL
end

---------------------------------------------------------------- comparison

local function norm_link_path(l)
  return l.path .. "\0" .. l.kind .. "\0" .. (l.subpath or "")
end
M.link_key = norm_link_path -- eq identity of a link (unique() hashes on it)

local TYPE_RANK = {
  null = 0,
  array = 1,
  boolean = 2,
  date = 3,
  duration = 4,
  ["function"] = 5,
  link = 6,
  number = 7,
  object = 8,
  string = 9,
  widget = 10,
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
    return dur_approx_ms(a) == dur_approx_ms(b)
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
    return scalar(dur_approx_ms(a), dur_approx_ms(b))
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

---WHERE comparisons use the same total order as SORT.
---@return boolean|table
function M.compare_op(op, a, b)
  if op == "=" then
    return M.eq(a, b)
  elseif op == "!=" then
    return not M.eq(a, b)
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
      return M.date(shift_months(a.ts, b.months) + b.ms / 1000, a.prec)
    elseif ta == "duration" and tb == "date" then
      return M.date(shift_months(b.ts, a.months) + a.ms / 1000, b.prec)
    elseif ta == "duration" and tb == "duration" then
      return M.dur(a.ms + b.ms, a.months + b.months)
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
      return M.date(shift_months(a.ts, -b.months) - b.ms / 1000, a.prec)
    elseif ta == "duration" and tb == "duration" then
      return M.dur(a.ms - b.ms, a.months - b.months)
    end
  elseif op == "*" then
    if ta == "number" and tb == "number" then
      return a * b
    elseif ta == "duration" and tb == "number" then
      return M.dur(a.ms * b, a.months * b)
    elseif ta == "number" and tb == "duration" then
      return M.dur(b.ms * a, b.months * a)
    end
  elseif op == "/" then
    if tb == "number" and b == 0 then
      return M.NULL
    end
    if ta == "number" and tb == "number" then
      return a / b
    elseif ta == "duration" and tb == "number" then
      return M.dur(a.ms / b, a.months / b)
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

function M.to_display(v, settings, depth)
  settings = settings or require("obsidian-query.dataview.settings").defaults
  depth = depth or 0
  if depth > settings.maxRecursiveRenderDepth then
    return "..."
  end
  local t = M.typeof(v)
  if t == "null" then
    return (settings.renderNullAs:gsub("\\(%p)", "%1"))
  elseif t == "string" then
    return v
  elseif t == "number" then
    return v % 1 == 0 and tostring(math.floor(v)) or tostring(v)
  elseif t == "boolean" then
    return tostring(v)
  elseif t == "date" then
    local fmt = v.hour == 0 and v.minute == 0 and v.second == 0 and settings.defaultDateFormat
      or settings.defaultDateTimeFormat
    return require("obsidian-query.dataview.functions").registry.dateformat({}, { v, fmt })
  elseif t == "duration" then
    -- negative durations (date - later_date): display the magnitude, signed
    if dur_approx_ms(v) < 0 then
      return "-" .. M.to_display(M.dur(-v.ms, -(rawget(v, "months") or 0)), settings, depth)
    end
    local parts = {}
    local months = rawget(v, "months") or 0
    local years = math.floor(math.abs(months) / 12) * (months < 0 and -1 or 1)
    local mrem = months - years * 12
    if years ~= 0 then
      parts[#parts + 1] = years .. (math.abs(years) == 1 and " year" or " years")
    end
    if mrem ~= 0 then
      parts[#parts + 1] = mrem .. (math.abs(mrem) == 1 and " month" or " months")
    end
    local rem = v.ms
    for _, u in ipairs({ "days", "hours", "minutes", "seconds" }) do
      local n = math.floor(rem / DUR_MS[u])
      if n > 0 then
        parts[#parts + 1] = n .. " " .. (n == 1 and u:sub(1, -2) or u)
        rem = rem - n * DUR_MS[u]
      end
    end
    return #parts > 0 and table.concat(parts, ", ") or "0 seconds"
  elseif t == "widget" then
    return v.display or v.url
  elseif t == "link" then
    local name = vim.fn.fnamemodify(v.path, ":t"):gsub("%.md$", "")
    return v.display or (name .. (v.subpath and (" > " .. v.subpath) or ""))
  elseif t == "array" then
    local parts = {}
    for _, x in ipairs(v) do
      parts[#parts + 1] = M.to_display(x, settings, depth + 1)
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
