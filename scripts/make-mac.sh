#!/bin/sh
# Build vms/mac from scratch: download the newest macOS restore image this host
# supports (about 25 GB, resumable) and install it. Around 20 minutes plus the
# download. First boot lands in Setup Assistant.
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"

[ -x bin/vmctl ] || ./build.sh
mkdir -p images/macos logs shared

bin/vmctl mac-latest > images/macos/latest.txt
cat images/macos/latest.txt
URL=$(awk '$1 == "url" {print $2}' images/macos/latest.txt)
IPSW=images/macos/$(basename "$URL")

# -C - resumes a partial download; the server answers 416 once it is complete.
curl -fL --retry 5 -C - -o "$IPSW" "$URL" || [ $? -eq 22 ]

bin/vmctl mac-install vms/mac --ipsw "$IPSW" --disk 64 --cpus 4 --mem 4
VM=$ROOT/vms/mac
# Share the kit's shared/ folder with the VM (VM Manager can change this later).
python3 -I - "$VM/config.json" "$ROOT/shared" <<'PY'
import json, sys
p, shared = sys.argv[1], sys.argv[2]
cfg = json.load(open(p))
cfg.setdefault("shares", [{"path": shared, "readOnly": False}])
json.dump(cfg, open(p, "w"), indent=2, sort_keys=True)
PY
echo "done — start it with ./mac"
