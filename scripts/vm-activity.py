"""Follow, on the Mac, what Claude Code is doing inside a VM — live.

The VMs keep their Claude Code session logs in the shared folder under
vm-sessions/<vm>/projects/<project>/<session>.jsonl. This prints the newest
session's recent messages and tool calls, then follows it (switching to a newer
session when one starts).

    scripts/vm-activity [VM] [--lines N] [--once] [--share DIR]
"""
import argparse
import json
import os
import sys
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def session_roots(vm, extra_share=None):
    """vm-sessions/<vm>/projects folders in this VM's shared folders."""
    cfg_path = os.path.join(ROOT, "vms", vm, "config.json")
    shares = [extra_share] if extra_share else []
    try:
        shares += [s["path"] for s in json.load(open(cfg_path)).get("shares", [])]
    except (OSError, ValueError, KeyError):
        pass
    shares.append(os.path.join(ROOT, "shared"))
    roots = []
    for share in dict.fromkeys(shares):
        base = os.path.join(share, "vm-sessions")
        if not os.path.isdir(base):
            continue
        for host in sorted(os.listdir(base)):
            p = os.path.join(base, host, "projects")
            # The guest names the folder after its hostname; prefer a match.
            if os.path.isdir(p) and not os.path.islink(p):
                roots.append((host != vm, p))
    return [p for _, p in sorted(roots)]


def newest_session(roots):
    best = None
    for root in roots:
        for dirpath, dirnames, filenames in os.walk(root, followlinks=False):
            for f in filenames:
                path = os.path.join(dirpath, f)
                if f.endswith(".jsonl") and not os.path.islink(path):
                    m = os.stat(path).st_mtime
                    if best is None or m > best[0]:
                        best = (m, path)
    return best[1] if best else None


def short(value, n=160):
    s = value if isinstance(value, str) else json.dumps(value, ensure_ascii=False)
    s = " ".join(s.split())
    return s if len(s) <= n else s[: n - 1] + "…"


def describe(event):
    """One or more display lines for a transcript entry, or []."""
    kind = event.get("type")
    msg = event.get("message") or {}
    content = msg.get("content")
    stamp = (event.get("timestamp") or "")[11:19]
    out = []
    if kind not in ("user", "assistant"):
        return out
    if isinstance(content, str):
        content = [{"type": "text", "text": content}]
    for part in content or []:
        t = part.get("type")
        if t == "text" and part.get("text", "").strip():
            who = "you   " if kind == "user" else "claude"
            out.append(f"{stamp} {who}  {short(part['text'], 400)}")
        elif t == "tool_use":
            inp = part.get("input") or {}
            detail = inp.get("command") or inp.get("file_path") or inp.get("pattern") or inp.get("url") or inp
            out.append(f"{stamp} tool    {part.get('name')}: {short(detail)}")
        elif t == "tool_result":
            res = part.get("content")
            if isinstance(res, list):
                res = " ".join(x.get("text", "") for x in res if isinstance(x, dict))
            flag = " (error)" if part.get("is_error") else ""
            out.append(f"{stamp} result{flag}  {short(res or '', 120)}")
    return out


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("vm", nargs="?", default="kiosk")
    ap.add_argument("--lines", type=int, default=25, help="recent lines to show first (default 25)")
    ap.add_argument("--once", action="store_true", help="print recent activity and exit")
    ap.add_argument("--share", help="also look in this shared folder")
    args = ap.parse_args()

    roots = session_roots(args.vm, args.share)
    if not roots:
        sys.exit(f"no session logs for {args.vm} yet (looked for vm-sessions/ in its shared folders)")

    current, fh, waiting = None, None, False
    while True:
        path = newest_session(roots)
        if path and path != current:
            if fh:
                fh.close()
            current, fh = path, open(path, encoding="utf-8", errors="replace")
            rel = os.path.relpath(path, os.path.dirname(roots[0]))
            print(f"\n── {args.vm}: {rel}", flush=True)
            backlog = []
            for line in fh:
                try:
                    backlog += describe(json.loads(line))
                except ValueError:
                    pass
            print("\n".join(backlog[-args.lines:]), flush=True)
            if args.once:
                return
        elif not path and not waiting:
            print("waiting for a session to start…", flush=True)
            waiting = True
        if fh:
            pos = fh.tell()
            line = fh.readline()
            if line.endswith("\n"):
                try:
                    for out in describe(json.loads(line)):
                        print(out, flush=True)
                except ValueError:
                    pass
                continue
            fh.seek(pos)  # partial line: wait for the rest
        time.sleep(1)


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        pass
