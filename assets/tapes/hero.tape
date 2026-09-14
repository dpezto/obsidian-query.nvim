Output assets/hero.gif

Source assets/tapes/style.tape

Hide
Type "source assets/demo/setup.sh" Enter
# -n (no swapfile): recordings are throwaway, and a stale swap from an earlier
# session pops an "ignoring swapfile" notification over the shot.
Type "nvim -i NONE -n --cmd 'luafile assets/demo/demo-init.lua' $OBSIDIAN_BASE_DIR/Demo/Reading-list.md" Enter
# lazy-load + obsidian cache build + first query render
Sleep 10s
Show
Sleep 3.5s
# onto the fence, open the picker
Type "5G"
Sleep 1.5s
Enter
Sleep 3.5s
Type "memory"
Sleep 2.5s
Escape
Sleep 1s
Hide
Type ":qa!" Enter
