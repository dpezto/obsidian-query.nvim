# Security Policy

## Reporting a Vulnerability

Please report security vulnerabilities privately via
[GitHub's private vulnerability reporting](https://github.com/dpezto/obsidian-query.nvim/security/advisories/new)
rather than filing a public issue.

This is a Neovim plugin with no server component. It reads notes from the
configured Obsidian vault and runs ripgrep for Search queries, so the main risk
surface is:

- Code or command execution triggered by a crafted note or query block
- Supply-chain issues in CI (GitHub Actions dependencies)

Expect an initial response within a few days; this is a solo-maintained project.
