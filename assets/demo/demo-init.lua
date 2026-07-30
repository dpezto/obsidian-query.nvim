-- Recording shim, loaded by every tape via `nvim --cmd 'luafile assets/demo/demo-init.lua'`.
-- Runs before the user config, so stubs below win the require() race.

-- The Neovim config auto-starts livesync-bridge for whatever OBSIDIAN_BASE_DIR
-- points at; recordings must never spawn a sync process against the demo vault.
package.preload["aux.livesync-bridge"] = function()
  return { setup = function() end }
end

-- Recordings need no LSP; ltex-style servers flash "Checking document"
-- notifications over the shot (and force-stopping them flashes "Client quit"
-- warnings instead). Keep servers from starting at all.
vim.lsp.enable = function() end
-- obsidian.nvim runs its own in-process obsidian-ls through vim.lsp.start and
-- the plugin needs it; only outside servers are blocked.
local real_start = vim.lsp.start
---@diagnostic disable-next-line: duplicate-set-field
vim.lsp.start = function(cfg, opts)
  if cfg and cfg.name and cfg.name:find("obsidian") then
    return real_start(cfg, opts)
  end
end

-- Freeze the statusline clock so GIFs are reproducible and don't leak the real
-- wall-clock. The lualine clock reads os.date("%R") (HH:MM) and os.date("%I")
-- (hour → clock-face glyph); pin just those two to 13:37. Every other format
-- passes through, so note dates and query results stay live.
local real_date = os.date
---@diagnostic disable-next-line: duplicate-set-field
os.date = function(fmt, t)
  if fmt == "%R" then
    return "13:37"
  elseif fmt == "%I" then
    return "01" -- 1 o'clock face for the 13:37 hour
  end
  return real_date(fmt, t)
end
