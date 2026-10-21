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

repo = Path(__file__).resolve().parents[2]
out = Path(sys.argv[1]).resolve()
out.mkdir(parents=True, exist_ok=True)
gpio = '--gpio' in sys.argv[2:]
name = 'TouchGpio' if gpio else 'TouchEnumeration'
table_id = 'TIMLTGPI' if gpio else 'TIMLTENU'
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
(out / 'touch-enumeration-acpi.json').write_text(json.dumps(dict(
    ssdt_sha256=hashlib.sha256(ssdt).hexdigest(), ssdt_size=len(ssdt),
    dsdt_sha256=hashlib.sha256(dsdt).hexdigest(), runtime_patches=ranges,
    iort_installed=False, requires_no_matching_drivers=not gpio), indent=2) + '\n')
