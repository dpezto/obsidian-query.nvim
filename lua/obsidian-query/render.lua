-- virt_lines builders shared by all fence engines
local M = {}

---Anchor a virt_lines block under a fenced code block, dodging render-markdown's
---line-concealed closing fence (virt_lines on a concealed row are swallowed).
---@param block TSNode fenced_code_block node
---@param buf integer
---@param lines table virt_lines
---@return table render.md.Mark
function M.anchored_mark(block, buf, lines)
  local _, _, end_row, end_col = block:range()
  local fence_row = end_col == 0 and end_row - 1 or end_row
  local anchor, above = fence_row + 1, true
  if anchor >= vim.api.nvim_buf_line_count(buf) then
    -- block at EOF: no next line, and the concealed fence row is unusable —
    -- hang the list below the last body line instead
    anchor, above = fence_row - 1, false
  end
  return {
    -- false: cursor crossing the anchor row must not collapse the list (viewport
    -- jumps by its height); insert mode already hides it via render_modes
    conceal = false,
    start_row = anchor,
    start_col = 0,
    opts = { virt_lines = lines, virt_lines_above = above },
  }
end

---@return table single pending-spinner virt line
function M.pending()
  return { { { "▏ …", "Comment" } } }
end

---One line per note (newest first), trailing count line.
---@param files string[]
---@return table virt_lines
function M.note_list(files)
  local lines = {}
  for _, f in ipairs(files) do
    lines[#lines + 1] = {
      { "▏ ", "RenderMarkdownBullet" },
      { vim.fn.fnamemodify(f, ":t:r"), "RenderMarkdownLink" },
    }
  end
  lines[#lines + 1] = {
    { "▏ ", "RenderMarkdownBullet" },
    { ("%d notes"):format(#files), "Comment" },
  }
  return lines
end

return M
