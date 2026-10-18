#!/usr/bin/env python3
"""Prepare versioned timelm assets without changing submodule commits."""
from pathlib import Path
import hashlib
import json
import shutil
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
overlay = root / "Resources/DeviceOverlays/timelm"
manifest = json.loads((overlay / "SHA256.json").read_text())
for relative, expected in manifest.items():
    source = overlay / relative
    if hashlib.sha256(source.read_bytes()).hexdigest() != expected:
        raise SystemExit("Overlay checksum mismatch: " + relative)

for path in ("Binaries", "Silicium-ACPI"):
    if not (root / path / ".git").exists():
        raise SystemExit("Initialize submodules first: git submodule update --init --recursive")

for name, destination in (
    ("Binaries", root / "Binaries/timelm"),
    ("ACPI", root / "Silicium-ACPI/Platforms/LG/timelm"),
):
    for source in sorted((overlay / name).rglob("*")):
        if not source.is_file():
            continue
        target = destination / source.relative_to(overlay / name)
        if target.exists() and target.read_bytes() != source.read_bytes():
            if target.suffix.lower() != ".md":
                raise SystemExit("Local asset differs; preserve it before preparing: " + str(target))
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, target)

iasl = shutil.which("iasl")
if not iasl:
    raise SystemExit("iasl is required to compile the timelm DSDT")
destination = root / "Silicium-ACPI/Platforms/LG/timelm"
with tempfile.TemporaryDirectory(prefix="timelm-acpi-") as temp:
    output = Path(temp) / "DSDT"
    subprocess.run([iasl, "-ve", "-p", str(output), str(destination / "DSDT.asl")], check=True)
    shutil.copyfile(output.with_suffix(".aml"), destination / "DSDT.aml")
print("Prepared and verified timelm firmware assets; compiled DSDT.")
