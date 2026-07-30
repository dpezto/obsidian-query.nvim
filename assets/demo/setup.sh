#!/bin/bash
# Build a throwaway Obsidian vault for recording the README GIFs, so recording
# never touches (or leaks) your real vaults. Your real Neovim config is reused
# as-is, so the GIFs use your colorscheme/plugins/font.
#
# Usage:  source assets/demo/setup.sh   (source, not run — it exports an env var)
#         vhs assets/tapes/hero.tape
#
# The Neovim config discovers vaults under $OBSIDIAN_BASE_DIR, so pointing that
# at the throwaway root makes obsidian.nvim (and obsidian-query) see only the
# demo vault for this shell.
set -eu

ROOT="${XDG_CACHE_HOME:-$HOME/.cache}/obsidian-query-demo"
VAULT="$ROOT/Demo"
rm -rf "$VAULT" # drop stale notes from previous runs
mkdir -p "$VAULT/.obsidian" "$VAULT/Books" "$VAULT/Projects" "$VAULT/Journal"

# --- dates relative to today, so queries/calendar always have live data ------
day() { date -v"$1"d +%Y-%m-%d 2>/dev/null || date -d "$1 day" +%Y-%m-%d; }

# --- Books: frontmatter fields for the TABLE shots ---------------------------
book() { # file, status, rating, author, pages, started-offset
  cat > "$VAULT/Books/$1.md" <<EOF
---
tags: [book]
status: $2
rating: $3
author: $4
pages: $5
started: $(day "$6")
---

Notes on *$1*. Favourite chapter so far marked in the margins.
EOF
}
book "The Dispossessed" reading 5 "Ursula K. Le Guin" 387 -12
book "Piranesi" done 4 "Susanna Clarke" 272 -40
book "A Memory Called Empire" done 5 "Arkady Martine" 462 -65
book "The Three-Body Problem" reading 4 "Liu Cixin" 416 -8
book "Too Like the Lightning" paused 3 "Ada Palmer" 432 -90
book "This Is How You Lose the Time War" done 5 "El-Mohtar & Gladstone" 209 -21

# --- Projects: tasks with Tasks-plugin emoji dates for the TASK shots --------
cat > "$VAULT/Projects/Apollo.md" <<EOF
---
tags: [project]
---

## Launch

- [ ] Prepare press kit 📅 $(day +3)
- [ ] Draft announcement post 📅 $(day +1)
	- [ ] Collect quotes from the team
- [x] Book the venue ✅ $(day -2)

## Backlog

- [ ] Write launch retrospective
- [ ] Archive old design files
EOF

cat > "$VAULT/Projects/Hyperion.md" <<EOF
---
tags: [project]
---

## Research

- [ ] Read the pilgrimage papers 📅 $(day +5)
- [x] Summarize prior art ✅ $(day -6)

## Writing

- [ ] Outline chapter three [due:: $(day +2)]
- [ ] Send draft to reviewers
EOF

# --- Journal: daily notes with varying per-day counts for the CALENDAR heat -
# Walk the last ~5 weeks; the repeating pattern gives days 0-3 notes so the
# heat map has a real gradient. Extra same-day notes get a suffix after the
# date (file.day parses the leading yyyy-MM-dd).
pattern=(1 2 0 1 3 1 0 2 1 1 0 3 1 2 1)
for i in $(seq 0 34); do
  d=$(day "-$i")
  n=${pattern[$((i % 15))]}
  [ "$n" -ge 1 ] && printf -- '---\ntags: [journal]\n---\n\nDaily log for %s.\n' "$d" > "$VAULT/Journal/$d.md"
  [ "$n" -ge 2 ] && printf -- '---\ntags: [journal]\n---\n\nMeeting notes.\n' > "$VAULT/Journal/$d meeting.md"
  [ "$n" -ge 3 ] && printf -- '---\ntags: [journal]\n---\n\nEvening review.\n' > "$VAULT/Journal/$d review.md"
done

# --- Notes holding the query fences the tapes open ---------------------------
cat > "$VAULT/Reading-list.md" <<'EOF'
# Reading list

Last touched `= this.file.mday`, `= length(this.file.outlinks)` outgoing links.

```dataview
TABLE author, rating, status, started
FROM #book
SORT rating DESC, file.name ASC
```
EOF

cat > "$VAULT/Open-tasks.md" <<'EOF'
# Open tasks

```dataview
TASK FROM "Projects"
WHERE !completed
GROUP BY file.link
```
EOF

cat > "$VAULT/Journal.md" <<'EOF'
# Journal

```dataview
CALENDAR FROM "Journal"
```
EOF

cat > "$VAULT/Search.md" <<'EOF'
# Search

```query
path:Projects task-todo:draft OR task-todo:press
```
EOF

# Completion playground: empty fence, the tape types the query live inside it.
cat > "$VAULT/Scratch.md" <<'EOF'
# Scratch

```dataview

```
EOF

export OBSIDIAN_BASE_DIR="$ROOT"
echo "Demo vault ready: $VAULT"
echo "OBSIDIAN_BASE_DIR now points at the throwaway root for this shell."
echo "Record with:  vhs assets/tapes/<name>.tape"
