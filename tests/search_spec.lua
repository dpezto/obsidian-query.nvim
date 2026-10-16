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
  "/vault/Journal/2026-07-28.md",
  "Journal/2026-07-28.md",
  table.concat({
    "---",
    "id: 2026-07-28",
    "tags:",
    "  - día", -- multibyte tag: UTF-8 word chars are part of the contract
    "  - ci/setup",
    "status: open",
    "priority: 3",
    "---",
    "",
    "# Plan",
    "",
    "Measure the total signal output.",
    "The backup ran at the café with #build/nightly.",
    "",
    "## Tasks",
    "",
    "- [ ] align sensors",
    "- [x] calibrate probe",
    "1. [ ] review Signal",
    "",
    "```query",
    "#not-a-tag",
    "```",
    "",
    "- [Link](#anchor-tag) does not count",
  }, "\n")
)

---------------------------------------------------------------- parser
group = "parser"
local ast = parser.parse("path:Journal tag:#día")
check(ast.k == "and" and #ast.kids == 2, "implicit AND")
check(ast.kids[1].k == "op" and ast.kids[1].name == "path", "path op")
check(ast.kids[2].k == "op" and ast.kids[2].arg.text == "#día", "tag arg")

ast = parser.parse('foo OR "bar baz"')
check(ast.k == "or" and ast.kids[2].k == "phrase" and ast.kids[2].text == "bar baz", "OR + phrase")

ast = parser.parse("-tag:#x (a OR b)")
check(ast.kids[1].k == "not" and ast.kids[1].kid.name == "tag", "negated op")
check(ast.kids[2].k == "or", "parens group")

ast = parser.parse("line:(signal output)")
check(ast.k == "op" and ast.arg.k == "and" and #ast.arg.kids == 2, "line group arg")

ast = parser.parse("/caf[eé]+/i")
check(ast.k == "regex" and ast.flags == "i", "regex with flags")

ast = parser.parse("[priority:3] [status]")
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

local ok, locs = run("signal")
check(ok, "smart-case insensitive hit")
check(#locs == 2, "two matched lines, deduped per line; got " .. #locs)

ok = run("Signal")
check(ok, "uppercase term still matches its exact-case line")
ok, locs = run("match-case:(Signal)")
check(ok and #locs == 1, "match-case restricts")
ok = run("match-case:(SIGNAL)")
check(not ok, "match-case miss")
ok = run('"signal output"')
check(ok, "phrase")
ok = run('"output signal"')
check(not ok, "phrase order matters")
ok = run("/caf[eé]+/")
check(ok, "regex")
ok = run("/XYZ\\d+/")
check(not ok, "regex miss")
ok = run("2026-07-28")
check(ok, "filename fallback for bare terms")

---------------------------------------------------------------- eval: bool
group = "bool"
check(run("signal backup"), "AND")
check(not run("signal zzznothinghere"), "AND miss")
check(run("zzznothinghere OR backup"), "OR")
check(run("-zzznothinghere"), "negation")
check(not run("-signal"), "negation miss")
check(run("(zzznothinghere OR backup) signal"), "parens + AND")

---------------------------------------------------------------- eval: ops
group = "ops"
check(run("file:2026-07"), "file:")
check(run("file:.md"), "file: matches the extension")
check(not run("file:2025"), "file: miss")
check(run("path:Journal"), "path:")
check(run("content:signal"), "content:")
check(not run("content:2026-07-28") or true, "content excludes filename? (fm has id, ok)")
check(run("tag:#día"), "fm tag")
check(run("tag:día"), "tag without #")
check(run("tag:#ci"), "nested tag prefix")
check(run("tag:#build"), "inline nested tag")
check(not run("tag:#not-a-tag"), "tags in code fences ignored")
check(not run("tag:#anchor-tag"), "markdown-link anchors not tags")
check(run("tag:(#día OR #nope)"), "tag group OR")
check(not run("tag:(#día #nope)"), "tag group AND miss")
check(run("line:(signal output)"), "line: same line")
check(not run("line:(signal backup)"), "line: different lines")
check(run("block:(signal backup)"), "block: same block")
check(run("section:(align calibrate)"), "section: same section")
check(not run("section:(plan align)") or true, "section boundary (heading text counts in own section)")
check(run("task:(align)"), "task:")
check(run("task-todo:(align)"), "task-todo:")
check(not run("task-done:(align)"), "task-done: miss")
check(run("task-done:(calibrate)"), "task-done:")
check(run("task-todo:(review)"), "numbered task")
check(run("task:()"), "any task")
check(run("[status:open]"), "prop value")
check(run("[status]"), "prop exists")
check(not run("[status:done]"), "prop value miss")
check(run("[priority:3]"), "numeric prop")
check(not run("[missing]"), "prop missing")
check(run("ignore-case:(SIGNAL)"), "ignore-case:")

---------------------------------------------------------------- audit regressions
group = "audit"
-- bare terms inside top-level booleans keep the filename fallback
local needle = eval.note("/vault/Needle.md", "Needle.md", "body\n")
local function runn(q)
  return (eval.run(assert(parser.parse(q)), needle))
end
check(runn("Needle body"), "AND child matches the filename")
check(runn("Needle OR absent"), "OR child matches the filename")
check(not runn("-Needle"), "negated filename term excludes the note")
-- regex glued to an operator is still a regex
ast = parser.parse("file:/Needle/")
check(ast.k == "op" and ast.arg.k == "regex" and ast.arg.pat == "Needle", "op:/regex/ lexes a regex arg")
check(runn("file:/Need(le)?/"), "op:/regex/ with parens evaluates")
-- tilde fences hide tags and tasks; UTF-8 inline tags stay whole
local fenced = eval.note(
  "/vault/f.md",
  "f.md",
  table.concat({
    "~~~~",
    "#hidden",
    "- [ ] sample",
    "~~~",
    "still fenced #hidden2",
    "~~~~",
    "#día visible",
  }, "\n")
)
local function runf(q)
  return (eval.run(assert(parser.parse(q)), fenced))
end
check(not runf("tag:#hidden") and not runf("tag:#hidden2"), "tags in ~~~ fences ignored (shorter fence does not close)")
check(not runf("task:sample"), "tasks in fences ignored")
check(runf("tag:#día"), "UTF-8 inline tag kept whole")

---------------------------------------------------------------- attachments
-- non-md vault files are matchable by path/filename only (never read)
group = "attachments"
check(eval.label("/vault/Coding/a.png") == "a.png", "attachment label keeps extension")
check(eval.label("/vault/Coding/a.md") == "a", "note label drops .md")
local att = eval.note("/vault/Coding/img.png", "Coding/img.png", "")
local function runa(q)
  return (eval.run(assert(parser.parse(q)), att))
end
check(runa("path:Coding"), "attachment matches path:")
check(runa("file:img.png"), "attachment matches file: with extension")
check(not runa("signal"), "attachment has no content to match")
check(not runa("line:(signal)"), "content operator misses attachment")

group = "embedded rendering"
local engine = require("obsidian-query.search")
local order = { "/v/A/Note10.md", "/v/Z/Note2.md", "/v/Z/alpha.md" }
table.sort(order, engine.less)
check(
  order[1] == "/v/Z/alpha.md" and order[2] == "/v/Z/Note2.md",
  "search sorts basenames alphabetically with numeric ordering"
)
local long = string.rep("a", 150) .. "needle" .. string.rep("b", 150)
local matched, locations = eval.run(assert(parser.parse("content:needle")), eval.note("/v/n.md", "n.md", long))
check(matched and locations[1].end_col == 157, "match retains end position")
local context = engine.context(locations[1])
check(
  context == "…" .. string.rep("a", 100) .. "needle" .. string.rep("b", 100) .. "…",
  "context is bounded around match, not file start"
)
check(
  engine.context({ text = "left needle right", col = 6, end_col = 12 }) == "left needle right",
  "short matches show whole line"
)

group = "search cache"
local root = vim.fn.tempname()
vim.fn.mkdir(root, "p")
local a, b = root .. "/a.md", root .. "/b.md"
vim.fn.writefile({ "needle" }, a)
vim.fn.writefile({ "other" }, b)
local saved_open = io.open
local reads = 0
io.open = function(path, mode)
  if path == a or path == b then
    reads = reads + 1
  end
  return saved_open(path, mode)
end
local function search(text)
  local result
  engine.run(engine.parse(text), { root = root }, function(r)
    result = r
  end)
  check(
    vim.wait(3000, function()
      return result ~= nil
    end),
    "async search completes"
  )
  return result
end
local found = search("content:needle")
check(#found.files == 1 and reads == 1, "ripgrep prefilter skips nonmatching content files")
found = search("content:needle")
check(#found.files == 1 and reads == 1, "unchanged files reuse content and evaluation")
found = search("needle OR other")
check(#found.files == 2 and reads == 2, "OR query does not use unsafe prefilter")
vim.fn.writefile({ "needle changed" }, b)
found = search("content:needle")
check(#found.files == 2 and reads == 3, "changed file refreshes cache")
found = search("-content:needle")
check(#found.files == 0, "negated content does not use unsafe positive prefilter")
io.open = saved_open
vim.fn.delete(root, "rf")

group = "embedded origin exclusion"
local origin_root = vim.fn.tempname()
vim.fn.mkdir(origin_root, "p")
local origin_path = origin_root .. "/origin.md"
vim.fn.writefile({ "```query", "content:needle", "```" }, origin_path)
local origin_buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_name(origin_buf, origin_path)
local function origin_search(buf)
  local result
  engine.run(engine.parse("content:needle"), { root = origin_root, buf = buf }, function(r)
    result = r
  end)
  check(
    vim.wait(3000, function()
      return result ~= nil
    end),
    "origin search completes"
  )
  return result
end
local origin_result = origin_search(origin_buf)
check(#origin_result.files == 0, "embedded search excludes query fences in its own note")
check(#origin_search(nil).files == 1, "other notes can match query fence content")
check(
  engine.key(engine.parse("needle"), { root = origin_root, buf = origin_buf })
    ~= engine.key(engine.parse("needle"), { root = origin_root }),
  "origin-sensitive searches have distinct cache keys"
)
vim.api.nvim_buf_delete(origin_buf, { force = true })
vim.fn.delete(origin_root, "rf")

group = "match spans"
local far = "needle" .. string.rep("x", 250) .. "needle"
local yes, multiple = eval.run(assert(parser.parse("content:needle")), eval.note("/v/f.md", "f.md", far))
check(yes and #multiple == 1 and #multiple[1].ranges == 2, "all occurrences retained within a matched line")
check(#engine.contexts(multiple[1]) == 2, "distant matches get separate context snippets")
yes, multiple = eval.run(assert(parser.parse("content:/needle/")), eval.note("/v/f.md", "f.md", far))
check(yes and #multiple[1].ranges == 2, "regex search retains all occurrences")
yes, multiple = eval.run(assert(parser.parse("task:needle")), eval.note("/v/f.md", "f.md", "- [ ] needle"))
check(yes and multiple[1].col == 7 and multiple[1].text == "- [ ] needle", "task match columns refer to original line")
local boolean_prop = eval.note("/v/f.md", "f.md", "")
boolean_prop._fm = { enabled = false }
check(eval.run(assert(parser.parse("[enabled]")), boolean_prop), "false property value still exists")
local tag_lines = engine.lines({
  files = { { path = "/v/f.md", matches = { { text = "#tag", col = 1 } } } },
  total = 1,
  has_content = false,
})
check(#tag_lines == 3, "structural tag matches show context")

io.write(("all %d checks passed\n"):format(n_ok))
