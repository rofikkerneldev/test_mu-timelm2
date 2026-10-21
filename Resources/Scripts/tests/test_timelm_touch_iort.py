# SPDX-License-Identifier: BSD-2-Clause-Patent
"""Independently parse generated IORT offsets, IRQs, mapping and checksum."""
import copy
import importlib.util
import json
from pathlib import Path
import struct
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / 'build_timelm_touch_iort.py'
spec = importlib.util.spec_from_file_location('touch_iort', SCRIPT)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class IortTest(unittest.TestCase):
    def setUp(self):
        self.profile = json.loads(module.PROFILE.read_text())

    def test_offsets_and_mapping(self):
        table = module.build(self.profile)
        self.assertEqual(table[:4], b'IORT')
        self.assertEqual(sum(table) % 256, 0)
        self.assertEqual(struct.unpack_from('<I', table, 4)[0], len(table))
        count, cursor, reserved = struct.unpack_from('<III', table, 36)
        self.assertEqual((count, cursor, reserved), (2, 48, 0))
        smmu = cursor
        kind, size, revision, identifier, maps, reference = struct.unpack_from('<BHBIII', table, smmu)
        self.assertEqual((kind, size, revision, identifier, maps, reference), (3, 668, 0, 0, 0, 0))
        base, span, model, flags = struct.unpack_from('<QQII', table, smmu+16)
        self.assertEqual((base, span, model, flags), (0x15000000, 0x100000, 1, 0))
        global_ref, irq_count, irq_ref, pmu_count, pmu_ref = struct.unpack_from('<IIIII', table, smmu+40)
        self.assertEqual((global_ref, irq_count, irq_ref, pmu_count, pmu_ref), (60, 74, 76, 0, 0))
        self.assertEqual(struct.unpack_from('<IIII', table, smmu+global_ref), (96, 0, 97, 0))
        interrupts = [struct.unpack_from('<II', table, smmu+irq_ref+8*i) for i in range(irq_count)]
        self.assertEqual(interrupts, [(i, 0) for i in self.profile['context_gsivs_dt'][:74]])
        named = smmu + size
        kind, size, revision, identifier, maps, reference = struct.unpack_from('<BHBIII', table, named)
        self.assertEqual((kind, revision, identifier, maps), (1, 0, 0, 1))
        self.assertEqual(struct.unpack_from('<IIBHBB', table, named+16), (0, 0, 0, 0, 0, 32))
        self.assertEqual(table[named+29:named+reference].rstrip(b'\0'), b'\\_SB_.TI2C')
        self.assertEqual(struct.unpack_from('<IIIII', table, named+reference), (0, 0, 0x56, smmu, 0))
        self.assertEqual(named + size, len(table))

    def test_incompatible_profile_rejected(self):
        for key, value in [('stream_id', 0x46), ('id1', 0x60000060),
                           ('smmu_base', 0x15100000), ('namespace', '\\_SB_.I2C1'),
                           ('interrupt_flags_iort', 1), ('qcom_skip_init', False)]:
            p = copy.deepcopy(self.profile)
            p[key] = value
            with self.subTest(key=key), self.assertRaises(ValueError):
                module.build(p)
        p = copy.deepcopy(self.profile)
        p['context_gsivs_dt'][0] = p['context_gsivs_dt'][1]
        with self.assertRaises(ValueError):
            module.build(p)

    def test_acpi_gate_and_resource_contract(self):
        asl = (module.PROFILE.parent / 'TouchIommuWindows.asl').read_text()
        self.assertIn('Name (TWEN, Zero)', asl)
        self.assertIn('0x54420301', asl)
        self.assertEqual(asl.count('Memory32Fixed ('), 4)
        self.assertNotIn('0x15000000', asl)
        self.assertIn('{311}', asl)
        self.assertIn('I2cSerialBusV2 (0x0028', asl)
        self.assertIn('{39}', asl)
        normal = (module.ROOT / 'Resources/DeviceOverlays/timelm/ACPI/AcpiTables.inf').read_text()
        self.assertNotIn('Iort', normal)
        self.assertNotIn('IORT', normal)
        self.assertNotIn('TouchIommu', normal)


if __name__ == '__main__':
    unittest.main()
