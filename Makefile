# snacks.nvim checkout for the picker integration test
SNACKS ?= ../snacks.nvim

# COVERAGE=1 records line coverage with luacov (config in .luacov). luacov must
# load before the plugin modules, jit.off() because compiled traces bypass the
# line hook, and the stats are flushed on exit because `nvim -l` skips luacov's
# own exit hook.
COV = $(if $(COVERAGE),--cmd "lua jit.off(); require('luacov')" --cmd "autocmd VimLeavePre * lua require('luacov.runner').shutdown()")

test:
	nvim $(COV) -l tests/dataview_spec.lua
	nvim $(COV) -l tests/search_spec.lua

# Real Snacks windows, formatting and selection; needs SNACKS=/path/to/snacks.nvim
picker:
	nvim --headless -u NONE $(COV) -l tests/picker_spec.lua $(SNACKS)

.PHONY: test picker
