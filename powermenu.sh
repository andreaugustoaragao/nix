#!/bin/sh

eww close powermenu || eww open powermenu

#rofi_command="/etc/profiles/per-user/$USER/bin/rofi -theme $HOME/.local/bin/powermenu.rasi"
#
## Options
#shutdown=" shutdown"
#reboot=" reboot"
#lock=" lock"
#suspend=" suspend"
#logout=" logout"
#
## Variable passed to rofi
#options="$lock\n$suspend\n$logout\n$reboot\n$shutdown"
#
#chosen="$(echo "$options" | $rofi_command -dmenu -selected-row 0)"
#case $chosen in
#$shutdown)
#  /run/current-system//sw/bin/systemctl poweroff
#  ;;
#$reboot)
#  /run/current-system//sw/bin/systemctl reboot
#  ;;
#$lock)
#  /run/current-system/sw/bin/xset s activate
#  ;;
#$suspend)
#  #amixer set Master mute
#  /run/current-system//sw/bin/systemctl suspend
#  ;;
#$logout)
#  /etc/profiles/per-user/$USER/bin/i3-msg exit
#  ;;
#esac
