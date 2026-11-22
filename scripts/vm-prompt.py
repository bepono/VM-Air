"""Send a prompt or a command to a VM from the Mac, and print the reply.

    scripts/vm-prompt [VM] "prompt"              ask Claude Code in the VM (default VM: kiosk)
    scripts/vm-prompt [VM] --continue "prompt"   continue its latest conversation in that folder
    scripts/vm-prompt [VM] --shell "command"     run a shell command in the VM (as claude)
    scripts/vm-prompt [VM] --list                show recent jobs

Options: --cwd DIR (folder inside the VM, default ~/shared/projects),
--no-wait (send and return), --timeout SECONDS (default 1800).

It's one-way: the job goes into the VM's control folder, which the VM can read
but not write; the reply comes back as a plain file in the shared folder. The
reply is data from the VM, so treat it as untrusted: this tool only prints it.
"""
import argparse
import datetime
import json
import os
import secrets
import sys
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def bundle_for(vm):
    if os.path.isfile(os.path.join(vm, "config.json")):
        return os.path.abspath(vm)
    path = os.path.join(ROOT, "vms", vm)
    if not os.path.isfile(os.path.join(path, "config.json")):
        sys.exit(f"no VM named {vm} in {os.path.join(ROOT, 'vms')}")
    return path


def results_dirs(bundle):
    """vm-control/*/results folders in the VM's shared folders (and one level down)."""
    try:
        shares = [s["path"] for s in json.load(open(os.path.join(bundle, "config.json"))).get("shares", [])]
    except (OSError, ValueError):
        shares = []
    found = []
    for share in shares:
        for base in [share] + [os.path.join(share, d) for d in sorted(os.listdir(share)) if os.path.isdir(os.path.join(share, d))]:
            vc = os.path.join(base, "vm-control")
            if os.path.isdir(vc) and not os.path.islink(vc):
                for host in sorted(os.listdir(vc)):
                    r = os.path.join(vc, host, "results")
                    if os.path.isdir(r) and not os.path.islink(r):
                        found.append(r)
    return found


def read_plain(path, limit=None):
    """Read a file the VM wrote, refusing symlinks."""
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    with os.fdopen(fd, "rb") as f:
        data = f.read(limit) if limit else f.read()
    return data.decode("utf-8", errors="replace")


def find_result(bundle, job_id):
    for r in results_dirs(bundle):
        p = os.path.join(r, job_id + ".json")
        if os.path.isfile(p) and not os.path.islink(p):
            try:
                return r, json.loads(read_plain(p, 4096))
            except ValueError:
                pass
    return None, None


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("args", nargs="*", help="[VM] text")
    ap.add_argument("--shell", action="store_true", help="the text is a shell command")
    ap.add_argument("--continue", dest="cont", action="store_true", help="continue the latest conversation")
    ap.add_argument("--cwd", default="~/shared/projects", help="folder inside the VM")
    ap.add_argument("--no-wait", action="store_true")
    ap.add_argument("--timeout", type=int, default=1800)
    ap.add_argument("--list", action="store_true", help="show recent jobs")
    a = ap.parse_intermixed_args()

    vm, text = "kiosk", None
    if a.list:
        vm = a.args[0] if a.args else vm
    elif len(a.args) == 1:
        text = a.args[0]
    elif len(a.args) == 2:
        vm, text = a.args
    else:
        ap.error("give the prompt (or command) as one quoted argument, optionally after the VM name")
    bundle = bundle_for(vm)
    inbox = os.path.join(bundle, "control", "inbox")
    os.makedirs(inbox, exist_ok=True)

    if a.list:
        jobs = sorted(f for f in os.listdir(inbox) if f.endswith(".json"))[-15:]
        for f in jobs:
            job = json.load(open(os.path.join(inbox, f)))
            _, res = find_result(bundle, job["id"])
            state = "sent" if not res else res["state"] + (f" (exit {res['exit']})" if res.get("exit") is not None else "")
            what = job.get("prompt") or job.get("command") or ""
            print(f"{job['id']}  {state:<14} {job['type']:<6} {' '.join(what.split())[:70]}")
        return

    stamp = datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
    job_id = f"{stamp}-{secrets.token_hex(3)}"
    job = {"id": job_id, "type": "shell" if a.shell else "prompt", "cwd": a.cwd, "created": stamp}
    if a.shell:
        job["command"] = text
    else:
        job["prompt"] = text
        job["continue"] = a.cont
    tmp = os.path.join(inbox, "." + job_id + ".tmp")
    with open(tmp, "w") as f:
        json.dump(job, f, indent=2)
    os.rename(tmp, os.path.join(inbox, job_id + ".json"))
    print(f"sent {job_id} to {os.path.basename(bundle)}", file=sys.stderr)
    if a.no_wait:
        return

    deadline = time.time() + a.timeout
    shown_running = False
    while time.time() < deadline:
        r, res = find_result(bundle, job_id)
        if res and res.get("state") == "running" and not shown_running:
            print("running… (follow it live with scripts/vm-activity)", file=sys.stderr)
            shown_running = True
        if res and res.get("state") == "done":
            out = os.path.join(r, job_id + ".out")
            if os.path.isfile(out) and not os.path.islink(out):
                sys.stdout.write(read_plain(out))
            if res.get("exit"):
                print(f"(exit {res['exit']})", file=sys.stderr)
            sys.exit(0 if not res.get("exit") else 1)
        time.sleep(1)
    sys.exit(f"no reply within {a.timeout}s (is the VM running with vm-agent installed?). It may still finish: scripts/vm-prompt --list")


if __name__ == "__main__":
    main()
