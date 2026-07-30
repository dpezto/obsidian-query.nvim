-- Plugin options. Kept in a leaf module so any component can read them
-- without require cycles.
local M = {}

---@class obsidian-query.Opts
M.opts = {
  picker = {
    -- "auto": first available of snacks > telescope > fzf-lua > vim.ui.select.
    -- Or pin one: "snacks" | "telescope" | "fzf-lua" | "select".
    backend = "auto",
    -- "file": plain file rows (snacks' stock formatter / paths elsewhere).
    -- "rich": query-shaped rows (dates, cells, task text).
    style = "file",
  },
  -- "auto": nerd-font glyphs unless vim.g.have_nerd_font == false.
  -- "nerd" | "ascii" to force.
  icons = "auto",
  -- Cap inline-rendered rows/notes/tasks; excess becomes a "+N more" line
  -- (the <CR> picker always holds the full set). nil = unlimited — beware:
  -- the cursor can't enter virt_lines, so j/k jump across the whole block;
  -- scroll tall results with <C-e>/<C-y>.
  max_inline_rows = 12,
}

---Inline row cap; math.huge when unset.
---@return number
function M.max_rows()
  return M.opts.max_inline_rows or math.huge
end

---Whether to draw nerd-font glyphs.
---@return boolean
function M.nerd_font()
  local mode = M.opts.icons
  if mode == "nerd" then
    return true
  elseif mode == "ascii" then
    return false
  end
  return vim.g.have_nerd_font ~= false
end

function M.set(user)
  M.opts = vim.tbl_deep_extend("force", M.opts, user or {})
end

return M
