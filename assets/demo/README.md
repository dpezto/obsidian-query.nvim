# Recording the GIFs

Run from the repository root:

```sh
vhs assets/tapes/hero.tape
vhs assets/tapes/tasks.tape
vhs assets/tapes/search.tape
vhs assets/tapes/calendar.tape
vhs assets/tapes/completion.tape
```

Each tape sources `setup.sh` in Bash to create a fresh temporary vault, then
opens Neovim with `demo-init.lua`. No manual setup is needed. Dates are
relative to the recording day. GIFs are written to `assets/`.

The TASK recording completes two tasks, closes the picker to show the new
count, then reopens the filtered results.

## Requirements

- [VHS](https://github.com/charmbracelet/vhs) 0.11.0, ffmpeg, and ttyd.
  Version 0.12.0 [silently skips exports](https://github.com/charmbracelet/vhs/issues/787).
- FiraCode Nerd Font, or change `FontFamily` in `../tapes/style.tape`.
- Your local Neovim config with obsidian.nvim, render-markdown.nvim,
  snacks.nvim, and this checkout loaded as a development plugin.
- blink.cmp with the `obsidian_query` source for the completion recording.

Your config must discover vaults under `$OBSIDIAN_BASE_DIR`; the setup script
points it at the generated demo root. The recording shim disables the local
livesync bridge and external LSP servers, and fixes the statusline clock.
Neovim's diagnostic log goes into the temporary directory too.

To inspect the demo manually, start Bash and source the setup script:

```sh
bash
source assets/demo/setup.sh
nvim --cmd 'luafile assets/demo/demo-init.lua' "$OBSIDIAN_BASE_DIR/Demo/Open-tasks.md"
```

The setup script prints its temporary vault path. Delete that generated
`obsidian-query-demo.*` directory when finished; each recording creates a new one.
