-- Lexer-driven syntax highlighting for ```query and ```dataview fence bodies.
-- No tree-sitter grammar exists for either language (biozz/tree-sitter-dataview
-- is WIP) — the engines' own lexers provide exact token spans instead. Applied
-- as plain extmarks so it stays visible in insert mode, precisely when
-- render-markdown collapses to the raw fence.
local M = {}

local ns = vim.api.nvim_create_namespace("obsidian-query-hl")
local attached = {} ---@type table<integer, true>

local DQL_KEYWORDS = {
  TABLE = true, LIST = true, TASK = true, CALENDAR = true,
  WITHOUT = true, ID = true, FROM = true, WHERE = true, SORT = true,
  GROUP = true, BY = true, FLATTEN = true, LIMIT = true, AS = true,
  ASC = true, DESC = true, AND = true, OR = true,
  TRUE = true, FALSE = true, NULL = true,
}
local DQL_OPS = {
  ["+"] = true, ["-"] = true, ["*"] = true, ["/"] = true, ["%"] = true,
  ["="] = true, ["!="] = true, ["<"] = true, ["<="] = true, [">"] = true,
  [">="] = true, ["&"] = true, ["|"] = true, ["!"] = true, ["=>"] = true,
}
local DQL_PUNCT = {
  ["("] = true, [")"] = true, ["["] = true, ["]"] = true,
  [","] = true, ["."] = true, [":"] = true,
}

---@return {pos: integer, fin: integer, hl: string}[]
local function dataview_spans(body)
  local lexer = require("obsidian-query.dataview.lexer")
  local toks = lexer.tokenize(body)
  if not toks then
    return {}
  end
  local spans = {}
  for idx, t in ipairs(toks) do
    local hl
    if t.type == "IDENT" then
      if DQL_KEYWORDS[t.text:upper()] then
        hl = "@keyword"
      elseif toks[idx + 1] and toks[idx + 1].type == "(" then
        hl = "@function.call"
      end
    elseif t.type == "STRING" then
      hl = "@string"
    elseif t.type == "NUMBER" then
      hl = "@number"
    elseif t.type == "TAG" then
      hl = "@tag"
    elseif t.type == "LINK" then
      hl = "@markup.link.label"
    elseif DQL_OPS[t.type] then
      hl = "@operator"
    elseif DQL_PUNCT[t.type] then
      hl = "@punctuation.bracket"
    end
    if hl then
      spans[#spans + 1] = { pos = t.pos, fin = t.fin, hl = hl }
    end
  end
  return spans
end

---@return {pos: integer, fin: integer, hl: string}[]
local function query_spans(body)
  local parser = require("obsidian-query.search.parser")
  local toks = parser.lex(body)
  if not toks then
    return {}
  end
  local spans = {}
  for _, t in ipairs(toks) do
    local hl
    if t.t == "op" then
      hl = "@keyword"
    elseif t.t == "OR" then
      hl = "@keyword.operator"
    elseif t.t == "phrase" then
      hl = "@string"
    elseif t.t == "regex" then
      hl = "@string.regexp"
    elseif t.t == "prop" then
      hl = "@property"
    elseif t.t == "-" then
      hl = "@operator"
    elseif t.t == "(" or t.t == ")" then
      hl = "@punctuation.bracket"
    elseif t.t == "word" and t.s:sub(1, 1) == "#" then
      hl = "@tag"
    end
    if hl then
      spans[#spans + 1] = { pos = t.pos, fin = t.fin, hl = hl }
    end
  end
  return spans
end

local SPANNERS = { query = query_spans, dataview = dataview_spans }

-- fence query shared with the render handler
local function get_query()
  return require("obsidian-query").fence_query()
end

---Byte offset (1-based) within `body` -> buffer (row, col), given body start.
local function make_locator(body, start_row)
  local line_starts, off = { 1 }, 1
  for nl in body:gmatch("()\n") do
    line_starts[#line_starts + 1] = nl + 1
    off = nl + 1
  end
  return function(pos)
    -- binary-search not needed: fence bodies are tiny
    for l = #line_starts, 1, -1 do
      if pos >= line_starts[l] then
        return start_row + l - 1, pos - line_starts[l]
      end
    end
    return start_row, pos - 1
  end
end

function M.refresh(buf)
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  local ok, parser = pcall(vim.treesitter.get_parser, buf, "markdown")
  if not ok or not parser then
    return
  end
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  local trees = parser:parse(true)
  if not trees or not trees[1] then
    return
  end
  local root = trees[1]:root()
  local query = get_query()
  for _, match in query:iter_matches(root, buf) do
    local lang, body
    for id, nodes in pairs(match) do
      local name = query.captures[id]
      if name == "lang" then
        lang = nodes[#nodes]
      elseif name == "body" then
        body = nodes[#nodes]
      end
    end
    local spanner = lang and SPANNERS[vim.treesitter.get_node_text(lang, buf)]
    if spanner and body then
      local text = vim.treesitter.get_node_text(body, buf)
      local start_row = body:range()
      local locate = make_locator(text, start_row)
      for _, span in ipairs(spanner(text)) do
        local srow, scol = locate(span.pos)
        local erow, ecol = locate(span.fin)
        pcall(vim.api.nvim_buf_set_extmark, buf, ns, srow, scol, {
          end_row = erow,
          end_col = ecol + 1,
          hl_group = span.hl,
          priority = 110, -- above markdown treesitter's @markup.raw
        })
      end
    end
  end
end

---Attach buffer-local refresh autocmds once per buffer (called from the
---render handler, so only markdown buffers that render fences pay for it).
function M.attach(buf)
  if attached[buf] then
    return
  end
  attached[buf] = true
  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI", "InsertLeave" }, {
    group = vim.api.nvim_create_augroup("obsidian_query_hl_" .. buf, { clear = true }),
    buffer = buf,
    callback = function()
      M.refresh(buf)
    end,
  })
  vim.api.nvim_create_autocmd("BufDelete", {
    buffer = buf,
    once = true,
    callback = function()
      attached[buf] = nil
    end,
  })
  M.refresh(buf)
end

return M
