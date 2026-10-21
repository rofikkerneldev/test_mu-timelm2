#!/usr/bin/env python3
# SPDX-License-Identifier: BSD-2-Clause-Patent
"""Generate an experimental timelm IORT candidate; never install firmware.

IORT rev 0 layout from MdePkg/IndustryStandard/IoRemappingTable.h.
This table advertises the shared apps-SMMU to the OS even if TI2C._STA=0.
The manifest deliberately does not certify secure-firmware ownership.
"""
import argparse
import hashlib
import json
from pathlib import Path
import struct

ROOT = Path(__file__).resolve().parents[2]
PROFILE = ROOT / 'Platforms/LG/timelmPkg/Experimental/TimelmTouchDma.json'


def build(profile):
    p = profile
    required = {'schema': 1, 'namespace': '\\_SB_.TI2C', 'input_id': 0,
                'stream_id': 0x56, 'smmu_base': 0x15000000,
                'smmu_span': 0x100000, 'smmu_model': 1,
                'id0': 0x4c017e57, 'id1': 0x6000004a,
                'interrupt_flags_iort': 0, 'qcom_skip_init': True}
    for key, value in required.items():
        if p.get(key) != value:
            raise ValueError(f'Not the captured V60 contract: {key}')
    # Linux arm-smmu reads ID1.NUMCB and ignores surplus DT IRQ entries.
    # 0x6000004a -> 74 context banks; the captured DT lists 96 interrupts.
    count = p['id1'] & 0xff
    all_irqs = p['context_gsivs_dt']
    if len(all_irqs) != 96 or count != 74 or p['global_gsivs'] != [96, 97]:
        raise ValueError('Unexpected SMMU interrupt evidence')
    if any(type(i) is not int or i < 32 or i > 1019 for i in all_irqs):
        raise ValueError('Not a GIC SPI interrupt')
    if len(set(all_irqs + p['global_gsivs'])) != 98:
        raise ValueError('Duplicate SMMU interrupt')
    irqs = all_irqs[:count]
    node_offset = 48
    # SMMUv2 generic model, noncoherent table walk, no device-local SMMU _CRS.
    smmu_length = 76 + count * 8
    smmu = struct.pack('<BH B III QQ IIIIIII IIII',
        3, smmu_length, 0, 0, 0, 0,
        p['smmu_base'], p['smmu_span'], p['smmu_model'], 0,
        60, count, 76, 0, 0, 96, 0, 97, 0)
    smmu += b''.join(struct.pack('<II', irq, 0) for irq in irqs)
    # One input ID only, NOT a single-mapping wildcard. NumIds encodes N-1.
    name = p['namespace'].encode('ascii') + b'\0'
    name += b'\0' * (-(29 + len(name)) % 4)
    map_offset = 29 + len(name)
    named = struct.pack('<BH B III II B H BB',
        1, map_offset + 20, 0, 0, 1, map_offset,
        0, 0, 0, 0, 0, 32) + name
    named += struct.pack('<IIIII', p['input_id'], 0, p['stream_id'], node_offset, 0)
    length = 48 + len(smmu) + len(named)
    header = struct.pack('<4s I BB 6s 8s I 4s I III',
        b'IORT', length, 0, 0, b'LGE   ', b'TIMLDMA ', 1, b'TMLM', 1, 2, 48, 0)
    data = bytearray(header + smmu + named)
    data[9] = (-sum(data)) & 255
    return bytes(data)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, default=ROOT / 'Build/TouchIommu')
    args = parser.parse_args()
    output = args.output.resolve()
    if not output.is_relative_to((ROOT / 'Build').resolve()):
        parser.error('Output must remain under this checkout Build/; this is not an installer')
    p = json.loads(PROFILE.read_text())
    data = build(p)
    output.mkdir(parents=True, exist_ok=True)
    (output / 'TimelmTouchIort.candidate.aml').write_bytes(data)
    manifest = {
        'board': p['board'], 'status': 'EXPERIMENTAL_NOT_HARDWARE_VALIDATED',
        'deployable': False, 'smmu_handoff_validated': False,
        'reason': 'Shared qcom,skip-init SMMU ownership/handoff is not established for Windows.',
        'namespace': p['namespace'], 'input_id': 0, 'stream_id': 0x56,
        'context_banks_id1': p['id1'] & 255,
        'context_interrupts_dt': len(p['context_gsivs_dt']),
        'context_interrupts_used': p['context_gsivs_dt'][:p['id1'] & 255],
        'profile_sha256': hashlib.sha256(PROFILE.read_bytes()).hexdigest(),
        'iort_sha256': hashlib.sha256(data).hexdigest(),
        'default_firmware_modified': False,
        'warning': 'IORT initialization is independent of the SSDT TWEN/_STA gate.'}
    (output / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
    print(json.dumps({k: manifest[k] for k in ('status', 'deployable', 'iort_sha256')}))


if __name__ == '__main__':
    main()
