# Recording the README GIFs

The tapes in `../tapes/` record against a **throwaway** Obsidian vault, so
recording never touches (or leaks) your real notes. They reuse your local
Neovim config so the GIFs match whatever colorscheme/plugins/font you already
run.

```sh
source assets/demo/setup.sh       # builds ~/.cache/obsidian-query-demo/Demo, exports OBSIDIAN_BASE_DIR
vhs assets/tapes/hero.tape        # -> assets/hero.gif
vhs assets/tapes/calendar.tape
vhs assets/tapes/tasks.tape
vhs assets/tapes/completion.tape
vhs assets/tapes/search.tape
```

## Prerequisites

- [`vhs`](https://github.com/charmbracelet/vhs) — records the tapes.
- A Nerd Font — the tapes set `FontFamily "FiraCode Nerd Font"` in
  `../tapes/style.tape`; swap it there if you use another.
- A local Neovim config with the plugin's full stack wired: obsidian.nvim
  (cache enabled, vaults discovered under `$OBSIDIAN_BASE_DIR`),
  render-markdown.nvim with the obsidian-query handlers, snacks.nvim, and —
  for `completion.gif` — blink.cmp with the `obsidian_query` source.

## How isolation works

- `setup.sh` builds the demo vault (books, projects with emoji-dated tasks,
  ~5 weeks of daily notes for the calendar heat map, one note per query shot)
  and exports `OBSIDIAN_BASE_DIR` so the Neovim config discovers only it.
  Dates are generated relative to today, so due dates and the calendar are
  always live.
- `demo-init.lua` is loaded with `--cmd` before the user config: it stubs the
  livesync-bridge autostart (no sync process against the demo vault) and
  freezes the statusline clock at 13:37 so recordings are reproducible.
