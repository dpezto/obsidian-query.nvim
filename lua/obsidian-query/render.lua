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

-- Nerd-font key glyphs; ASCII when the config says no nerd font.
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
---`<Key>` for the rest (and for everything without a nerd font).
---@param lhs string e.g. "<Left>"
---@return string
function M.key(lhs)
  if not require("obsidian-query.config").nerd_font() then
    return lhs .. " "
  end
  return KEY_ICONS[lhs] or (lhs .. " ")
end

---@class obsidian-query.Checkbox
---@field icon string trailing-padded glyph
---@field highlight string
---@field scope_highlight string? highlight for the task text (strike-through, …)

---render-markdown's component for a raw state, nil when render-markdown isn't
---loaded or its checkbox rendering is off. Custom states are matched on `raw`
---the same way render-markdown does it (lib/resolved.lua: keyed by `raw:lower()`).
---A state with no component falls back to the list bullet plus the bare state
---char — which is what the buffer shows for it: render-markdown gives up on the
---checkbox and renders the line as an ordinary list item (`● [~] text`).
---@param status string
---@return obsidian-query.Checkbox?
local function rm_checkbox(status)
  local ok, state = pcall(require, "render-markdown.state")
  if not ok then
    return nil
  end
  -- ponytail: buffer 0 — in the picker that's the picker buffer, so per-filetype
  -- `overrides` don't reach here. Thread a buf through if anyone ever sets them.
  local got, cfg = pcall(function()
    return state.get(0)
  end)
  if not got or not cfg or not cfg.checkbox or cfg.checkbox.enabled == false then
    return nil
  end
  local component
  if status == " " then
    component = cfg.checkbox.unchecked
  elseif status == "x" or status == "X" then
    component = cfg.checkbox.checked
  else
    local raw = ("[%s]"):format(status):lower()
    for _, custom in pairs(cfg.checkbox.custom or {}) do
      if custom.raw and custom.raw:lower() == raw then
        component = { icon = custom.rendered, highlight = custom.highlight, scope_highlight = custom.scope_highlight }
        break
      end
    end
    if not component then
      local icons = cfg.bullet and cfg.bullet.icons
      local bullet = type(icons) == "table" and icons[1] or icons
      component = {
        icon = ("%s %s"):format(type(bullet) == "string" and bullet or "●", status),
        highlight = "RenderMarkdownBullet",
      }
    end
  end
  if not component or type(component.icon) ~= "string" then
    return nil
  end
  local icon = component.icon
  if not icon:match("%s$") then
    icon = icon .. " "
  end
  return { icon = icon, highlight = component.highlight, scope_highlight = component.scope_highlight }
end

---Task checkbox component for a raw state char, icon trailing-padded.
---Mirrors render-markdown: `checkbox.unchecked` / `checkbox.checked` plus any
---`checkbox.custom` entry whose `raw` matches, so results look like the buffer.
---States it has no component for get the list bullet plus the bare state char
---(`● ~ `), matching how the buffer renders them.
---@param status string the single char inside the brackets (" ", "x", "-", …)
---@return obsidian-query.Checkbox
function M.checkbox(status)
  status = status or " "
  local done = status == "x" or status == "X"
  if require("obsidian-query.config").nerd_font() then
    local component = rm_checkbox(status)
    if component then
      return component
    end
  end
  return {
    icon = ("[%s] "):format(status),
    highlight = done and "RenderMarkdownChecked" or "RenderMarkdownUnchecked",
    scope_highlight = done and "@markup.strikethrough" or nil,
  }
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

---Result picker. Items carry `display` (segment list: { {text, hl?}, ... })
---so results show as query rows, not raw file paths; `text` stays the
---fuzzy-match string. Dispatches to the configured backend.
---@param title string
---@param items table[] { file, text, pos?, display }
---@param opts table? { toggle = fun(item): boolean? } TASK checkbox toggling
function M.picker(title, items, opts)
  if #items == 0 then
    return
  end
  require("obsidian-query.picker").open(title, items, opts)
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
