---
name: vm-network-check
description: Check that an "Internet only" VM (in this repository's vms/ folder) can reach the internet but nothing on the local network or this Mac (the network guard). Use when asked to verify, test or audit VM network isolation, after the guard is installed or updated, or after changing a VM's network setting.
---

# VM network check

The VMs here run on Apple's Virtualization.framework. A VM set to **Internet only**
(`"network": "internet-only"` in `vms/<vm>/config.json`) gets its own network in
192.168.241–254.x with no IPv6. The **network guard** (pf rules installed on the Mac
by `scripts/netguard/install.sh`) blocks those networks from private/LAN addresses,
the Mac, broadcast/multicast and IPv6, and drops traffic with forged senders.

## Run the check

```sh
scripts/netguard/verify.sh [vm]    # from the repository root; default vm: alpine
```

- The VM must be **stopped** (the script boots it headless, probes, powers it off).
  Supported: `alpine`, `kiosk`. It must be set to Internet only.
- Needs no admin rights and changes nothing on the Mac. Takes about a minute.
- Exit 0 means: guard installed, internet and DNS OK, every local probe blocked.

Report the table to the user. `LEAK — reachable` on any line, or `FAILED` for
internet/DNS, is a problem to investigate; say which line.

## Things to know

- **Don't install, update or remove the guard yourself.** It changes the Mac's firewall
  and needs the user's admin password. Give them the command instead:
  `sudo <repository>/scripts/netguard/install.sh` (also `status`, `uninstall`).
  After editing `scripts/netguard/vm-netguard`, the user must rerun the install for it
  to take effect; check with `cmp "/Library/Application Support/VMNetGuard/vm-netguard" scripts/netguard/vm-netguard`.
- Guard running? `launchctl print system/local.vm-netguard | grep 'state ='`; its log:
  `/usr/bin/log show --last 1h --style compact --predicate 'process == "logger"' | grep -E 'rules loaded|failed'`
  (in zsh, `log` is a builtin — use `/usr/bin/log`).
- Forged-sender traffic can't be observed from inside the VM. The user can see the
  rules' packet counters with `sudo …/install.sh status`.
- Don't open listeners on the Mac to test reachability: if the Mac's application
  firewall is on, that can pop up "accept incoming connections?" dialogs for the user.
- A running VM uses the network it was started with; a changed setting applies at its
  next start. VMs on the default network ("Internet and local network") are not guarded.
