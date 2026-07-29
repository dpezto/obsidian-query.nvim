-- Plugin options. Kept in a leaf module so any component can read them
-- without require cycles.
local M = {}

---@class obsidian-query.Opts
M.opts = {
  picker = {
    -- "file": snacks' stock file formatter (paths + icons).
    -- "rich": query-shaped rows (dates, cells, task text).
    style = "file",
  },
  -- Cap inline-rendered rows/notes/tasks; excess becomes a "+N more" line.
  -- nil = unlimited (j/k jump across tall virt_lines blocks; scroll with
  -- <C-e>/<C-y> or use the <CR> picker).
  max_inline_rows = nil,
}

function M.set(user)
  M.opts = vim.tbl_deep_extend("force", M.opts, user or {})
end

return M
