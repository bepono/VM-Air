#!/bin/sh
# Smoke test — run as root over the serial console while the desktop is up:
# waits for the XFCE session, opens Chromium and a terminal running Claude
# Code, and drops screenshots into the host share.
set -eu
i=0
until pgrep -x xfce4-session >/dev/null; do
	i=$((i + 1))
	if [ "$i" -ge 90 ]; then
		echo "no XFCE session after 90s"
		rc-service lightdm status || true
		tail -n 40 /var/log/lightdm/lightdm.log /var/log/lightdm/x-0.log 2>/dev/null || true
		exit 1
	fi
	sleep 1
done
echo "xfce session up after ${i}s"
apk add --quiet --virtual .smoke scrot
sleep 8
su alpine -c 'cd; DISPLAY=:0 scrot -o /tmp/desktop.png'
su alpine -c 'cd; export DISPLAY=:0; . /etc/profile.d/claude-code.sh
	(chromium-browser --no-first-run https://example.com >/tmp/chromium.log 2>&1 &)
	sleep 20
	(xfce4-terminal --geometry 80x12+40+420 -e "bash -lc \"claude --version; uname -a; exec bash\"" >/dev/null 2>&1 &)
	sleep 6
	scrot -o /tmp/apps.png'
cp /tmp/desktop.png /tmp/apps.png /mnt/setup/
apk del --quiet .smoke
echo "=== state"
cat /proc/cmdline
grep -c . /etc/fstab; grep shared /etc/fstab; mount | grep virtiofs
DISPLAY=:0 XAUTHORITY=/home/alpine/.Xauthority xrandr 2>/dev/null | head -3 || true
tail -n 5 /tmp/chromium.log || true
free -m | sed -n 2p
