# CALENDAR heat map: month navigation with <Left>/<Right>/<Home>.
# Run `source assets/demo/setup.sh` first (throwaway vault).
#   vhs assets/tapes/calendar.tape

Output assets/calendar.gif

Source assets/tapes/style.tape

Hide
Type "nvim -i NONE -n --cmd 'luafile assets/demo/demo-init.lua' $HOME/.cache/obsidian-query-demo/Demo/Journal.md" Enter
Sleep 10s
Show
Sleep 3s
# cursor onto the fence so the arrow keys drive the calendar
Type "4G"
Sleep 1.5s
Left
Sleep 2s
Left
Sleep 2s
Right
Sleep 2s
# (vhs has no Home key; the second Right lands back on the current month)
Right
Sleep 2.5s
Hide
Type ":qa!" Enter
