-- Picker backends. One item contract for every backend:
--   { file: string, text: string, pos?: {lnum, col0}, display: { {text, hl?}, ... } }
-- opts.toggle (TASK pickers) flips the item's checkbox on disk and mutates
-- item.display in place; each backend just re-draws the row afterwards.
local M = {}

local function style()
  return require("obsidian-query.config").opts.picker.style
end

---Jump to an item's file/position (backends without their own jump logic).
local function jump(item)
  if not item then
    return
  end
  vim.cmd.edit(vim.fn.fnameescape(item.file))
  if item.pos then
    pcall(vim.api.nvim_win_set_cursor, 0, { item.pos[1], math.max(item.pos[2] or 0, 0) })
  end
end

---Flatten display segments to plain text.
local function plain(item)
  if style() ~= "rich" or not item.display then
    return vim.fn.fnamemodify(item.file, ":.") .. (item.pos and (":" .. item.pos[1]) or "")
  end
  local parts = {}
  for _, seg in ipairs(item.display) do
    parts[#parts + 1] = seg[1]
  end
  return table.concat(parts)
end

-- ---------------------------------------------------------------- snacks --
local function snacks_open(title, items, opts)
  local extra
  if opts and opts.toggle then
    local function toggle_action(picker, item)
      if opts.toggle(item) == nil then
        return
      end
      pcall(function()
        picker.list.dirty = true -- render() is a no-op unless marked dirty
        picker.list:render()
      end)
      pcall(function()
        picker.preview:refresh(picker) -- drop the memoized item so the file re-reads
      end)
    end
    extra = {
      actions = { toggle_task = toggle_action },
      win = {
        input = { keys = { ["<c-t>"] = { "toggle_task", mode = { "n", "i" }, desc = "Toggle task" } } },
        list = { keys = { ["<c-t>"] = { "toggle_task", desc = "Toggle task" } } },
      },
    }
  end
  Snacks.picker(vim.tbl_deep_extend("force", {
    title = title,
    items = items,
    format = style() == "rich" and function(item)
      return item.display
    end or "file",
  }, extra or {}))
end

-- ------------------------------------------------------------- telescope --
local function telescope_open(title, items, opts)
  local pickers = require("telescope.pickers")
  local finders = require("telescope.finders")
  local conf = require("telescope.config").values
  local actions = require("telescope.actions")
  local action_state = require("telescope.actions.state")

  local function entry_maker(item)
    return {
      value = item,
      ordinal = item.text,
      filename = item.file,
      lnum = item.pos and item.pos[1] or nil,
      col = item.pos and item.pos[2] and item.pos[2] + 1 or nil,
      display = function()
        if style() ~= "rich" or not item.display then
          return plain(item)
        end
        local text, hls, byte = {}, {}, 0
        for _, seg in ipairs(item.display) do
          text[#text + 1] = seg[1]
          if seg[2] then
            hls[#hls + 1] = { { byte, byte + #seg[1] }, seg[2] }
          end
          byte = byte + #seg[1]
        end
        return table.concat(text), hls
      end,
    }
  end

  pickers
    .new({}, {
      prompt_title = title,
      finder = finders.new_table({ results = items, entry_maker = entry_maker }),
      sorter = conf.generic_sorter({}),
      previewer = conf.qflist_previewer({}),
      attach_mappings = function(bufnr, map)
        if opts and opts.toggle then
          map({ "i", "n" }, "<C-t>", function()
            local entry = action_state.get_selected_entry()
            if entry and opts.toggle(entry.value) ~= nil then
              local picker = action_state.get_current_picker(bufnr)
              picker:refresh(picker.finder, { reset_prompt = false })
            end
          end)
        end
        return true -- keep telescope's default <CR> (jumps via filename/lnum)
      end,
    })
    :find()
end

-- --------------------------------------------------------------- fzf-lua --
local function fzf_open(title, items, opts)
  local fzf = require("fzf-lua")
  -- fzf hands back plain display strings; index them for the reverse lookup
  local function lines()
    local out, lookup = {}, {}
    for _, item in ipairs(items) do
      local line = plain(item)
      -- disambiguate duplicate rows instead of silently merging them
      while lookup[line] do
        line = line .. " "
      end
      lookup[line] = item
      out[#out + 1] = line
    end
    return out, lookup
  end
  local out, lookup = lines()
  local acts = {
    ["default"] = function(selected)
      jump(lookup[selected and selected[1]])
    end,
  }
  if opts and opts.toggle then
    -- `reload = true` needs string (shell) contents; ours is a Lua table, so
    -- resume instead: the file is toggled, the visible row refreshes on next open
    acts["ctrl-t"] = {
      function(selected)
        local item = lookup[selected and selected[1]]
        if item then
          opts.toggle(item)
        end
      end,
      fzf.actions.resume,
    }
  end
  fzf.fzf_exec(out, {
    prompt = title .. "> ",
    actions = acts,
  })
end

-- ---------------------------------------------------------- vim.ui.select --
local function select_open(title, items, _)
  vim.ui.select(items, {
    prompt = title,
    format_item = plain,
  }, jump)
end

local BACKENDS = {
  { name = "snacks", avail = function()
    return _G.Snacks and Snacks.picker ~= nil
  end, open = snacks_open },
  { name = "telescope", avail = function()
    return pcall(require, "telescope")
  end, open = telescope_open },
  { name = "fzf-lua", avail = function()
    return pcall(require, "fzf-lua")
  end, open = fzf_open },
  { name = "select", avail = function()
    return true
  end, open = select_open },
}

---Resolve the configured backend to a name ("snacks"|"telescope"|"fzf-lua"|"select").
---@return string
function M.backend()
  local want = require("obsidian-query.config").opts.picker.backend
  for _, b in ipairs(BACKENDS) do
    if (want == "auto" or want == b.name) and b.avail() then
      return b.name
    end
  end
  return "select" -- pinned backend missing: degrade instead of erroring
end

---@param title string
---@param items table[]
---@param opts table? { toggle = fun(item): boolean? }
function M.open(title, items, opts)
  local name = M.backend()
  for _, b in ipairs(BACKENDS) do
    if b.name == name then
      return b.open(title, items, opts)
    end
  end
end

return M
