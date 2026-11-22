#!/bin/sh
# Check what an "internet only" VM can reach, from inside it.
#
#   scripts/netguard/verify.sh [VM]        (default VM: alpine; must be stopped)
#
# Boots the VM headless, probes from inside, powers it off, and prints a table.
# With the network guard installed every local probe should be BLOCKED while the
# internet and DNS stay OK; without it, local probes show up as LEAK. Exits 0
# only if the guard is installed and nothing leaks. Needs no admin rights and
# changes nothing on the Mac.
#
# Traffic with a forged sender address can't be observed from inside the VM;
# the guard's rule hit counters show it: sudo scripts/netguard/install.sh status
set -eu
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
VM=${1:-alpine}
B=$ROOT/vms/$VM
[ -f "$B/config.json" ] || { echo "no VM $VM"; exit 2; }
cfg() { python3 -I -c "import json,sys; print(json.load(open(sys.argv[1])).get(sys.argv[2]) or '')" "$B/config.json" "$1"; }
[ "$(cfg kind)" = linux ] || { echo "$VM is not a Linux VM"; exit 2; }
[ "$(cfg network)" = internet-only ] || { echo "$VM is not set to 'Internet only' (VM Manager ▸ Network)"; exit 2; }
if [ -s "$B/.lock" ] && ps -p "$(cat "$B/.lock")" -o command= 2>/dev/null | grep -q vmctl; then
	echo "$VM is running; shut it down first (the check boots it headless)"; exit 2
fi
case $VM in
alpine) CONSOLE="$ROOT/scripts/alpine-console.exp" ;;
kiosk) CONSOLE="$ROOT/scripts/kiosk-console.exp" ;;
*) echo "no console script for $VM"; exit 2 ;;
esac

GUARD=no
[ -f /Library/LaunchDaemons/local.vm-netguard.plist ] && GUARD=yes
ROUTER=$(route -n get default | awk '/gateway:/{print $2}')
MAC_LAN=$(ipconfig getifaddr "$(route -n get default | awk '/interface:/{print $2}')" || true)
GW=$(cfg subnet | sed 's/\.0$/.1/')
LAN_BCAST=$(ifconfig "$(route -n get default | awk '/interface:/{print $2}')" | awk '/inet / {for (i = 1; i < NF; i++) if ($i == "broadcast") print $(i + 1); exit}')
MAC_V6=$(ifconfig "$(route -n get default | awk '/interface:/{print $2}')" | awk '/inet6 / && $2 !~ /^fe80/ {print $2; exit}')
OTHER_NET=$(ifconfig | awk '/^[a-z]/{b=($1 ~ /^bridge/)} b && /inet 192\.168\./ && $2 !~ /^192\.168\.(24[0-9]|25[0-5])\./ {print $2; exit}')

STAGE=$(mktemp -d "$ROOT/build/netcheck.XXXXXX")
trap 'rm -rf "$STAGE"' EXIT
cat > "$STAGE/probe.sh" <<EOF
#!/bin/sh
# Runs inside the VM. Prints: RESULT|name|kind|ok-or-not
r() { echo "RESULT|\$1|\$2|\$3"; }
n=0; until ip -4 addr show 2>/dev/null | grep -q 'inet 192\.168\.2[45][0-9]\.'; do n=\$((n+1)); [ \$n -ge 40 ] && break; sleep 1; done
tcp() { nc -z -w 3 "\$1" "\$2" 2>/dev/null && echo yes || echo no; }
png() { ping -c 1 -W 2 "\$@" >/dev/null 2>&1 && echo yes || echo no; }
r "internet over IPv4 (https://example.com)" allow \$(curl -4 -s -m 10 -o /dev/null https://example.com && echo yes || echo no)
r "DNS through the Mac ($GW)" allow \$(nslookup example.com $GW >/dev/null 2>&1 && echo yes || echo no)
r "internet over IPv6" block \$(curl -6 -s -m 6 -o /dev/null https://example.com 2>/dev/null && echo yes || echo no)
r "router $ROUTER: ping" block \$(png $ROUTER)
r "router $ROUTER: DNS service (tcp 53)" block \$(tcp $ROUTER 53)
r "router $ROUTER: web admin (tcp 80)" block \$(tcp $ROUTER 80)
r "router $ROUTER: DNS lookup through it" block \$(nslookup example.com $ROUTER >/dev/null 2>&1 && echo yes || echo no)
r "this Mac on the LAN ($MAC_LAN): ping" block \$(png $MAC_LAN)
r "this Mac via the VM gateway ($GW): ping" block \$(png $GW)
for p in 22 88 445 548 3283 5000 5900 7000 8080; do
	r "this Mac ($MAC_LAN) tcp \$p" block \$(tcp $MAC_LAN \$p)
	r "this Mac via gateway ($GW) tcp \$p" block \$(tcp $GW \$p)
done
[ -n "$OTHER_NET" ] && r "default VM network ($OTHER_NET): ping" block \$(png $OTHER_NET)
[ -n "$MAC_V6" ] && r "this Mac's IPv6 ($MAC_V6): ping" block \$(png -6 $MAC_V6)
[ -n "$LAN_BCAST" ] && r "LAN broadcast ($LAN_BCAST) gets replies" block \$(ping -b -c 1 -W 2 $LAN_BCAST 2>/dev/null | grep -q 'bytes from' && echo yes || echo no)
EOF

echo "Booting $VM headless to probe its network (guard installed: $GUARD)…"
"$CONSOLE" probe.sh "$ROOT/bin/vmctl" linux-run "$B" --headless --share "$STAGE" > "$STAGE/console.log" 2>&1 || true
LC_ALL=C tr '\r' '\n' < "$STAGE/console.log" | LC_ALL=C grep -a '^RESULT|' > "$STAGE/results" || true
[ -s "$STAGE/results" ] || { echo "no results — VM console output:"; tail -n 20 "$STAGE/console.log"; exit 2; }

fail=0
printf '\n%-52s %s\n' "CHECK" "RESULT"
while IFS='|' read -r _ name kind got; do
	case "$kind:$got" in
	allow:yes) s="OK" ;;
	allow:no) s="FAILED (should work)"; fail=1 ;;
	block:no) s="blocked" ;;
	block:yes) s="LEAK — reachable"; fail=1 ;;
	esac
	# Closed ports look the same with or without the guard; only report open ones.
	case "$name:$got" in "this Mac"*"tcp "*:no) continue ;; esac
	printf '%-52s %s\n' "$name" "$s"
done < "$STAGE/results"
echo "(Mac tcp ports that are closed anyway are not listed.)"
echo
if [ "$GUARD" = no ]; then
	echo "The network guard is NOT installed. Install it with:"
	echo "  sudo $ROOT/scripts/netguard/install.sh"
	exit 1
fi
[ $fail = 0 ] && echo "All good: internet works, nothing local is reachable." || echo "Something is wrong — see above."
echo "Forged-sender traffic: see the hit counters with  sudo $ROOT/scripts/netguard/install.sh status"
exit $fail
