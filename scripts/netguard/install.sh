#!/bin/sh
# Install, check or remove the VM network guard (needs your admin password):
#
#   sudo scripts/netguard/install.sh             install or update, and start it
#   sudo scripts/netguard/install.sh status      show the rules in force
#   sudo scripts/netguard/install.sh uninstall   stop it and remove everything
#
# What it installs: one script in /Library/Application Support/VMNetGuard and a
# launchd job that runs it as root. It only adds rules to its own pf anchor
# (com.apple/050.VMNetGuard); /etc/pf.conf is not changed. See vm-netguard for
# the rules themselves.
set -eu
[ "$(id -u)" = 0 ] || { echo "Run it with sudo: sudo $0 ${1:-}"; exit 1; }
DIR="/Library/Application Support/VMNetGuard"
LABEL=local.vm-netguard
PLIST=/Library/LaunchDaemons/$LABEL.plist
ANCHOR=com.apple/050.VMNetGuard

case "${1:-install}" in
install)
	install -d -o root -g wheel -m 755 "$DIR"
	install -o root -g wheel -m 755 "$(cd "$(dirname "$0")" && pwd)/vm-netguard" "$DIR/vm-netguard"
	cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key><string>$LABEL</string>
	<key>ProgramArguments</key>
	<array><string>/bin/sh</string><string>$DIR/vm-netguard</string></array>
	<key>RunAtLoad</key><true/>
	<key>KeepAlive</key><true/>
</dict>
</plist>
EOF
	chown root:wheel "$PLIST"
	chmod 644 "$PLIST"
	launchctl bootout "system/$LABEL" 2>/dev/null || true
	launchctl bootstrap system "$PLIST"
	sleep 4
	echo "Network guard installed. Rules in force:"
	pfctl -a "$ANCHOR" -s rules 2>/dev/null
	;;
status)
	launchctl print "system/$LABEL" 2>/dev/null | grep -E '^\s*state' || echo "not running"
	pfctl -s info 2>/dev/null | grep Status
	echo "Rules, with how many packets each has matched:"
	pfctl -a "$ANCHOR" -v -s rules 2>/dev/null | sed -n 's/^\(@\{0,1\}[a-z].*\)/\1/p; s/^ *\[ Evaluations.*Packets: *\([0-9]*\).*/      packets matched: \1/p'
	;;
uninstall)
	launchctl bootout "system/$LABEL" 2>/dev/null || true
	rm -f "$PLIST"
	rm -rf "$DIR"
	pfctl -a "$ANCHOR" -F all 2>/dev/null || true
	echo "Network guard removed."
	;;
*)
	echo "usage: sudo $0 [install|status|uninstall]"
	exit 2
	;;
esac
