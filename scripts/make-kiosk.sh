#!/bin/sh
# Build vms/kiosk: Debian 13 (arm64) Claude kiosk, unattended.
#   - Debian installer booted directly with a preseed, console on the serial port
#   - scripts/kiosk/kiosk-setup.sh runs in the new system at the end of the install
#   - the finished VM boots its own kernel directly (no boot loader); the guest
#     hands kernel updates back to vms/kiosk/boot/ by itself
# Takes 20–40 minutes depending on the connection.
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"

VM=$ROOT/vms/kiosk
DI=$ROOT/images/debian/di
STAGE=$ROOT/build/kiosk-stage
DI_URL=https://deb.debian.org/debian/dists/trixie/main/installer-arm64/current/images

[ -x bin/vmctl ] || ./build.sh
mkdir -p "$DI" logs build

# 1. Debian installer kernel + initrd, checked against Debian's SHA256SUMS.
curl -fsSL "$DI_URL/SHA256SUMS" -o "$DI/SHA256SUMS"
for f in linux initrd.gz; do
	[ -f "$DI/$f" ] || curl -fL -o "$DI/$f" "$DI_URL/netboot/debian-installer/arm64/$f"
	sum=$(grep -E "netboot/debian-installer/arm64/$f\$" "$DI/SHA256SUMS" | cut -d' ' -f1)
	echo "$sum  $DI/$f" | shasum -a 256 -c -
done

# 2. Preseed, appended to the installer's initrd as a second cpio archive.
TZ_NAME=$(readlink /etc/localtime | sed 's|.*/zoneinfo/||')
PW=$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 24)  # locked after install
rm -rf "$STAGE"
mkdir -p "$STAGE/initrd" "$STAGE/share/out"
cp scripts/kiosk/kiosk-setup.sh scripts/kiosk/vm-link-sessions scripts/kiosk/vm-agent scripts/kiosk/vm-agent.service "$STAGE/share/"
cat > "$STAGE/initrd/preseed.cfg" <<EOF
d-i debian-installer/locale string en_US.UTF-8
d-i keyboard-configuration/xkb-keymap select us
d-i hw-detect/load_firmware boolean false
d-i netcfg/choose_interface select auto
d-i netcfg/get_hostname string kiosk
d-i netcfg/get_domain string local
d-i netcfg/hostname string kiosk
d-i mirror/country string manual
d-i mirror/http/hostname string deb.debian.org
d-i mirror/http/directory string /debian
d-i mirror/http/proxy string
d-i passwd/root-login boolean false
d-i passwd/user-fullname string Claude
d-i passwd/username string claude
d-i passwd/user-password password $PW
d-i passwd/user-password-again password $PW
d-i clock-setup/utc boolean true
d-i time/zone string $TZ_NAME
d-i clock-setup/ntp boolean true
d-i partman-auto/disk string /dev/vda
d-i partman-auto/method string regular
d-i partman-auto/expert_recipe string rootonly :: 4000 10000 -1 ext4 \$primary{ } method{ format } format{ } use_filesystem{ } filesystem{ ext4 } mountpoint{ / } .
d-i partman-auto/choose_recipe select rootonly
d-i partman-basicfilesystems/no_swap boolean false
d-i partman-partitioning/confirm_write_new_label boolean true
d-i partman/choose_partition select finish
d-i partman/confirm boolean true
d-i partman/confirm_nooverwrite boolean true
d-i partman-efi/non_efi_system boolean true
d-i base-installer/kernel/image string linux-image-arm64
d-i apt-setup/cdrom/set-first boolean false
d-i pkgsel/run_tasksel boolean false
tasksel tasksel/first multiselect
d-i pkgsel/include string sudo curl ca-certificates gnupg
d-i pkgsel/upgrade select full-upgrade
popularity-contest popularity-contest/participate boolean false
d-i grub-installer/skip boolean true
d-i lilo-installer/skip boolean true
d-i nobootloader/confirmation_common note
d-i preseed/late_command string mkdir -p /mnt/host; mount -t virtiofs shared /mnt/host; cp /mnt/host/kiosk-setup.sh /target/root/kiosk-setup.sh; cp /mnt/host/vm-link-sessions /target/usr/local/bin/vm-link-sessions; chmod 0755 /target/usr/local/bin/vm-link-sessions; cp /mnt/host/vm-agent /target/usr/local/bin/vm-agent; chmod 0755 /target/usr/local/bin/vm-agent; cp /mnt/host/vm-agent.service /target/etc/systemd/system/vm-agent.service; in-target sh -c 'bash /root/kiosk-setup.sh > /root/kiosk-setup.log 2>&1'; echo \$? > /mnt/host/out/setup.status; cp /target/root/kiosk-setup.log /mnt/host/out/setup.log; rm -f /target/root/kiosk-setup.sh; cp /target/boot/vmlinuz-* /target/boot/initrd.img-* /mnt/host/out/; sync; umount /mnt/host
d-i finish-install/reboot_in_progress note
d-i debian-installer/exit/poweroff boolean true
EOF
(cd "$STAGE/initrd" && echo preseed.cfg | cpio -o -H newc 2>/dev/null | gzip -9) > "$STAGE/preseed.cpio.gz"
cat "$DI/initrd.gz" "$STAGE/preseed.cpio.gz" > "$STAGE/initrd-preseed.gz"

# 3. The VM: fresh 32 GB disk, 4 CPUs, 4 GB, 1440×900.
if [ -f "$VM/config.json" ]; then
	echo "$VM already exists; move it away to rebuild" >&2
	exit 1
fi
bin/vmctl linux-create "$VM" --disk 32 --cpus 4 --mem 4

# 4. Install. The installer powers the VM off when it is done.
echo "== installing Debian + kiosk (serial log: logs/kiosk-install.log)"
bin/vmctl linux-run "$VM" --headless --serial "$ROOT/logs/kiosk-install.log" \
	--kernel "$DI/linux" --initrd "$STAGE/initrd-preseed.gz" \
	--cmdline "console=hvc0 auto=true priority=critical" \
	--share "$STAGE/share" > logs/kiosk-runner.log 2>&1

status=$(cat "$STAGE/share/out/setup.status" 2>/dev/null || echo missing)
if [ "$status" != 0 ] || ! grep -q KIOSK-SETUP-OK "$STAGE/share/out/setup.log"; then
	echo "kiosk setup failed (status $status); see $STAGE/share/out/setup.log" >&2
	tail -n 30 "$STAGE/share/out/setup.log" >&2 || true
	exit 1
fi

# 5. Direct boot from now on: newest kernel + initrd into the bundle.
mkdir -p "$VM/boot"
k=$(ls -1 "$STAGE/share/out"/vmlinuz-* | sort -V | tail -n 1)
v=${k##*/vmlinuz-}
cp "$k" "$VM/boot/vmlinuz"
cp "$STAGE/share/out/initrd.img-$v" "$VM/boot/initrd.img"
echo "$v" > "$VM/boot/version"
python3 -I - "$VM/config.json" "$ROOT/shared" <<'EOF'
import json, sys
p, shared = sys.argv[1], sys.argv[2]
cfg = json.load(open(p))
cfg.update(
    kernel="boot/vmlinuz",
    initrd="boot/initrd.img",
    cmdline="root=/dev/vda1 ro console=tty0 console=hvc0 quiet",
    width=1440,
    height=900,
    shares=[{"path": shared, "readOnly": False}],
)
json.dump(cfg, open(p, "w"), indent=2, sort_keys=True)
EOF
cp "$STAGE/share/out/setup.log" logs/kiosk-setup.log
rm -rf "$STAGE"
echo "done — kernel $v; start it from VM Manager or: bin/vmctl linux-run vms/kiosk"
