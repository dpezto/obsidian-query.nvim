<h1 align="center">obsidian-query.nvim</h1>

<p align="center">
  Live <a href="https://obsidian.md">Obsidian</a> queries inside Neovim — no Obsidian required.
</p>

<p align="center">
  <a href="https://github.com/dpezto/obsidian-query.nvim/actions/workflows/ci.yml"><img alt="CI" src="https://github.com/dpezto/obsidian-query.nvim/actions/workflows/ci.yml/badge.svg"></a>
  <img alt="Neovim 0.11+" src="https://img.shields.io/badge/Neovim-0.11%2B-57A143?logo=neovim&logoColor=white">
  <img alt="Made with Lua" src="https://img.shields.io/badge/Lua-100%25-2C2D72?logo=lua&logoColor=white">
  <img alt="License: MIT" src="https://img.shields.io/badge/license-MIT-blue">
</p>

<p align="center">
  <img alt="A dataview TABLE fence rendering live results, then opening the result picker" src="assets/hero.gif" width="850">
</p>

Your reading list, unfinished tasks, and journal activity, right beside your
notes. Write a `query` or `dataview` code block and its results appear below
it in normal mode. Move in to edit and the query is there waiting for you.
Your files only contain the query; the results live on screen.

Supports Dataview `TABLE`, `LIST`, `TASK`, and `CALENDAR`, plus inline
expressions such as `` `= this.file.mday` ``. Queries use your notes'
frontmatter, inline fields, links, tags, and tasks.

## Setup

You need:

- Neovim 0.11+ with the `markdown` and `markdown_inline` Tree-sitter parsers.
- [obsidian.nvim](https://github.com/obsidian-nvim/obsidian.nvim), with a
  workspace configured and `cache = { enabled = true }` in its options.
- [render-markdown.nvim](https://github.com/MeanderingProgrammer/render-markdown.nvim).
- [ripgrep](https://github.com/BurntSushi/ripgrep) for Search queries.

Add these specs to your [lazy.nvim](https://github.com/folke/lazy.nvim) config:

```lua
{
  "dpezto/obsidian-query.nvim",
  ft = "markdown",
  opts = {
    picker = { style = "rich" }, -- show task text and query columns
  },
},
{
  "MeanderingProgrammer/render-markdown.nvim",
  opts = function(_, opts)
    opts.custom_handlers = opts.custom_handlers or {}
    opts.custom_handlers.markdown = require("obsidian-query").handler
    opts.custom_handlers.markdown_inline = require("obsidian-query.inline").handler
  end,
},
```

Use [snacks.nvim](https://github.com/folke/snacks.nvim),
[telescope.nvim](https://github.com/nvim-telescope/telescope.nvim), or
[fzf-lua](https://github.com/ibhagwan/fzf-lua) for result pickers. They are
tried in that order. Without one, `vim.ui.select` opens notes but has no task
toggle or preview.

Run `:checkhealth obsidian-query` if results don't appear.

## A few things to try

### Reading list

Give those book notes a shelf. Pull authors, ratings, and reading status
into a table, then press Enter to pick a book and open its note.

````markdown
```dataview
TABLE author, rating, status, started
FROM #book
SORT rating DESC, file.name ASC
```
````

Fields come from the notes' frontmatter or `Key:: value` fields. Sources can
be tags, folders, links, or a CSV file. `WHERE`, `SORT`, `GROUP BY`, `FLATTEN`,
and `LIMIT` run in the order you write them.

### Tasks

One place to see what's left, even when the checkboxes are scattered across
project notes:

````markdown
```dataview
TASK FROM "Projects"
WHERE !completed
GROUP BY file.link
```
````

Press Enter on the query to open its results, then Ctrl-T to complete or
reopen a task. This writes the source note. Closing the picker refreshes the
query and its remaining-task count.

<img alt="Completing two tasks and returning to the updated remaining count" src="assets/tasks.gif" width="850">

Task fields include `completed`, `status`, `due`, `children`, and
`fullyCompleted`. Dates can use `[due:: 2026-09-20]` or Tasks-plugin emoji
notation such as `📅 2026-09-20`. To show tasks due by the end of this week, use:

```text
WHERE !completed AND due AND due <= date(eow)
```

Snacks and Telescope update task rows while the picker is open. fzf-lua
updates them the next time you open it and has no preview. If a task has
moved or its text has changed, reopen the query picker before toggling it.

### Search

Find the draft you still need to send, or the press kit you haven't finished:

````markdown
```query
path:Projects task-todo:draft OR task-todo:press
```
````

<img alt="Search results with matching task text" src="assets/search.gif" width="850">

Search supports words, quoted phrases, regex, `OR`, `-` negation, and groups.
Use `tag:`, `path:`, `file:`, or `[property:value]` to narrow results;
`line:(...)`, `section:(...)`, and `block:(...)` restrict where terms match.
Lowercase terms ignore case; uppercase letters make a plain-text term case-sensitive.

### Calendar heat map

A month of notes at a glance. This one turns a journal folder into a calendar:

````markdown
```dataview
CALENDAR FROM "Journal"
```
````

<img alt="Journal activity by day, with month navigation" src="assets/calendar.gif" width="850">

The calendar uses dates from note names or a frontmatter `date` field.
Brighter days have more notes; today is marked so you can find your way back.
The colors follow your colorscheme. Use Left/Right on the query to change
months, Home to return to this month, or click a day to open its notes.

### Inline expressions

Sometimes a whole table is too much. Tuck a query into a sentence:

```markdown
This note has `= length(this.file.tasks)` tasks, last edited `= this.file.mday`.
```

The value appears in place; move the cursor onto the line to edit the expression.

For the language reference, functions, and more examples, see
`:help obsidian-query-dataview` and `:help obsidian-query-search`.

## Controls

| Key | Action |
| --- | --- |
| Enter on a query | Open results in a picker |
| Ctrl-T in a TASK picker | Toggle and save the selected task |
| Left / Right on a calendar query | Previous / next month |
| Home on a calendar query | Current month |
| Click a calendar day | Open that day's notes |

Results are virtual lines, so `j` and `k` skip over them. Use the picker to
select a result, or Ctrl-E/Ctrl-Y to scroll through a tall block.

These mappings are installed in vault notes. Outside queries they keep
their normal behavior, including obsidian.nvim's Enter action. Entering a
note in another configured vault switches the active workspace.

## Options

Defaults:

```lua
require("obsidian-query").setup({
  picker = {
    backend = "auto", -- "snacks", "telescope", "fzf-lua", or "select"
    style = "file",   -- "rich" includes query columns and task text
  },
  icons = "auto",     -- "nerd" or "ascii" to override
  max_inline_rows = 12,
})
```

The picker always contains the full result set. Set `max_inline_rows` to
`math.huge` to show every result inline.

Checkbox icons follow your render-markdown configuration. Without a Nerd
Font, set `icons = "ascii"` or `vim.g.have_nerd_font = false`.

## Completion

Start typing a query and let your vault fill in the names. The completion
source suggests keywords and functions, along with your tags, folders,
notes, and properties. Function documentation is there in the menu too.

For [blink.cmp](https://github.com/Saghen/blink.cmp), add a source to its options:

```lua
sources = {
  per_filetype = { markdown = { inherit_defaults = true, "obsidian_query" } },
  providers = {
    obsidian_query = {
      name = "ObsidianQuery",
      module = "obsidian-query.blink",
    },
  },
},
```

<img alt="Completing Dataview keywords, note properties, tags, and file fields" src="assets/completion.gif" width="850">

## Differences from Obsidian

- `dataviewjs` and `$=` JavaScript expressions aren't supported.
- Arrays use 1-based indexing.
- Dates use local time without timezone or millisecond support.
- Plain items in `file.lists` have no parent/child nesting; tasks do.
- Regex is translated to Vim regex. In-pattern backreferences, named groups,
  and inline flags aren't supported.
- Dataview queries read saved notes from obsidian.nvim's cache.

The query engines are implemented in Lua, based on
[Dataview](https://github.com/blacksmithgu/obsidian-dataview) and
[Obsidian Search](https://help.obsidian.md/plugins/search). They don't run
Obsidian's plugins or read Dataview's settings.

## Credits

[Dataview](https://github.com/blacksmithgu/obsidian-dataview) made querying
your own notes feel natural. This plugin brings that habit to Neovim, with
[Obsidian Search](https://help.obsidian.md/plugins/search) alongside it and
emoji dates from [Tasks](https://github.com/obsidian-tasks-group/obsidian-tasks).

Built on [obsidian.nvim](https://github.com/obsidian-nvim/obsidian.nvim) and
[render-markdown.nvim](https://github.com/MeanderingProgrammer/render-markdown.nvim),
with your picker doing the jumping between notes.
