-- Dataview 0.5.68 defaults; vault overrides are cached by file timestamp.
local M = {}
M.defaults = {
  renderNullAs = "\\-",
  taskCompletionTracking = false,
  taskCompletionUseEmojiShorthand = false,
  taskCompletionText = "completion",
  taskCompletionDateFormat = "yyyy-MM-dd",
  recursiveSubTaskCompletion = false,
  warnOnEmptyResult = true,
  defaultDateFormat = "MMMM dd, yyyy",
  defaultDateTimeFormat = "h:mm a - MMMM dd, yyyy",
  maxRecursiveRenderDepth = 4,
  tableIdColumnName = "File",
  tableGroupColumnName = "Group",
  showResultCount = true,
  inlineQueryPrefix = "=",
  enableInlineDataview = true,
  inlineQueriesInCodeblocks = true,
}
local cache = {}
function M.get(root)
  local path = root .. "/.obsidian/plugins/dataview/data.json"
  local st = vim.uv.fs_stat(path)
  local key = st and table.concat({ st.mtime.sec, st.mtime.nsec, st.size }, ":") or "missing"
  if cache[root] and cache[root].key == key then
    return cache[root].settings
  end
  local settings = vim.deepcopy(M.defaults)
  local fd = st and io.open(path, "r")
  if fd then
    local raw = fd:read("*a")
    fd:close()
    local ok, data = pcall(vim.json.decode, raw)
    if ok and type(data) == "table" then
      for k, default in pairs(M.defaults) do
        if type(data[k]) == type(default) then
          settings[k] = data[k]
        end
      end
    end
  end
  cache[root] = { key = key, settings = settings }
  return settings
end
return M
