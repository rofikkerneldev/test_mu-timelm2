// SPDX-License-Identifier: BSD-2-Clause-Patent
// LG V60 timelm initial Windows bring-up. Addresses checked against mainline DTB.
// UFS hardware ID/resources follow the upstream Kona/kebab ACPI contract.
// Peripheral drivers and low power states require separate device validation.
DefinitionBlock ("", "DSDT", 2, "LGE   ", "TIMELM  ", 0x00000001)
{
    Scope (\_SB)
    {
        // Explicit integer widths are required by Kona AcpiTableUpdateLib.
        Name (PSUB, "MTP08250")
        Name (SOID, 0xFFFFFFFF)
        Name (STOR, 0xFFFFFFFF)
        Name (SIDS, "899800000000000")
        Name (SIDV, 0xFFFFFFFF)
        Name (SVMJ, 0xFFFF)
        Name (SVMI, 0xFFFF)
        Name (SDFE, 0xFFFF)
        Name (SIDM, 0x0000000FFFFFFFFF)
        Name (PUS3, 0xFFFFFFFF)
        Name (SIDT, 0xFFFFFFFF)
        Name (SJTG, 0xFFFFFFFF)
        Name (EMUL, 0xFFFFFFFF)
        Name (SOSN, 0xAAAAAAAABBBBBBBB)
        Name (PLST, 0xFFFFFFFF)
        Name (SOSI, 0xDEADBEEFFFFFFFFF)
        Name (PRP0, 0xFFFFFFFF)
        Name (PRP1, 0xFFFFFFFF)
        Name (PRP2, 0xFFFFFFFF)

        Device (UFS0)
        {
            Name (_HID, "QCOM24A5")
            Name (_UID, Zero)
            Name (_CCA, Zero)
            Alias (\_SB.EMUL, EMUL)
            Method (_STA, 0, NotSerialized) { Return (0x0F) }
            Name (_CRS, ResourceTemplate ()
            {
                Memory32Fixed (ReadWrite, 0x01D84000, 0x0001C000)
                // DT SPI 265 + the GIC SPI base 32 = GSIV 297.
                Interrupt (ResourceConsumer, Level, ActiveHigh, Exclusive) { 0x129 }
            })
            Device (DEV0)
            {
                Name (_ADR, 0x08)
                Name (_RMV, Zero)
            }
        }
        // N1kroks WOA-Kona/Drivers 3dcdec0 contract.
        // One mapped TLMM span is required by the driver's tile-offset model.
        Device (GPIO)
        {
            Name (_HID, "KONA1001")
            Name (_UID, Zero)
            Name (_CCA, Zero)
            Name (_CRS, ResourceTemplate ()
            {
                Memory32Fixed (ReadWrite, 0x0F100000, 0x00B00000)
                // Three logical 64-pin banks share the DT SPI 208 / GSIV 240.
                Interrupt (ResourceConsumer, Level, ActiveHigh, Shared) { 240 }
                Interrupt (ResourceConsumer, Level, ActiveHigh, Shared) { 240 }
                Interrupt (ResourceConsumer, Level, ActiveHigh, Shared) { 240 }
            })
        }
        Device (SPMI)
        {
            Name (_HID, "KONA1002")
            Name (_UID, Zero)
            Name (_CCA, Zero)
            Name (_CRS, ResourceTemplate ()
            {
                // Ordered CORE, CHNLS, OBSRVR, INTR, CNFG as required by SPMI.sys.
                Memory32Fixed (ReadWrite, 0x0C440000, 0x00001100)
                Memory32Fixed (ReadWrite, 0x0C600000, 0x02000000)
                Memory32Fixed (ReadWrite, 0x0E600000, 0x00100000)
                Memory32Fixed (ReadWrite, 0x0E700000, 0x000A0000)
                Memory32Fixed (ReadWrite, 0x0C40A000, 0x00026000)
            })
        }
        Device (PMIC)
        {
            Name (_HID, "KONA1003")
            Name (_UID, Zero)
            Name (_DEP, Package () { \_SB.SPMI })
            // Populated SID pairs from timelm Recovery's live SPMI device tree.
            // Subtypes are read by PMIC.sys; no PMK8002 at SID 6/7 is assumed.
            Method (PCFG, 0, NotSerialized)
            {
                Return (Package ()
                {
                    5,
                    Package () { 0x00, 0x01 }, // PM8150
                    Package () { 0x02, 0x03 }, // PM8150B
                    Package () { 0x04, 0x05 }, // PM8150L
                    Package () { 0x08, 0x09 }, // PMXPRAIRIE / modem PMIC
                    Package () { 0x0A, 0x0B }  // PM8009
                })
            }
        }
        Device (CPU0)
        {
            Name (_HID, "ACPI0007")
            Name (_UID, 0)
            Method (_STA, 0, NotSerialized) { Return (0x0F) }
        }
        Device (CPU1)
        {
            Name (_HID, "ACPI0007")
            Name (_UID, 1)
            Method (_STA, 0, NotSerialized) { Return (0x0F) }
        }
        Device (CPU2)
        {
            Name (_HID, "ACPI0007")
            Name (_UID, 2)
            Method (_STA, 0, NotSerialized) { Return (0x0F) }
        }
        Device (CPU3)
        {
            Name (_HID, "ACPI0007")
            Name (_UID, 3)
            Method (_STA, 0, NotSerialized) { Return (0x0F) }
        }
        Device (CPU4)
        {
            Name (_HID, "ACPI0007")
            Name (_UID, 4)
            Method (_STA, 0, NotSerialized) { Return (0x0F) }
        }
        Device (CPU5)
        {
            Name (_HID, "ACPI0007")
            Name (_UID, 5)
            Method (_STA, 0, NotSerialized) { Return (0x0F) }
        }
        Device (CPU6)
        {
            Name (_HID, "ACPI0007")
            Name (_UID, 6)
            Method (_STA, 0, NotSerialized) { Return (0x0F) }
        }
        Device (CPU7)
        {
            Name (_HID, "ACPI0007")
            Name (_UID, 7)
            Method (_STA, 0, NotSerialized) { Return (0x0F) }
        }
    }
}
