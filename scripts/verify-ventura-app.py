#!/usr/bin/env python3
"""Verify the deployment floor and Intel slice of every bundled Mach-O image."""
import plistlib
import re
import subprocess
import sys
from pathlib import Path

app = Path(sys.argv[1]).resolve()
with (app / "Contents/Info.plist").open("rb") as handle:
    info = plistlib.load(handle)
assert info["CFBundleIdentifier"] == "com.metepolat.Remarc"
assert info["LSMinimumSystemVersion"] in ("13.0", "13.0.0"), info.get("LSMinimumSystemVersion")

checked = 0
for path in app.rglob("*"):
    if not path.is_file() or path.is_symlink():
        continue
    description = subprocess.check_output(["file", "-b", str(path)], text=True)
    if "Mach-O" not in description:
        continue
    archs = subprocess.check_output(["lipo", "-archs", str(path)], text=True).split()
    assert "x86_64" in archs, f"Missing Intel slice: {path}"
    commands = subprocess.check_output(["otool", "-arch", "x86_64", "-l", str(path)], text=True)
    versions = re.findall(r"\bminos\s+([\d.]+)", commands)
    versions += re.findall(r"LC_VERSION_MIN_MACOSX\s+cmdsize\s+\d+\s+version\s+([\d.]+)", commands)
    assert versions, f"Missing deployment version: {path}"
    for version in versions:
        parts = tuple(int(part) for part in version.split("."))
        assert (parts + (0, 0))[:3] <= (13, 0, 0), f"{path} requires macOS {version}"
    checked += 1
assert checked, "No Mach-O images found"
print(f"Verified {checked} Mach-O images: x86_64, macOS 13.0 or earlier; app minimum 13.0")
