#!/bin/bash
# Runs inside the freshly installed Debian (chroot, as root) at the end of the
# unattended install. Turns it into a Claude kiosk:
#   - autologin on tty1 straight into Sway, apps shown as tabs, no desktop
#   - Claude Desktop (official apt repo), Claude Code CLI (official apt repo)
#   - Chromium with the Claude in Chrome extension force-installed
#   - user "claude" with passwordless sudo; Claude Code defaults to bypassPermissions
set -euxo pipefail
export DEBIAN_FRONTEND=noninteractive
USER_NAME=claude
HOME_DIR=/home/$USER_NAME
ANTHROPIC_KEY_FPR=31DDDE24DDFAB679F42D7BD2BAA929FF1A7ECACE

apt-get update
apt-get install -y --no-install-recommends \
	sway swaybg foot xwayland wl-clipboard grim \
	dbus-user-session libpam-systemd polkitd \
	xdg-desktop-portal xdg-desktop-portal-wlr xdg-desktop-portal-gtk \
	gnome-keyring libsecret-1-0 \
	fonts-dejavu fonts-noto-core fonts-noto-color-emoji adwaita-icon-theme \
	chromium \
	systemd-zram-generator systemd-timesyncd \
	sudo curl ca-certificates gnupg git ripgrep jq less nano

# --- Anthropic apt repositories (Claude Desktop + Claude Code), key checked by fingerprint
key=$(mktemp)
curl -fsSL https://downloads.claude.ai/claude-desktop/key.asc -o "$key"
gpg --show-keys --with-colons "$key" | grep -q "^fpr:::::::::$ANTHROPIC_KEY_FPR:" \
	|| { echo "Claude Desktop signing key fingerprint mismatch"; exit 1; }
install -m 0644 "$key" /usr/share/keyrings/claude-desktop-archive-keyring.asc
curl -fsSL https://downloads.claude.ai/keys/claude-code.asc -o "$key"
gpg --show-keys --with-colons "$key" | grep -q "^fpr:::::::::$ANTHROPIC_KEY_FPR:" \
	|| { echo "Claude Code signing key fingerprint mismatch"; exit 1; }
install -d -m 0755 /etc/apt/keyrings
install -m 0644 "$key" /etc/apt/keyrings/claude-code.asc
rm -f "$key"
echo "deb [arch=amd64,arm64 signed-by=/usr/share/keyrings/claude-desktop-archive-keyring.asc] https://downloads.claude.ai/claude-desktop/apt/stable stable main" \
	> /etc/apt/sources.list.d/claude-desktop.list
echo "deb [signed-by=/etc/apt/keyrings/claude-code.asc] https://downloads.claude.ai/claude-code/apt/stable stable main" \
	> /etc/apt/sources.list.d/claude-code.list
apt-get update
apt-get install -y claude-desktop claude-code

# --- Root access for Claude: passwordless sudo, and Claude Code runs without
# permission prompts (bypassPermissions refuses to run as root, so Claude runs
# as "claude" and uses sudo).
id "$USER_NAME"
passwd -l "$USER_NAME"                     # no password logins; autologin + sudo only
usermod -aG sudo,audio,video,input,render "$USER_NAME"
echo "$USER_NAME ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/90-claude
chmod 0440 /etc/sudoers.d/90-claude
install -d -m 0755 /etc/claude-code
cat > /etc/claude-code/managed-settings.json <<'EOF'
{
  "permissions": {
    "defaultMode": "bypassPermissions"
  }
}
EOF

# --- Chromium: force-install Claude in Chrome, quiet first run
install -d -m 0755 /etc/chromium/policies/managed
cat > /etc/chromium/policies/managed/claude-kiosk.json <<'EOF'
{
  "ExtensionInstallForcelist": [
    "fcoeoabgfenejglbffodgkkbkcdhcgfn;https://clients2.google.com/service/update2/crx"
  ],
  "DefaultBrowserSettingEnabled": false,
  "PromotionalTabsEnabled": false,
  "MetricsReportingEnabled": false,
  "BackgroundModeEnabled": false
}
EOF

# --- Autologin: tty1 runs the kiosk; the virtio serial console (hvc0) gives a
# shell to whoever runs the VM from the host (used for setup and checks).
install -d /etc/systemd/system/getty@tty1.service.d /etc/systemd/system/serial-getty@hvc0.service.d
cat > /etc/systemd/system/getty@tty1.service.d/autologin.conf <<EOF
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin $USER_NAME --noclear %I \$TERM
EOF
cat > /etc/systemd/system/serial-getty@hvc0.service.d/autologin.conf <<EOF
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin $USER_NAME --keep-baud 115200,57600,38400,9600 %I \$TERM
EOF
systemctl enable serial-getty@hvc0.service

# --- Host shares: user folders under tag "shared", boot files under "vmboot"
install -d /mnt/shared /mnt/vmboot
grep -q '^shared ' /etc/fstab || echo 'shared /mnt/shared virtiofs rw,nofail 0 0' >> /etc/fstab
grep -q '^vmboot ' /etc/fstab || echo 'vmboot /mnt/vmboot virtiofs rw,nofail 0 0' >> /etc/fstab
# One-way control from the Mac: jobs arrive read-only in /mnt/control; vm-agent
# runs them as claude and writes replies to the shared folder (vm-control/).
install -d /mnt/control
grep -q '^control ' /etc/fstab || echo 'control /mnt/control virtiofs ro,nofail 0 0' >> /etc/fstab
systemctl enable vm-agent.service

# The host boots this VM's kernel directly (no boot loader). Whenever a kernel
# or initramfs is installed, hand the newest pair to the host through the
# vmboot inbox; the host checks the files before it boots them.
cat > /usr/local/sbin/vm-export-boot <<'EOF'
#!/bin/sh
# Copy the newest kernel and initramfs to the VM bundle's boot/ folder on the host.
set -e
mountpoint -q /mnt/vmboot || mount /mnt/vmboot 2>/dev/null || { echo "vm-export-boot: host share not mounted; skipped"; exit 0; }
k=$(ls -1v /boot/vmlinuz-* 2>/dev/null | tail -n 1)
[ -n "$k" ] || exit 0
v=${k#/boot/vmlinuz-}
[ -f "/boot/initrd.img-$v" ] || exit 0
cp "$k" /mnt/vmboot/.vmlinuz.new && mv /mnt/vmboot/.vmlinuz.new /mnt/vmboot/vmlinuz
cp "/boot/initrd.img-$v" /mnt/vmboot/.initrd.new && mv /mnt/vmboot/.initrd.new /mnt/vmboot/initrd.img
echo "$v" > /mnt/vmboot/version
echo "vm-export-boot: host will boot $v next time"
EOF
chmod 0755 /usr/local/sbin/vm-export-boot
install -d /etc/kernel/postinst.d /etc/initramfs/post-update.d
printf '#!/bin/sh\nexec /usr/local/sbin/vm-export-boot\n' > /etc/kernel/postinst.d/zz-vm-export-boot
printf '#!/bin/sh\nexec /usr/local/sbin/vm-export-boot\n' > /etc/initramfs/post-update.d/vm-export-boot
chmod 0755 /etc/kernel/postinst.d/zz-vm-export-boot /etc/initramfs/post-update.d/vm-export-boot

# Memory: compressed swap in RAM (Electron + Chromium in 4 GB).
cat > /etc/systemd/zram-generator.conf <<'EOF'
[zram0]
zram-size = min(ram / 2, 4096)
compression-algorithm = zstd
EOF

# Kiosk polish: no blanking, no suspend, no Ctrl+Alt+Del reboot.
systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target ctrl-alt-del.target

# --- The user's session
install -d -o "$USER_NAME" -g "$USER_NAME" \
	"$HOME_DIR/.config/sway" "$HOME_DIR/.claude" "$HOME_DIR/.local/bin" \
	"$HOME_DIR/.local/share/keyrings" "$HOME_DIR/.config/google-chrome/NativeMessagingHosts" \
	"$HOME_DIR/.config/chromium"

# Claude Code installs its Claude in Chrome bridge for Google Chrome; Debian's
# Chromium reads its own folder, so point that at the same manifests.
ln -sfn ../google-chrome/NativeMessagingHosts "$HOME_DIR/.config/chromium/NativeMessagingHosts"

# Unlocked, password-less login keyring so apps can store sign-ins without a prompt.
printf 'login' > "$HOME_DIR/.local/share/keyrings/default"
cat > "$HOME_DIR/.local/share/keyrings/login.keyring" <<'EOF'
[keyring]
display-name=login
ctime=0
mtime=0
lock-on-idle=false
lock-after=false
EOF
chmod 0600 "$HOME_DIR/.local/share/keyrings/login.keyring"

cat > "$HOME_DIR/.claude/settings.json" <<'EOF'
{
  "skipDangerousModePermissionPrompt": true
}
EOF

ln -sfn /mnt/shared "$HOME_DIR/shared"

cat > "$HOME_DIR/.bash_profile" <<'EOF'
[ -f ~/.bashrc ] && . ~/.bashrc
# Claude Code session logs live in the Mac's shared folder (readable there live).
/usr/local/bin/vm-link-sessions
# The kiosk: tty1 goes straight into Sway. Leaving Sway logs out, and the
# autologin brings it straight back.
if [ -z "${WAYLAND_DISPLAY:-}" ] && [ "$(tty)" = /dev/tty1 ]; then
	export XDG_CURRENT_DESKTOP=sway XDG_SESSION_TYPE=wayland
	export WLR_RENDERER=pixman WLR_NO_HARDWARE_CURSORS=1   # virtio-gpu is 2D only
	export MOZ_ENABLE_WAYLAND=1 ELECTRON_OZONE_PLATFORM_HINT=auto
	exec sway > "$HOME/.sway.log" 2>&1
fi
EOF

# The Claude Code tab: wait until the API answers (the kiosk starts within seconds
# of boot, before the network is ready), then run claude; leave a shell behind when it exits.
cat > "$HOME_DIR/.local/bin/claude-code-tab" <<'EOF'
#!/bin/bash
cd ~
for _ in $(seq 60); do curl -s -m 3 -o /dev/null https://api.anthropic.com/ && break; sleep 1; done
claude
exec bash -l
EOF
chmod 0755 "$HOME_DIR/.local/bin/claude-code-tab"

cat > "$HOME_DIR/.local/bin/kiosk-help" <<'EOF'
#!/bin/sh
echo "⌘1 Claude   ⌘2 Chromium   ⌘3 Claude Code   ⌘↩ Terminal   ⌥⇥ next tab   ⌘F full screen   ⌘⇧Q close"
EOF
chmod 0755 "$HOME_DIR/.local/bin/kiosk-help"

cat > "$HOME_DIR/.config/sway/config" <<'EOF'
# Claude kiosk: every app is a tab in one full-screen container.
set $mod Mod4
font pango:DejaVu Sans 11
workspace_layout tabbed
default_border normal 0
default_floating_border normal 0
titlebar_padding 10 6
hide_edge_borders both
focus_on_window_activation focus
output * bg #191a1f solid_color

#                       border   background text     indicator child_border
client.focused          #d97757  #d97757    #ffffff  #d97757   #d97757
client.focused_inactive #2b2d35  #2b2d35    #c9cbd3  #2b2d35   #2b2d35
client.unfocused        #23252c  #23252c    #8b8e99  #23252c   #23252c

# Hand the session to systemd/dbus (portals, keyring, Claude Desktop).
exec systemctl --user import-environment WAYLAND_DISPLAY DISPLAY SWAYSOCK XDG_CURRENT_DESKTOP XDG_SESSION_TYPE
exec dbus-update-activation-environment --systemd WAYLAND_DISPLAY DISPLAY SWAYSOCK XDG_CURRENT_DESKTOP XDG_SESSION_TYPE
exec gnome-keyring-daemon --start --components=secrets

# The kiosk apps (each key brings its app back if it was closed).
exec claude-desktop
exec chromium
exec foot --title "Claude Code" ~/.local/bin/claude-code-tab

bindsym $mod+1 exec claude-desktop
bindsym $mod+2 exec chromium
bindsym $mod+3 exec foot --title "Claude Code" ~/.local/bin/claude-code-tab
bindsym $mod+Return exec foot
bindsym Mod1+Tab focus right
bindsym Mod1+Shift+Tab focus left
bindsym $mod+f fullscreen toggle
bindsym $mod+Shift+q kill

bar {
    position top
    height 26
    status_command while ~/.local/bin/kiosk-help; do sleep 3600; done
    tray_output *
    colors {
        background #191a1f
        statusline #8b8e99
        focused_workspace #191a1f #191a1f #191a1f
        inactive_workspace #191a1f #191a1f #191a1f
    }
    workspace_buttons no
}
EOF

chown -R "$USER_NAME:$USER_NAME" "$HOME_DIR"
apt-get clean
echo "KIOSK-SETUP-OK"
