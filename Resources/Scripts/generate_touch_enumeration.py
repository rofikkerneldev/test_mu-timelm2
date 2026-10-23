#!/usr/bin/env python3
"""Compile the actual V60 resources for a driver-free, one-boot enumeration trial.

No IORT is included. Deployment must verify that no matching host/client INF is
installed; this table alone does not validate DMA or make touch functional.
"""
import hashlib
import json
from pathlib import Path
import struct
import subprocess
import sys

# Snapshot contract mode: bake the enumerated-ID tables captured on the phone.
#
# Live platform DSDT read back by Windows on 2026-10-23 (trial9 and trial10
# snapshots are byte-identical, 952 bytes). The reviewed runtime mask below
# covers only the volatile serial/config fields plus the revision byte; a
# one-time diff against the historical 952-byte AML showed 83 differing
# bytes, all inside masked ranges. See docs/touch-gpio-handoff-20261023/.
# Do NOT loosen the mask; a different FPGA/firmware table must pass through
# a new reviewed snapshot, never by widening the mask schema.
LIVE_DSDT_SHA256 = 'b759e921e4224158834b5867a456ab988a49d5f900ee90d2b77ed984d9a6c5fe'
# SSDT TIMLTGPI (451 bytes) captured while trial 9 reached Code 10 on the
# Windows host driver: the bytes that enumerate cleanly on this platform.
TRIAL9_SSDT_SHA256 = '79aab95e716573b511d12538d6d44d6c07361ea9278382a5eaf4b8260b7a3501'

repo = Path(__file__).resolve().parents[2]
argv = sys.argv[1:]
out = Path(argv[0]).resolve()
out.mkdir(parents=True, exist_ok=True)
rest = argv[1:]
snapshot_args = None
if '--snapshot' in rest:
    index = rest.index('--snapshot')
    snapshot_args = (Path(rest[index + 1]).resolve(), Path(rest[index + 2]).resolve())
    del rest[index:index + 3]
gpio = '--gpio' in rest
name = 'TouchGpio' if gpio else 'TouchEnumeration'
table_id = 'TIMLTGPI' if gpio else 'TIMLTENU'
dsdt_mode = 'platform'
if snapshot_args is None:
    source_file = 'TouchGpioWindows.asl' if gpio else 'TouchIommuWindows.asl'
    source = (repo / ('Platforms/LG/timelmPkg/Experimental/' + source_file)).read_text()
    assert source.count('Name (TWEN, Zero)') == 1
    source = source.replace('Name (TWEN, Zero)', 'Name (TWEN, One)')
    source = source.replace('"TIMLTDMA"', '"TIMLTENU"')
    asl = out / (name + '.asl')
    asl.write_text(source)
    subprocess.run(['iasl', '-ve', '-p', str(out / name), str(asl)], check=True)
    ssdt = (out / (name + '.aml')).read_bytes()
    dsdt = (repo / 'Resources/DeviceOverlays/timelm/ACPI/DSDT.aml').read_bytes()
    manifest = json.loads((repo / 'Resources/DeviceOverlays/timelm/SHA256.json').read_text())
    assert hashlib.sha256(dsdt).hexdigest() == manifest['ACPI/DSDT.aml']
else:
    dsdt_mode = 'live-snapshot'
    dsdt = snapshot_args[0].read_bytes()
    ssdt = snapshot_args[1].read_bytes()
    assert hashlib.sha256(dsdt).hexdigest() == LIVE_DSDT_SHA256, hashlib.sha256(dsdt).hexdigest()
    assert hashlib.sha256(ssdt).hexdigest() == TRIAL9_SSDT_SHA256, hashlib.sha256(ssdt).hexdigest()
    # The snapshot SSDT already enumerates as-is; copy it for the meta step.
    (out / (name + '.aml')).write_bytes(ssdt)
for data, sig in [(ssdt, b'SSDT'), (dsdt, b'DSDT')]:
    assert data[:4] == sig and 36 <= len(data) <= 65536
    assert struct.unpack_from('<I', data, 4)[0] == len(data) and sum(data) % 256 == 0
assert dsdt[10:24] == b'LGE   TIMELM  ' and ssdt[16:24] == table_id.encode('ascii')
# Same narrow data-only mask as the existing USB namespace gate. Keep AML
# opcodes, resource descriptors, names and lengths immutable.
fields = {'SOID':(0x0c,4),'STOR':(0x0c,4),'SIDV':(0x0c,4),'SVMJ':(0x0b,2),
          'SVMI':(0x0b,2),'SDFE':(0x0b,2),'SIDM':(0x0e,2),'PUS3':(0x0c,4),
          'SIDT':(0x0c,4),'SJTG':(0x0c,4),'EMUL':(0x0c,4),'SOSN':(0x0e,8),
          'PLST':(0x0c,4),'SOSI':(0x0e,8),'PRP0':(0x0c,4),'PRP1':(0x0c,4),
          'PRP2':(0x0c,4),'SIDS':(0x0d,16)}
mask = bytearray(len(dsdt)); mask[9] = 1
ranges = []
for name, (prefix, size) in fields.items():
    needle = b'\x08' + name.encode() + bytes([prefix])
    assert dsdt.count(needle) == 1, name
    start = dsdt.index(needle) + len(needle)
    assert start + size <= len(dsdt)
    mask[start:start+size] = b'\x01' * size
    ranges.append(dict(name=name, offset=start, size=size))

def array(name, data):
    rows = ['  ' + ','.join(f'0x{x:02x}' for x in data[i:i+16]) + ',' for i in range(0,len(data),16)]
    return 'STATIC CONST UINT8 ' + name + '[]={\n' + '\n'.join(rows) + '\n};\n'

(out / 'TouchEnumerationAcpi.h').write_text('// Generated; do not edit.\n' +
    array('mTouchSsdt', ssdt) + array('mTimelmDsdt', dsdt) + array('mTimelmDsdtMask', mask))
contract = dict(
    ssdt_sha256=hashlib.sha256(ssdt).hexdigest(), ssdt_size=len(ssdt),
    dsdt_sha256=hashlib.sha256(dsdt).hexdigest(), runtime_patches=ranges,
    iort_installed=False, requires_no_matching_drivers=not gpio)
if snapshot_args is not None:
    contract['dsdt_source'] = 'live-snapshot 2026-10-23 (trial9/trial10 identical, 952 B)'
    contract['ssdt_source'] = 'trial9 TIMLTGPI enumerated snapshot'
(out / 'touch-enumeration-acpi.json').write_text(json.dumps(contract, indent=2) + '\n')
