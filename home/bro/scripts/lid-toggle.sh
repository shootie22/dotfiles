#!/usr/bin/env bash
# Toggle whether closing the lid suspends the laptop (SUPER+L). Useful for
# letting a rebuild or a long job finish while carrying the laptop home.
# Works by holding a systemd "handle-lid-switch" inhibitor, plus sleep and
# idle so nothing else suspends it either. Toggling again releases it.
who=lid-toggle

if systemd-inhibit --list --no-legend 2>/dev/null | grep -qw -- "$who"; then
  pkill -f "systemd-inhibit --who=$who"
  notify-send -a "Lid" -u normal "Lid: suspends again" \
    "Closing the lid puts the laptop to sleep, as usual."
else
  setsid -f systemd-inhibit --who="$who" --what=handle-lid-switch:sleep:idle \
    --why="Keep running with the lid closed" --mode=block sleep infinity
  notify-send -a "Lid" -u critical "Lid: stays awake" \
    "Closing the lid won't suspend. Press SUPER+L again when you're done, and mind the heat in a bag."
fi
