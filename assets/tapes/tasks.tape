# TASK query: grouped open tasks, picker, live <C-t> checkbox toggle.
# Run `source assets/demo/setup.sh` first (throwaway vault).
#   vhs assets/tapes/tasks.tape

Output assets/tasks.gif

Source assets/tapes/style.tape

Hide
Type "nvim -i NONE -n --cmd 'luafile assets/demo/demo-init.lua' $HOME/.cache/obsidian-query-demo/Demo/Open-tasks.md" Enter
Sleep 10s
Show
Sleep 3.5s
# onto the fence, open the TASK picker
Type "4G"
Sleep 1.5s
Enter
Sleep 3s
# toggle the selected task's checkbox in its file
Ctrl+t
Sleep 2.5s
Ctrl+t
Sleep 2s
Escape
Sleep 2s
Hide
Type ":qa!" Enter
