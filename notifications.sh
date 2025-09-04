#!/bin/sh

# Paths to the executables
DUNSTCTL="/etc/profiles/per-user/$USER/bin/dunstctl"
GREP="/run/current-system/sw/bin/grep"

# Check if Dunst is paused
if $DUNSTCTL is-paused | $GREP -q "true"; then
  # Get the count of waiting notifications
  COUNT=$($DUNSTCTL count waiting)
  # Output icon and count only if COUNT is greater than 0
  if [ "$COUNT" -gt 0 ]; then
    echo " %{F#6e6a86}󰂛 ($COUNT) "
  else
    echo " 󰂛 "
  fi
else
  # Output icon for active notifications
  echo " %{F#F6C177}󰂚 "
fi
#!/bin/sh
