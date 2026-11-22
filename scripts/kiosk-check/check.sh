#!/bin/sh
# Checks the kiosk from inside the guest (runs as "claude" on the serial console).
export XDG_RUNTIME_DIR=/run/user/$(id -u)
out=/mnt/shared
echo "=== system"; . /etc/os-release; echo "$PRETTY_NAME, kernel $(uname -r)"; nproc; free -m | sed -n '2,3p'
echo "=== root"; sudo -n id
echo "=== claude code"; claude --version; cat /etc/claude-code/managed-settings.json
echo "=== desktop"; dpkg-query -W claude-desktop claude-code chromium sway 2>&1
i=0
until pgrep -u claude -x sway >/dev/null && ls "$XDG_RUNTIME_DIR"/wayland-* >/dev/null 2>&1; do
	i=$((i + 1)); [ $i -ge 60 ] && { echo "no sway session"; tail -n 30 ~/.sway.log; exit 1; }; sleep 2
done
echo "sway up"
export WAYLAND_DISPLAY=$(basename "$(ls "$XDG_RUNTIME_DIR"/wayland-? | head -n 1)")
export SWAYSOCK=$(ls "$XDG_RUNTIME_DIR"/sway-ipc.*.sock | head -n 1)
sleep 45   # let Claude Desktop and Chromium finish starting
echo "=== windows"
swaymsg -t get_tree | jq -r '.. | objects | select(.type? == "con" and .pid?) | "\(.app_id // .window_properties.class)  —  \(.name)"'
grim "$out/kiosk-1.png"
swaymsg '[app_id="chromium"] focus' >/dev/null 2>&1 || swaymsg '[class="Chromium"] focus' >/dev/null 2>&1
sleep 3; grim "$out/kiosk-2.png"
swaymsg '[title="Claude Code"] focus' >/dev/null 2>&1; sleep 3; grim "$out/kiosk-3.png"
echo "=== extension"
ls ~/.config/chromium/Default/Extensions/ 2>&1
ls -la ~/.config/chromium/NativeMessagingHosts/ 2>&1
echo "=== memory with apps running"; free -m | sed -n '2,3p'; swapon --show
tail -n 5 ~/.sway.log
