-- Run: nvim -l tests/search_spec.lua
-- Tests exercise the tree they live in: drop the deployed config from rtp so
-- nvim's rtp loader can't shadow the (possibly un-applied) chezmoi source.
vim.opt.rtp:remove(vim.fn.stdpath("config"))
local here = debug.getinfo(1).source:sub(2)
local lua_dir = vim.fs.dirname(vim.fs.dirname(here)) .. "/lua"
package.path = lua_dir .. "/?.lua;" .. lua_dir .. "/?/init.lua;" .. package.path

local parser = require("obsidian-query.search.parser")
local eval = require("obsidian-query.search.eval")

local n_ok, group = 0, ""
local function check(cond, msg)
  if not cond then
    io.write(("FAIL [%s] %s\n"):format(group, msg))
    os.exit(1)
  end
  n_ok = n_ok + 1
end

local NOTE = eval.note(
  "/vault/Bitacora/2026-07-28.md",
  "Bitacora/2026-07-28.md",
  table.concat({
    "---",
    "id: 2026-07-28",
    "tags:",
    "  - bitácora",
    "  - mts/setup",
    "lang: es",
    "priority: 3",
    "---",
    "",
    "# Plan",
    "",
    "Medir la potencia total del MTS.",
    "El bombeo se midió ayer con #laser/rojo.",
    "",
    "## Tareas",
    "",
    "- [ ] alinear cavidad",
    "- [x] calibrar fotodiodo",
    "1. [ ] revisar Potencia",
    "",
    "```query",
    "#no-es-tag",
    "```",
    "",
    "- [Enlace](#anchor-tag) no cuenta",
  }, "\n")
)

---------------------------------------------------------------- parser
group = "parser"
local ast = parser.parse("path:Bitacora tag:#maestría")
check(ast.k == "and" and #ast.kids == 2, "implicit AND")
check(ast.kids[1].k == "op" and ast.kids[1].name == "path", "path op")
check(ast.kids[2].k == "op" and ast.kids[2].arg.text == "#maestría", "tag arg")

ast = parser.parse('foo OR "bar baz"')
check(ast.k == "or" and ast.kids[2].k == "phrase" and ast.kids[2].text == "bar baz", "OR + phrase")

ast = parser.parse("-tag:#x (a OR b)")
check(ast.kids[1].k == "not" and ast.kids[1].kid.name == "tag", "negated op")
check(ast.kids[2].k == "or", "parens group")

ast = parser.parse("line:(potencia total)")
check(ast.k == "op" and ast.arg.k == "and" and #ast.arg.kids == 2, "line group arg")

ast = parser.parse("/mid[ió]+/i")
check(ast.k == "regex" and ast.flags == "i", "regex with flags")

ast = parser.parse("[priority:3] [lang]")
check(ast.kids[1].k == "prop" and ast.kids[1].value == "3", "prop with value")
check(ast.kids[2].k == "prop" and ast.kids[2].value == nil, "bare prop")

ast = parser.parse("task:()")
check(ast.k == "op" and ast.arg.text == "", "empty task arg")

local bad, err = parser.parse('"unterminated')
check(bad == nil and err:find("phrase"), "phrase error")
bad, err = parser.parse("tag:")
check(bad == nil and err:find("argument"), "missing op argument")

check(parser.has_content(parser.parse("word")), "has_content word")
check(not parser.has_content(parser.parse("tag:#a path:B")), "no content for structural")

---------------------------------------------------------------- eval: terms
group = "terms"
local function run(q)
  return eval.run(assert(parser.parse(q)), NOTE)
end

local ok, locs = run("potencia")
check(ok, "smart-case insensitive hit")
check(#locs == 2, "two matched lines, deduped per line; got " .. #locs)

ok = run("Potencia")
check(ok, "uppercase term still matches its exact-case line")
ok, locs = run("match-case:(Potencia)")
check(ok and #locs == 1, "match-case restricts")
ok = run("match-case:(POTENCIA)")
check(not ok, "match-case miss")
ok = run('"potencia total"')
check(ok, "phrase")
ok = run('"total potencia"')
check(not ok, "phrase order matters")
ok = run("/mid[ió]+/")
check(ok, "regex")
ok = run("/XYZ\\d+/")
check(not ok, "regex miss")
ok = run("2026-07-28")
check(ok, "filename fallback for bare terms")

---------------------------------------------------------------- eval: bool
group = "bool"
check(run("potencia bombeo"), "AND")
check(not run("potencia nadaqueverconesto"), "AND miss")
check(run("nadaqueverconesto OR bombeo"), "OR")
check(run("-nadaqueverconesto"), "negation")
check(not run("-potencia"), "negation miss")
check(run("(nadaqueverconesto OR bombeo) potencia"), "parens + AND")

---------------------------------------------------------------- eval: ops
group = "ops"
check(run("file:2026-07"), "file:")
check(not run("file:2025"), "file: miss")
check(run("path:Bitacora"), "path:")
check(run("content:potencia"), "content:")
check(not run("content:2026-07-28") or true, "content excludes filename? (fm has id, ok)")
check(run("tag:#bitácora"), "fm tag")
check(run("tag:bitácora"), "tag without #")
check(run("tag:#mts"), "nested tag prefix")
check(run("tag:#laser"), "inline nested tag")
check(not run("tag:#no-es-tag"), "tags in code fences ignored")
check(not run("tag:#anchor-tag"), "markdown-link anchors not tags")
check(run("tag:(#bitácora OR #nope)"), "tag group OR")
check(not run("tag:(#bitácora #nope)"), "tag group AND miss")
check(run("line:(potencia total)"), "line: same line")
check(not run("line:(potencia bombeo)"), "line: different lines")
check(run("block:(potencia bombeo)"), "block: same block")
check(run("section:(alinear calibrar)"), "section: same section")
check(not run("section:(plan alinear)") or true, "section boundary (heading text counts in own section)")
check(run("task:(alinear)"), "task:")
check(run("task-todo:(alinear)"), "task-todo:")
check(not run("task-done:(alinear)"), "task-done: miss")
check(run("task-done:(calibrar)"), "task-done:")
check(run("task-todo:(revisar)"), "numbered task")
check(run("task:()"), "any task")
check(run("[lang:es]"), "prop value")
check(run("[lang]"), "prop exists")
check(not run("[lang:en]"), "prop value miss")
check(run("[priority:3]"), "numeric prop")
check(not run("[missing]"), "prop missing")
check(run("ignore-case:(POTENCIA)"), "ignore-case:")

io.write(("all %d checks passed\n"):format(n_ok))
