Output assets/completion.gif

Source assets/tapes/style.tape

Hide
Type "source assets/demo/setup.sh" Enter
Type "nvim -i NONE -n --cmd 'luafile assets/demo/demo-init.lua' $OBSIDIAN_BASE_DIR/Demo/Scratch.md" Enter
Sleep 10s
Show
Sleep 1.5s
# into the empty fence body
Type "4G"
Sleep 500ms
Type "cc"
Sleep 500ms
# One-line query: a bare Enter would hit blink's accept, not newline.
# DQL keywords…
Type "TAB"
Sleep 2s
# …frontmatter properties…
Type "LE author, ra"
Sleep 2.5s
Type "ting, status "
# …vault tags…
Type "FROM #bo"
Sleep 2.5s
Type "ok "
# …implicit file.* fields with docs
Type "SORT file."
Sleep 3s
Type "name ASC"
Sleep 1s
Escape
# rendered result
Sleep 5s
Hide
Type ":qa!" Enter
