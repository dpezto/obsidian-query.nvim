-- Run: nvim --headless -u NONE -l tests/picker_spec.lua /path/to/snacks.nvim
-- Integration check against real Snacks windows, formatting and selection.
vim.opt.rtp:remove(vim.fn.stdpath("config"))
local root = vim.fs.dirname(vim.fs.dirname(debug.getinfo(1).source:sub(2)))
vim.opt.rtp:prepend(root)
vim.opt.rtp:prepend(assert(arg[1], "pass the snacks.nvim checkout path"))
require("snacks").setup({ picker = { enabled = true } })
require("obsidian-query.config").set({ picker = { style = "rich" }, icons = "ascii" })

local path = vim.fn.tempname() .. ".md"
local ok, err = xpcall(function()
  for _, reverse in ipairs({ false, true }) do
    vim.fn.writefile({ "- [ ] first", "- [ ] second", "- [ ] " }, path)
    local buf = vim.fn.bufnr(path)
    if buf ~= -1 then
      vim.api.nvim_buf_delete(buf, { force = true })
    end
    Snacks.config.picker.layout = { preset = "default", reverse = reverse }
    local tasks = {}
    for i, text in ipairs({ "first", "second", "" }) do
      tasks[i] = { path = path, line = i, text = text, status = " ", completed = false }
    end
    require("obsidian-query.dataview").pick({}, {}, {
      ok = true, data = { kind = "task", groups = { { items = tasks } } },
    })
    local picker = assert(Snacks.picker.get()[1])
    assert(vim.wait(2000, function()
      return picker.list.win:valid() and #picker.list.visible == 3
    end), "picker did not render")
    vim.cmd("stopinsert")
    vim.api.nvim_set_current_win(picker.list.win.win)
    local function shown(i)
      local row = picker.list:idx2row(i)
      return vim.api.nvim_buf_get_lines(picker.list.win.buf, row - 1, row, false)[1]
    end
    local function toggle(i)
      -- Move without dispatching CursorMoved: the action argument is stale.
      vim.api.nvim_win_set_cursor(picker.list.win.win, { picker.list:idx2row(i), 0 })
      picker.opts.actions.toggle_task(picker, picker:current())
    end
    toggle(1)
    toggle(2)
    assert(vim.deep_equal(vim.fn.readfile(path), { "- [x] first", "- [x] second", "- [ ] " }),
      "Ctrl-T toggled the previous task")
    assert(shown(1):find("[x] first", 1, true) and shown(2):find("[x] second", 1, true),
      "picker rows did not redraw immediately")
    toggle(3)
    assert(vim.fn.readfile(path)[3] == "- [x] " and shown(3):find("[x]", 1, true),
      "formatter mutation broke empty task toggling")
    toggle(2)
    assert(vim.fn.readfile(path)[2] == "- [ ] second" and shown(2):find("[ ] second", 1, true),
      "reopening did not redraw")
    assert(vim.wait(1000, function()
      local preview = vim.api.nvim_buf_get_lines(picker.preview.win.buf, 0, -1, false)
      return vim.deep_equal(preview, vim.fn.readfile(path))
    end), "preview and source disagree")
    picker:close()
    vim.wait(20, function() return false end) -- let pending preview callbacks finish
  end
end, debug.traceback)
vim.fn.delete(path)
assert(ok, err)
print("picker integration passed (normal and reversed lists)")
