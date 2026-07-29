-- Total DQL expression evaluator — never throws; failures evaluate to NULL.
-- env = { page = Page, this = Page|NULL, extra = table?, funcs = registry, now = Date }
local value = require("obsidian-query.dataview.value")

local M = {}

local NULL = value.NULL

local function norm(v)
  if v == nil then
    return NULL
  end
  return v
end

---index on arrays with a string key = element-wise swizzle (rows.file.link)
function M.index(obj, key)
  local t = value.typeof(obj)
  if t == "null" then
    return NULL
  end
  if t == "array" and type(key) == "string" then
    local out = {}
    for _, el in ipairs(obj) do
      out[#out + 1] = M.index(el, key)
    end
    return value.array(out)
  end
  if t == "array" and type(key) == "number" then
    return norm(obj[key]) -- 1-based (Lua-consistent; documented deviation)
  end
  if type(obj) == "table" then
    return norm(obj[key])
  end
  return NULL
end

local function resolve_ident(name, env)
  if env.extra then
    local v = env.extra[name]
    if v ~= nil then
      return v
    end
  end
  if env.page then
    local v = env.page[name]
    if v ~= nil then
      return v
    end
    -- overlay rows chain via __index; plain miss falls through
  end
  if name == "this" then
    return norm(env.this)
  end
  if env.funcs and env.funcs[name:lower()] then
    local fname = name:lower()
    return function(args)
      return env.funcs[fname](env, args)
    end
  end
  return NULL
end

local function date_literal(lit, env)
  local now = env.now or value.date(os.time(), "datetime")
  local function day_start(ts)
    local t = os.date("*t", math.floor(ts))
    return os.time({ year = t.year, month = t.month, day = t.day, hour = 0, min = 0, sec = 0 })
  end
  if lit == "now" then
    return now
  elseif lit == "today" then
    return value.date(day_start(now.ts), "date")
  elseif lit == "tomorrow" then
    return value.date(day_start(now.ts) + 86400, "date")
  elseif lit == "yesterday" then
    return value.date(day_start(now.ts) - 86400, "date")
  elseif lit == "sow" then
    local t = os.date("*t", math.floor(now.ts))
    local wd = (t.wday + 5) % 7 -- 0 = Monday
    return value.date(day_start(now.ts) - wd * 86400, "date")
  elseif lit == "eow" then
    local t = os.date("*t", math.floor(now.ts))
    local wd = (t.wday + 5) % 7
    return value.date(day_start(now.ts) + (6 - wd) * 86400, "date")
  elseif lit == "som" then
    local t = os.date("*t", math.floor(now.ts))
    return value.date(os.time({ year = t.year, month = t.month, day = 1, hour = 0 }), "date")
  elseif lit == "eom" then
    local t = os.date("*t", math.floor(now.ts))
    local nm = os.time({ year = t.year, month = t.month + 1, day = 1, hour = 0 })
    return value.date(nm - 86400, "date")
  elseif lit == "soy" then
    local t = os.date("*t", math.floor(now.ts))
    return value.date(os.time({ year = t.year, month = 1, day = 1, hour = 0 }), "date")
  elseif lit == "eoy" then
    local t = os.date("*t", math.floor(now.ts))
    return value.date(os.time({ year = t.year, month = 12, day = 31, hour = 0 }), "date")
  end
  return value.parse_date(lit)
end

local eval_node

eval_node = function(ast, env)
  local k = ast.k
  if k == "lit" then
    return ast.v
  elseif k == "null" then
    return NULL
  elseif k == "ident" then
    return resolve_ident(ast.name, env)
  elseif k == "link" then
    local path, display = ast.raw:match("^([^|]*)|?(.*)$")
    return value.link(vim.trim(path), { display = display ~= "" and display or nil })
  elseif k == "list" then
    local out = {}
    for _, item in ipairs(ast.items) do
      out[#out + 1] = eval_node(item, env)
    end
    return value.array(out)
  elseif k == "index" then
    local obj = eval_node(ast.obj, env)
    local key = eval_node(ast.key, env)
    if value.typeof(key) == "null" then
      return NULL
    end
    return M.index(obj, key)
  elseif k == "call" then
    local fn = eval_node(ast.fn, env)
    if type(fn) ~= "function" then
      return NULL
    end
    local args = {}
    for i, a in ipairs(ast.args) do
      args[i] = eval_node(a, env)
    end
    local ok, res = pcall(fn, args)
    return ok and norm(res) or NULL
  elseif k == "datelit" then
    if ast.fn == "date" then
      return date_literal(ast.lit, env)
    end
    return value.parse_dur(ast.lit)
  elseif k == "lambda" then
    return function(args)
      local extra = setmetatable({}, { __index = env.extra })
      for i, p in ipairs(ast.params) do
        extra[p] = norm(args[i])
      end
      return eval_node(ast.body, vim.tbl_extend("keep", { extra = extra }, env))
    end
  elseif k == "cmp" then
    local res = value.compare_op(ast.op, eval_node(ast.l, env), eval_node(ast.r, env))
    return res
  elseif k == "bin" then
    return value.arith(ast.op, eval_node(ast.l, env), eval_node(ast.r, env))
  elseif k == "and" then
    return value.truthy(eval_node(ast.l, env)) and value.truthy(eval_node(ast.r, env))
  elseif k == "or" then
    return value.truthy(eval_node(ast.l, env)) or value.truthy(eval_node(ast.r, env))
  elseif k == "not" then
    return not value.truthy(eval_node(ast.e, env))
  elseif k == "neg" then
    local v = eval_node(ast.e, env)
    local t = value.typeof(v)
    if t == "number" then
      return -v
    elseif t == "duration" then
      return value.dur(-v.ms)
    end
    return NULL
  end
  return NULL
end

---@return any dv-value (never raises)
function M.expr(ast, env)
  local ok, res = pcall(eval_node, ast, env)
  return ok and norm(res) or NULL
end

return M
