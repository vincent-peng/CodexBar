import hashlib
import json
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys

repo = Path.cwd()
root = Path(__file__).resolve().parent
phase = sys.argv[1]
assert phase in {"baseline", "fixed"}
bundle = root / (phase.title() + ".app")
assert not bundle.exists()
shutil.copytree(repo / "CodexBar.app", bundle, symlinks=True)
plist_path = bundle / "Contents/Info.plist"
with plist_path.open("rb") as stream:
    plist = plistlib.load(stream)
plist["CFBundleIdentifier"] = "com.steipete.codexbar.proof." + phase
plist["CFBundleName"] = "CodexBar 4787 " + phase.title() + " Proof"
plist["CFBundleDisplayName"] = plist["CFBundleName"]
for key in ["CFBundleURLTypes", "CFBundleDocumentTypes", "NSServices"]:
    plist.pop(key, None)
with plist_path.open("wb") as stream:
    plistlib.dump(plist, stream)
subprocess.run(["codesign", "--force", "--sign", "-", str(bundle)], check=True)
subprocess.run(["codesign", "--verify", "--deep", "--strict", str(bundle)], check=True)
files = [
    "Sources/CodexBar/Menu/PluginPercentRefreshProof.swift",
    "Sources/CodexBar/StatusItem/StatusItemController+IconObservation.swift",
    "Sources/CodexBar/StatusItem/StatusItemController.swift",
    "Sources/CodexBar/CodexbarApp.swift",
]
metadata = {
    "phase": phase,
    "productionHead": subprocess.check_output(["git", "rev-parse", "HEAD"], text=True).strip(),
    "baselineProduction": "5f93dc3068b3bee3f8753f3772614cc2949c335d",
    "bundleIdentifier": plist["CFBundleIdentifier"],
    "executableSHA256": hashlib.sha256((bundle / "Contents/MacOS/CodexBar").read_bytes()).hexdigest(),
    "sourceSHA256": {name: hashlib.sha256((repo / name).read_bytes()).hexdigest() for name in files},
    "note": "Temporary synthetic startup and append-only updateIcons receipts; no production render override.",
}
(root / (phase + "-build-metadata.json")).write_text(json.dumps(metadata, indent=2) + "\n")
print(json.dumps(metadata, indent=2))
