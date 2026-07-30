# Core-Search fence: matched lines under each note, then the picker.
# Run `source assets/demo/setup.sh` first (throwaway vault).
#   vhs assets/tapes/search.tape

Output assets/search.gif

Source assets/tapes/style.tape

Hide
Type "nvim -i NONE -n --cmd 'luafile assets/demo/demo-init.lua' $HOME/.cache/obsidian-query-demo/Demo/Search.md" Enter
Sleep 10s
Show
Sleep 3.5s
# onto the fence, open the picker (jumps to exact matched lines)
Type "4G"
Sleep 1.5s
Enter
Sleep 3.5s
Escape
Sleep 1s
Hide
Type ":qa!" Enter
