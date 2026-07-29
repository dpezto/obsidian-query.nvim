-- Presentation helpers shared by all fence engines: virt_lines anchoring,
-- clipping, key hints, the result picker and render-markdown re-render nudges.
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
    opts = {
      virt_lines = lines,
      virt_lines_above = above,
      -- wide results (tables) scroll with the window instead of wrapping
      virt_lines_overflow = "scroll",
    },
  }
end

-- Nerd-font key glyphs.
local KEY_ICONS = {
  ["<Left>"] = " ",
  ["<Right>"] = " ",
  ["<Up>"] = " ",
  ["<Down>"] = " ",
  ["<CR>"] = "󰌑 ",
  ["<Home>"] = "󰋜 ",
  ["<Esc>"] = "󱊷 ",
  ["<Tab>"] = "󰌒 ",
}

---Key hint, always trailing-padded: the glyph for known keys, the literal
---`<Key>` for the rest.
---@param lhs string e.g. "<Left>"
---@return string
function M.key(lhs)
  return KEY_ICONS[lhs] or (lhs .. " ")
end

---@return table single pending-spinner virt line
function M.pending()
  return { { { "▏ …", "Comment" } } }
end

---Clip to `w` display columns, ellipsis when it doesn't fit. Character-wise,
---so multibyte text can't be cut mid-codepoint.
---@param s string
---@param w integer
---@return string
function M.clip(s, w)
  if vim.fn.strdisplaywidth(s) <= w then
    return s
  end
  return vim.fn.strcharpart(s, 0, w - 1) .. "…"
end

---Result picker. Items carry `display` (snacks Highlight[]) so results show
---as query rows, not raw file paths; `text` stays the fuzzy-match string.
---@param title string
---@param items table[]
---@param opts table? extra Snacks.picker config (actions, keys, ...)
function M.picker(title, items, opts)
  if #items == 0 then
    return
  end
  local style = require("obsidian-query.config").opts.picker.style
  Snacks.picker(vim.tbl_deep_extend("force", {
    title = title,
    items = items,
    format = style == "rich" and function(item)
      return item.display
    end or "file",
  }, opts or {}))
end

---render-markdown silently drops render calls that arrive while a render is in
---flight AND restarts its debounce on every dropped call, so retries back off
---exponentially to outgrow any window. Stops as soon as `done()` reports a
---parse pass consumed the result — self-healing instead of a magic delay.
---@param done fun(): boolean
---@param render fun()
function M.retry(done, render)
  local tries, delay = 0, 150
  local function attempt()
    if done() or tries >= 5 then
      return
    end
    tries = tries + 1
    render()
    delay = delay * 2 -- 300, 600, 1200, 2400ms between attempts
    vim.defer_fn(attempt, delay)
  end
  vim.defer_fn(attempt, delay)
end

return M
