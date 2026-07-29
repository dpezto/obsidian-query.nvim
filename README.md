# obsidian-query.nvim

Renders Obsidian ```query (core Search) and ```dataview (DQL) fences inline
in Neovim via render-markdown custom handlers; `<CR>` opens results in
snacks.picker; double-click a calendar day for that day's notes; inline
`= expr` queries render in prose. Engines are pure Lua — Obsidian is never
involved.

Requires: obsidian.nvim (community fork, `cache = { enabled = true }`),
render-markdown.nvim, snacks.nvim, ripgrep. Optional: blink.cmp
(`module = "obsidian-query.blink"` source).

## Setup (lazy.nvim)

    {
      "dpezto/obsidian-query.nvim",
      ft = "markdown",
      opts = {
        picker = { style = "file" }, -- or "rich": query-shaped picker rows
        max_inline_rows = nil,       -- e.g. 15 to cap inline output
      },
    }

Wire the render-markdown handlers:

    custom_handlers = {
      markdown = { extends = true, parse = function(ctx) return require("obsidian-query").parse(ctx) end },
      markdown_inline = { extends = true, parse = function(ctx) return require("obsidian-query.inline").parse(ctx) end },
    }

## Decision record

- **Highlighting = lexer-driven extmarks, not a tree-sitter grammar.**
  The engines' lexers emit byte spans; what highlights is exactly what
  parses (one source of truth). A TS grammar would mean a second
  implementation of each language that drifts, plus per-machine parser
  builds (incl. the Pi Zero where treesitter is gated off). Adopt
  biozz/tree-sitter-dataview only if it matures into nvim-treesitter;
  switch = delete highlight.lua + one injection query.
- **Completion = in-process blink source, not an LSP.** Same logic either
  way; an LSP adds a process and packaging for zero capability in a
  single-editor setup. Matches the 5 existing custom blink providers.
- **Internal-API couplings (the real fragility):** obsidian.nvim's cache
  (`obsidian.cache.notes.*`, plugin pinned `version = "*"`) and
  render-markdown's drop-while-rendering decorator (worked around with
  retry-until-rendered in init.lua). Both are probed by
  `:checkhealth obsidian-query` — run it after `:Lazy update`.

## Known deviations from Obsidian/dataview

Fixed-factor duration math (mo=30d, y=365d), 1-based array indexing,
PCRE→Lua-pattern regex shim (no alternation/lookaround), last-wins for
repeated inline-field keys, naive local time, `file.lists` = checkbox
items only, no dataviewjs, no csv() source, no file.starred.

## Recipes

Single-month calendar — CALENDAR is just a projection, so filter rows:

    ```dataview
    CALENDAR FROM "Bitacora"
    WHERE file.day >= date(2026-06-01) AND file.day <= date(2026-06-30)
    ```

Double-click a dotted day to open a picker of that day's notes; `<CR>` on
the fence lists every dated note.

## Tests

    nvim -l tests/search_spec.lua
    nvim -l tests/dataview_spec.lua

Specs strip the user config from rtp, so they always test this repo's tree.
