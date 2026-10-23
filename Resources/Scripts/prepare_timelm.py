#!/usr/bin/env python3
"""Prepare versioned timelm assets without changing submodule commits."""
from pathlib import Path
import hashlib
import json
import shutil

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

aml = root / "Silicium-ACPI/Platforms/LG/timelm/DSDT.aml"
digest = hashlib.sha256(aml.read_bytes()).hexdigest()
if digest != manifest["ACPI/DSDT.aml"]:
    raise SystemExit("Copied DSDT.aml lost its manifest fingerprint: " + str(aml))
# The platform tree keeps the CI-compiled artifact byte for byte. The trial
# launcher bakes the very same table as its fingerprint (TrialKnownDsdt), and
# AcpiTables.inf embeds the AML verbatim, so a local iasl recompile would
# slightly move unmasked bytes and break the namespace gate after the flash.
print("Prepared and verified timelm firmware assets.")
print("Platform ACPI/DSDT.aml sha256: " + digest)
