-- :checkhealth obsidian-query — verifies the two internal-API couplings
-- (obsidian.nvim cache, render-markdown api) that can drift on :Lazy update.
local M = {}

local h = vim.health

function M.check()
  h.start("obsidian-query")

  -- ripgrep
  if vim.fn.executable("rg") == 1 then
    h.ok("ripgrep on PATH")
  else
    h.error("ripgrep not found — query fences cannot fetch")
  end

  -- treesitter markdown
  local ts_ok = pcall(vim.treesitter.language.add, "markdown")
  if ts_ok then
    h.ok("treesitter markdown parser available")
  else
    h.error("treesitter markdown parser missing — fences cannot be located")
  end

  -- render-markdown api surface
  local rm_ok, rm_api = pcall(require, "render-markdown.api")
  if rm_ok and type(rm_api.render) == "function" then
    h.ok("render-markdown.api.render present")
  else
    h.error("render-markdown.api.render missing — re-renders after fetch will not land (API drift?)")
  end

  -- obsidian.nvim cache surface + row shape
  local c_ok, cache = pcall(require, "obsidian.cache")
  if not c_ok then
    h.error("obsidian.cache module missing — dataview engine dead (API drift?)")
  elseif not cache.is_enabled() then
    h.error("obsidian.nvim cache disabled — set cache = { enabled = true }")
  elseif not cache.is_ready() then
    h.warn("obsidian.nvim cache not ready yet (still indexing?)")
  else
    h.ok(("obsidian.nvim cache ready (%d notes)"):format(cache.notes.count()))
    -- probe a row that has tasks (rows without tasks may omit the key)
    local probe, tasked
    for _, row in pairs(cache.notes.all()) do
      probe = probe or row
      if row.tasks and row.tasks[1] then
        tasked = row
        break
      end
    end
    if probe then
      local bad = false
      for _, key in ipairs({ "mtime", "tags", "properties" }) do
        if probe[key] == nil then
          bad = true
          h.error(("cache row missing %q — row schema drifted, page building will break"):format(key))
        end
      end
      local t = tasked and tasked.tasks[1]
      if t and (t.line == nil or t.line == 0) then
        bad = true
        h.error("cache task lines look 0-indexed — picker jumps will be off by one (schema drift)")
      end
      if not bad then
        h.ok("cache row shape as expected")
      end
    end
  end

  -- blink source
  if pcall(require, "obsidian-query.blink") then
    h.ok("blink source module loads")
  else
    h.warn("blink source failed to load — fence completion unavailable")
  end
end

return M
