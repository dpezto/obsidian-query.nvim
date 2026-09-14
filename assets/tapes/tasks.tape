Output assets/tasks.gif

Source assets/tapes/style.tape

Hide
Type "source assets/demo/setup.sh" Enter
Type "nvim -i NONE -n --cmd 'luafile assets/demo/demo-init.lua' $OBSIDIAN_BASE_DIR/Demo/Open-tasks.md" Enter
Sleep 10s
Show
Sleep 3.5s
# onto the fence, open the TASK picker
Type "4G"
Sleep 1.5s
Enter
Sleep 3s
# Complete two different tasks; both rows and the preview update.
Ctrl+t
Sleep 2s
Ctrl+n
Sleep 1s
Ctrl+t
Sleep 2s
# Return to the note and show the remaining count dropping from eight to six.
Escape
Escape
Type "gg"
Sleep 4s
# Reopen the filtered results: completed tasks are gone.
Type "4G"
Enter
Sleep 3s
Escape
Escape
Sleep 1s
Hide
Type ":qa!" Enter
