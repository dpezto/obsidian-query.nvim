# Hero shot: a TABLE fence rendering live results, then <CR> opening the
# result picker. Run `source assets/demo/setup.sh` first (throwaway vault).
#   vhs assets/tapes/hero.tape

Output assets/hero.gif

Source assets/tapes/style.tape

Hide
# -n (no swapfile): recordings are throwaway, and a stale swap from an earlier
# session pops an "ignoring swapfile" notification over the shot.
Type "nvim -i NONE -n --cmd 'luafile assets/demo/demo-init.lua' $HOME/.cache/obsidian-query-demo/Demo/Reading-list.md" Enter
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
