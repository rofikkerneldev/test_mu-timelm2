#!/usr/bin/env python3
"""Exercise the production generator against pinned and corrupted snapshots."""
from pathlib import Path
import subprocess, sys, tempfile, json
repo=Path(__file__).resolve().parents[3]
with tempfile.TemporaryDirectory(prefix='timelm-contract-') as temp:
    out=Path(temp)
    dsdt=repo/'Resources/Tests/TouchGpio/DSDT-952.aml'
    ssdt=repo/'Resources/Tests/TouchGpio/SSDT-451.aml'
    command=[sys.executable,str(repo/'Resources/Scripts/generate_touch_enumeration.py'),str(out/'good'),'--gpio','--snapshot']
    good=subprocess.run(command+[str(dsdt),str(ssdt)],capture_output=True,text=True)
    assert good.returncode==0,good.stderr
    bad=bytearray(dsdt.read_bytes());bad[36]^=1;bad[9]=0;bad[9]=(-sum(bad))&255
    (out/'bad.aml').write_bytes(bad)
    invalid=subprocess.run(command+[str(out/'bad.aml'),str(ssdt)],capture_output=True,text=True)
    assert invalid.returncode!=0
    record=json.loads((out/'good/touch-enumeration-acpi.json').read_text())
    assert record['dsdt_sha256']=='b759e921e4224158834b5867a456ab988a49d5f900ee90d2b77ed984d9a6c5fe'
print('PASS: pinned 952/451 snapshot accepted; altered unmasked AML with valid checksum refused')
