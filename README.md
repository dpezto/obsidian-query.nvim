# obsidian-query.nvim

Live [Obsidian](https://obsidian.md) queries inside Neovim — no Obsidian
required.

Renders Obsidian's `query` (core Search) and  `dataview`
([Dataview](https://github.com/blacksmithgu/obsidian-dataview) DQL) code
fences as inline results, exactly where Obsidian would render them. Both
query languages are re-implemented in pure Lua and evaluated against your
vault's markdown files, so results are always live — Obsidian never runs.

```
```query                          ▏ 2026-07-28
path:Bitacora tag:#project       ▏ 2026-07-03
```                    ──────▶   ▏ 2026-06-26
                                 ▏ 3 notes
```

- **Search fences** — the full core-Search query language: terms, phrases,
  `/regex/`, `OR`/`-`/`(...)`, `tag:` `path:` `file:` `content:` `line:()`
  `section:()` `block:()` `task:` `[property]`, smart case. Matched lines
  render under each note. Like Obsidian, every vault file is matchable by
  `path:` / `file:` / bare filename — attachments included; content
  operators only ever hit notes.
- **Dataview fences** — DQL `TABLE` / `LIST` / `TASK` / `CALENDAR` with
  `FROM` / `WHERE` / `SORT` / `GROUP BY` / `FLATTEN` / `LIMIT`, a full
  expression language with lambdas, ~60 functions, typed dates / durations
  / links, implicit `file.*` fields, inline `Key:: value` fields, tasks
  with `[due:: …]` and Tasks-plugin emoji dates, `FROM csv("data.csv")`.
- **Inline queries** — `` `= this.file.mtime` `` in prose renders its value
  as inline virtual text.
- **Interactive** — `<CR>` on a fence opens the result set in a
  [snacks.nvim](https://github.com/folke/snacks.nvim) picker (jumping to
  exact lines for content matches and tasks); click a calendar day
  for that day's notes.
- **Syntax highlighting** for both fence languages, driven by the same
  lexers that execute the queries.
- **Completion** — an optional [blink.cmp](https://github.com/Saghen/blink.cmp)
  source offering context-aware operators, DQL keywords and functions with
  inline documentation, plus your vault's tags, folders, note names and
  frontmatter properties.

Rendering is done with virtual lines: results appear in normal mode and
collapse back to the raw fence while you edit — your files on disk only
ever contain the query.

## Requirements

- Neovim ≥ 0.11
- [obsidian.nvim](https://github.com/obsidian-nvim/obsidian.nvim)
  (community fork) with the cache enabled — the dataview engine reads its
  metadata index:

  ```lua
  require("obsidian").setup({ cache = { enabled = true }, ... })
  ```
- [render-markdown.nvim](https://github.com/MeanderingProgrammer/render-markdown.nvim)
- [snacks.nvim](https://github.com/folke/snacks.nvim) (pickers)
- [ripgrep](https://github.com/BurntSushi/ripgrep) (already required by obsidian.nvim)
- a Nerd Font, for the key glyphs in result hints

## Installation

[lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  "dpezto/obsidian-query.nvim",
  ft = "markdown",
}
```

Wire the render-markdown handlers (this is what puts results on screen):

```lua
{
  "MeanderingProgrammer/render-markdown.nvim",
  opts = {
    custom_handlers = {
      markdown = {
        extends = true,
        parse = function(ctx)
          return require("obsidian-query").parse(ctx)
        end,
      },
      -- optional: inline `= expr` queries in prose
      markdown_inline = {
        extends = true,
        parse = function(ctx)
          return require("obsidian-query.inline").parse(ctx)
        end,
      },
    },
  },
}
```

Optional blink.cmp source:

```lua
sources = {
  per_filetype = { markdown = { inherit_defaults = true, "obsidian_query" } },
  providers = {
    obsidian_query = { name = "ObsidianQuery", module = "obsidian-query.blink" },
  },
}
```

Run `:checkhealth obsidian-query` to verify the setup.

## Configuration

Defaults:

```lua
opts = {
  picker = {
    -- "file": snacks' stock file formatter (paths + icons)
    -- "rich": query-shaped rows (dates, table cells, source note + task text)
    style = "file",
  },
  -- Cap inline-rendered rows; excess becomes a "+N more — <CR> for all"
  -- line. nil = unlimited.
  max_inline_rows = nil,
}
```

Keymaps are buffer-local to vault notes and set automatically:

| Mapping | Action |
|---|---|
| `<CR>` | On a query/dataview fence: open results in a picker, titled by query kind and source — `TABLE · "Coding" (24)`. Elsewhere: obsidian.nvim's smart action, unchanged. |
| `<LeftMouse>` | Single click on a calendar day with notes: picker of that day's notes, titled `Notes · 2026-07-29`. On the `‹` / `›` header arrows: previous/next month. On the month label: back to today. Elsewhere: normal click. |
| `<Left>` / `<Right>` | On a calendar fence: previous/next month. Elsewhere: unchanged. |
| `<Home>` | On a calendar fence: back to the current month. Elsewhere: unchanged. |

## Examples

Notes tagged `#project` under a folder, with matching lines:

````
```query
path:Areas/Work tag:#project "kickoff meeting"
```
````

A table of recent Spanish-language notes:

````
```dataview
TABLE lang, created AS "Started"
FROM "Bitacora"
WHERE lang = "es" AND file.mtime >= date(today) - dur(30 days)
SORT file.name DESC
LIMIT 10
```
````

Open tasks due this week, grouped by note section:

````
```dataview
TASK FROM "Projects"
WHERE !completed AND due AND due <= date(eow)
GROUP BY section
```
````

Daily notes as a calendar — one month at a time, opening on the current
month, `<Left>`/`<Right>` (or the `‹` `›` arrows) to change month, `<Home>`
(or the month label) for today, click a day to open its notes:

````
```dataview
CALENDAR FROM "Bitacora"
```
````

External data:

````
```dataview
TABLE score, when FROM csv("measurements.csv") SORT score DESC
```
````

Inline, in the middle of a sentence:

```
This note has `= length(this.file.tasks)` tasks, last touched `= this.file.mday`.
```

## Language coverage

**Search fences** implement the complete core-Search syntax: words,
`"phrases"`, `/regex/`, implicit AND, `OR`, `-` negation, `(...)` grouping,
and the operators `file:` `path:` `content:` `tag:` (frontmatter and inline
tags, nested), `line:()` `section:()` `block:()` `task:` `task-todo:`
`task-done:` `match-case:()` `ignore-case:()` `[property]`
`[property:value]`. Matching is smart-case, like Obsidian.

**Dataview fences** implement DQL:

- Headers: `TABLE [WITHOUT ID]`, `LIST [WITHOUT ID]`, `TASK`, `CALENDAR`
- Sources: `#tag` (nested), `"folder"`, `[[note]]` (inlinks),
  `outgoing([[note]])`, `csv("file.csv")`, combined with `AND`/`OR`/`-`
- Commands: `WHERE`, `SORT` (multi-key), `GROUP BY`, `FLATTEN`, `LIMIT` —
  executed in written order, duplicates allowed, matching Dataview
- Expressions: arithmetic with typed values (`date - date` → duration,
  `date + dur(1 month)` shifts the calendar month with day clamping),
  comparisons with Dataview's null semantics, `AND`/`OR`/`!`, lambdas
  (`(x) => ...`), list literals, `[[link]]` literals, contextual
  `date(2026-01-01)` / `date(today|sow|som|…)` / `dur(30 days)` literals
- Implicit fields: `file.name/folder/path/link/size/ctime/cday/mtime/mday/
  day/tags/etags/aliases/tasks/inlinks/outlinks/frontmatter/starred`
  (bookmarks), frontmatter keys (original, lowercase and kebab-case),
  inline `Key:: value` fields (repeated keys merge into arrays)
- Tasks: `text/status/checked/completed/fullyCompleted/line/section/
  children/parent`, `[due:: …]`-style fields and 📅 ✅ ➕ ⏳ 🛫 dates,
  indent-based nesting
- ~60 functions: `contains`, `date`, `dur`, `default`, `choice`, `map`,
  `filter`, `sort`, `sum`, `min`/`max`(`by`), `join`, `flat`, `unique`,
  `regexmatch`, `regexreplace`, `dateformat`, `durationformat`,
  `currencyformat`, `striptime`, `typeof`, … (see
  `lua/obsidian-query/dataview/functions.lua`)

Regular expressions (both `/regex/` search terms and the `regex*`
functions) are translated to Vim regex: alternation, `{n,m}`, character
classes, `\b`, non-capturing groups and all four lookarounds work;
`$1` backreferences work in replacements.

## Limitations

- No `dataviewjs` — that is JavaScript and needs Obsidian's runtime.
- Array indexing is 1-based (Lua convention; Dataview's is 0-based).
- Dates are naive local time — no timezones or millisecond precision.
- `file.lists` currently equals `file.tasks` (only checkbox items are
  indexed).
- Regex patterns with in-pattern backreferences, named groups or inline
  flags are rejected (a one-time warning, the pattern matches nothing).
- Results are virtual lines: the cursor cannot enter them (use the `<CR>`
  picker), and task checkboxes in results are not clickable.

## How it works

Queries are parsed with recursive-descent parsers and evaluated in Lua.
The search engine reads candidate notes directly; the dataview engine
builds page objects from obsidian.nvim's mtime-checked cache plus its own
supplemental index (inline fields, headers, backlinks, bookmarks). Results
are drawn as `virt_lines` through render-markdown's custom-handler API,
re-rendered with an exponential backoff that survives render-markdown's
debounce window. Fence highlighting reuses the engines' lexers, so what
highlights is exactly what parses. Evaluation is total: malformed input
renders an error line (fences) or nothing (inline) — never a Lua error.

`:checkhealth obsidian-query` probes every external coupling (ripgrep,
treesitter, render-markdown API, obsidian.nvim cache schema); run it after
plugin updates.

## Development

```
nvim -l tests/search_spec.lua
nvim -l tests/dataview_spec.lua
```

Plain-assert suites (215+ checks), no framework, no fixtures on disk.
Specs strip the user config from `runtimepath` so they always exercise
this repo's tree.
