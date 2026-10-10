# Contributing

Thanks for helping out. Small, focused PRs merge fastest.

## Development

- `make test` runs the Dataview and Search suites (`tests/dataview_spec.lua`, `tests/search_spec.lua`) with `nvim -l`. They need no other plugins.
- `make picker SNACKS=/path/to/snacks.nvim` runs `tests/picker_spec.lua`, an integration check against real Snacks windows. Run it when you change `picker.lua` or the Dataview picker actions.
- `stylua lua tests` before pushing. CI runs `stylua --check lua tests`, so an unformatted file fails the build.
- `COVERAGE=1 make test picker` writes `luacov.stats.out`; it needs `luacov` and `luacov-reporter-lcov` on `LUA_PATH`. Config is in `.luacov`.

Add or extend a test for any behavior change. The specs are plain assert-style scripts: copy the nearest existing check.

## Commits and PR titles

PRs are squash-merged and releases are cut by release-please from the commit history, so **PR titles must follow [Conventional Commits](https://www.conventionalcommits.org)** (`feat: …`, `fix: …`, `docs: …`). CI checks the title; `feat` and `fix` drive the version bump and the changelog.

If a change touches the config surface, the commands, or the supported query syntax, update `README.md` and `doc/obsidian-query.txt` in the same PR.

## AI-assisted contributions

AI assistance (Copilot, Claude, etc.) is welcome, with three rules:

1. **Disclose it** in the PR description. A one-liner is fine.
2. **You must understand and have tested the change yourself.** Run `make test` locally. You are the author; "the model wrote it" is not a review response.
3. **No unreviewed dumps.** Large AI-generated diffs with no accompanying reasoning, and AI-generated bug reports without a reproducible case, will be closed.

## Bug reports

Use the issue form. The `:checkhealth obsidian-query` output, the query block itself, and the frontmatter or inline fields of one note it should match usually make a report reproducible on the first try.
