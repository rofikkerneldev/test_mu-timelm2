// SPDX-License-Identifier: BSD-2-Clause-Patent
// LG V60 timelm initial Windows bring-up. Addresses checked against mainline DTB.
// UFS hardware ID/resources follow the upstream Kona/kebab ACPI contract.
// Peripheral drivers and low power states require separate device validation.
DefinitionBlock ("", "DSDT", 2, "LGE   ", "TIMELM  ", 0x00000002)
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
                // Trial 10 pin registry: self-referencing GpioIo entries keep the
                // resource-hub connection position equal to the physical TLMM pin
                // number, so a consumer pin index resolves onto the matching pin
                // instead of a sequential connection id (trial 9: IdLowPart 1..4).
                GpioIo (Exclusive, PullNone, 0, 0, IoRestrictionNone, "\\_SB.GPIO", 0, ResourceConsumer, ,) { 0x00 }
                GpioIo (Exclusive, PullNone, 0, 0, IoRestrictionNone, "\\_SB.GPIO", 0, ResourceConsumer, ,) { 0x01 }
                GpioIo (Exclusive, PullNone, 0, 0, IoRestrictionNone, "\\_SB.GPIO", 0, ResourceConsumer, ,) { 0x02 }
                GpioIo (Exclusive, PullNone, 0, 0, IoRestrictionNone, "\\_SB.GPIO", 0, ResourceConsumer, ,) { 0x03 }
                GpioIo (Exclusive, PullNone, 0, 0, IoRestrictionNone, "\\_SB.GPIO", 0, ResourceConsumer, ,) { 0x04 }
                GpioIo (Exclusive, PullNone, 0, 0, IoRestrictionNone, "\\_SB.GPIO", 0, ResourceConsumer, ,) { 0x05 }
                GpioIo (Exclusive, PullNone, 0, 0, IoRestrictionNone, "\\_SB.GPIO", 0, ResourceConsumer, ,) { 0x06 }
                GpioIo (Exclusive, PullNone, 0, 0, IoRestrictionNone, "\\_SB.GPIO", 0, ResourceConsumer, ,) { 0x07 }
                GpioIo (Exclusive, PullNone, 0, 0, IoRestrictionNone, "\\_SB.GPIO", 0, ResourceConsumer, ,) { 0x08 }
                GpioIo (Exclusive, PullNone, 0, 0, IoRestrictionNone, "\\_SB.GPIO", 0, ResourceConsumer, ,) { 0x09 }
                GpioIo (Exclusive, PullNone, 0, 0, IoRestrictionNone, "\\_SB.GPIO", 0, ResourceConsumer, ,) { 0x0A }
                GpioIo (Exclusive, PullNone, 0, 0, IoRestrictionNone, "\\_SB.GPIO", 0, ResourceConsumer, ,) { 0x0B }
                GpioIo (Exclusive, PullNone, 0, 0, IoRestrictionNone, "\\_SB.GPIO", 0, ResourceConsumer, ,) { 0x0C }
                GpioIo (Exclusive, PullNone, 0, 0, IoRestrictionNone, "\\_SB.GPIO", 0, ResourceConsumer, ,) { 0x0D }
                GpioIo (Exclusive, PullNone, 0, 0, IoRestrictionNone, "\\_SB.GPIO", 0, ResourceConsumer, ,) { 0x0E }
                GpioIo (Exclusive, PullNone, 0, 0, IoRestrictionNone, "\\_SB.GPIO", 0, ResourceConsumer, ,) { 0x0F }
                GpioIo (Exclusive, PullNone, 0, 0, IoRestrictionNone, "\\_SB.GPIO", 0, ResourceConsumer, ,) { 0x10 }
                GpioIo (Exclusive, PullNone, 0, 0, IoRestrictionNone, "\\_SB.GPIO", 0, ResourceConsumer, ,) { 0x11 }
                GpioIo (Exclusive, PullNone, 0, 0, IoRestrictionNone, "\\_SB.GPIO", 0, ResourceConsumer, ,) { 0x12 }
                GpioIo (Exclusive, PullNone, 0, 0, IoRestrictionNone, "\\_SB.GPIO", 0, ResourceConsumer, ,) { 0x13 }
                GpioIo (Exclusive, PullNone, 0, 0, IoRestrictionNone, "\\_SB.GPIO", 0, ResourceConsumer, ,) { 0x14 }
                GpioIo (Exclusive, PullNone, 0, 0, IoRestrictionNone, "\\_SB.GPIO", 0, ResourceConsumer, ,) { 0x15 }
                GpioIo (Exclusive, PullNone, 0, 0, IoRestrictionNone, "\\_SB.GPIO", 0, ResourceConsumer, ,) { 0x16 }
                GpioIo (Exclusive, PullNone, 0, 0, IoRestrictionNone, "\\_SB.GPIO", 0, ResourceConsumer, ,) { 0x17 }
                GpioIo (Exclusive, PullNone, 0, 0, IoRestrictionNone, "\\_SB.GPIO", 0, ResourceConsumer, ,) { 0x18 }
                GpioIo (Exclusive, PullNone, 0, 0, IoRestrictionNone, "\\_SB.GPIO", 0, ResourceConsumer, ,) { 0x19 }
                GpioIo (Exclusive, PullNone, 0, 0, IoRestrictionNone, "\\_SB.GPIO", 0, ResourceConsumer, ,) { 0x1A }
                GpioIo (Exclusive, PullNone, 0, 0, IoRestrictionNone, "\\_SB.GPIO", 0, ResourceConsumer, ,) { 0x1B }
                GpioIo (Exclusive, PullNone, 0, 0, IoRestrictionNone, "\\_SB.GPIO", 0, ResourceConsumer, ,) { 0x1C }
                GpioIo (Exclusive, PullNone, 0, 0, IoRestrictionNone, "\\_SB.GPIO", 0, ResourceConsumer, ,) { 0x1D }
                GpioIo (Exclusive, PullNone, 0, 0, IoRestrictionNone, "\\_SB.GPIO", 0, ResourceConsumer, ,) { 0x1E }
                GpioIo (Exclusive, PullNone, 0, 0, IoRestrictionNone, "\\_SB.GPIO", 0, ResourceConsumer, ,) { 0x1F }
                GpioIo (Exclusive, PullNone, 0, 0, IoRestrictionNone, "\\_SB.GPIO", 0, ResourceConsumer, ,) { 0x20 }
                GpioIo (Exclusive, PullNone, 0, 0, IoRestrictionNone, "\\_SB.GPIO", 0, ResourceConsumer, ,) { 0x21 }
                GpioIo (Exclusive, PullNone, 0, 0, IoRestrictionNone, "\\_SB.GPIO", 0, ResourceConsumer, ,) { 0x22 }
                GpioIo (Exclusive, PullNone, 0, 0, IoRestrictionNone, "\\_SB.GPIO", 0, ResourceConsumer, ,) { 0x23 }
                GpioIo (Exclusive, PullNone, 0, 0, IoRestrictionNone, "\\_SB.GPIO", 0, ResourceConsumer, ,) { 0x24 }
                GpioIo (Exclusive, PullNone, 0, 0, IoRestrictionNone, "\\_SB.GPIO", 0, ResourceConsumer, ,) { 0x25 }
                GpioIo (Exclusive, PullNone, 0, 0, IoRestrictionNone, "\\_SB.GPIO", 0, ResourceConsumer, ,) { 0x26 }
                GpioIo (Exclusive, PullNone, 0, 0, IoRestrictionNone, "\\_SB.GPIO", 0, ResourceConsumer, ,) { 0x27 }
                GpioIo (Exclusive, PullNone, 0, 0, IoRestrictionNone, "\\_SB.GPIO", 0, ResourceConsumer, ,) { 0x28 }
                GpioIo (Exclusive, PullNone, 0, 0, IoRestrictionNone, "\\_SB.GPIO", 0, ResourceConsumer, ,) { 0x29 }
                GpioIo (Exclusive, PullNone, 0, 0, IoRestrictionNone, "\\_SB.GPIO", 0, ResourceConsumer, ,) { 0x2A }
                GpioIo (Exclusive, PullNone, 0, 0, IoRestrictionNone, "\\_SB.GPIO", 0, ResourceConsumer, ,) { 0x2B }
                GpioIo (Exclusive, PullNone, 0, 0, IoRestrictionNone, "\\_SB.GPIO", 0, ResourceConsumer, ,) { 0x2C }
                GpioIo (Exclusive, PullNone, 0, 0, IoRestrictionNone, "\\_SB.GPIO", 0, ResourceConsumer, ,) { 0x2D }
                GpioIo (Exclusive, PullNone, 0, 0, IoRestrictionNone, "\\_SB.GPIO", 0, ResourceConsumer, ,) { 0x2E }
                GpioIo (Exclusive, PullNone, 0, 0, IoRestrictionNone, "\\_SB.GPIO", 0, ResourceConsumer, ,) { 0x2F }
                GpioIo (Exclusive, PullNone, 0, 0, IoRestrictionNone, "\\_SB.GPIO", 0, ResourceConsumer, ,) { 0x30 }
                GpioIo (Exclusive, PullNone, 0, 0, IoRestrictionNone, "\\_SB.GPIO", 0, ResourceConsumer, ,) { 0x31 }
                GpioIo (Exclusive, PullNone, 0, 0, IoRestrictionNone, "\\_SB.GPIO", 0, ResourceConsumer, ,) { 0x32 }
                GpioIo (Exclusive, PullNone, 0, 0, IoRestrictionNone, "\\_SB.GPIO", 0, ResourceConsumer, ,) { 0x33 }
                GpioIo (Exclusive, PullNone, 0, 0, IoRestrictionNone, "\\_SB.GPIO", 0, ResourceConsumer, ,) { 0x34 }
                GpioIo (Exclusive, PullNone, 0, 0, IoRestrictionNone, "\\_SB.GPIO", 0, ResourceConsumer, ,) { 0x35 }
                GpioIo (Exclusive, PullNone, 0, 0, IoRestrictionNone, "\\_SB.GPIO", 0, ResourceConsumer, ,) { 0x36 }
                GpioIo (Exclusive, PullNone, 0, 0, IoRestrictionNone, "\\_SB.GPIO", 0, ResourceConsumer, ,) { 0x37 }
                GpioIo (Exclusive, PullNone, 0, 0, IoRestrictionNone, "\\_SB.GPIO", 0, ResourceConsumer, ,) { 0x38 }
                GpioIo (Exclusive, PullNone, 0, 0, IoRestrictionNone, "\\_SB.GPIO", 0, ResourceConsumer, ,) { 0x39 }
                GpioIo (Exclusive, PullNone, 0, 0, IoRestrictionNone, "\\_SB.GPIO", 0, ResourceConsumer, ,) { 0x3A }
                GpioIo (Exclusive, PullNone, 0, 0, IoRestrictionNone, "\\_SB.GPIO", 0, ResourceConsumer, ,) { 0x3B }
                GpioIo (Exclusive, PullNone, 0, 0, IoRestrictionNone, "\\_SB.GPIO", 0, ResourceConsumer, ,) { 0x3C }
                GpioIo (Exclusive, PullNone, 0, 0, IoRestrictionNone, "\\_SB.GPIO", 0, ResourceConsumer, ,) { 0x3D }
                GpioIo (Exclusive, PullNone, 0, 0, IoRestrictionNone, "\\_SB.GPIO", 0, ResourceConsumer, ,) { 0x3E }
                GpioIo (Exclusive, PullNone, 0, 0, IoRestrictionNone, "\\_SB.GPIO", 0, ResourceConsumer, ,) { 0x3F }
                GpioIo (Exclusive, PullNone, 0, 0, IoRestrictionNone, "\\_SB.GPIO", 0, ResourceConsumer, ,) { 0x40 }
                GpioIo (Exclusive, PullNone, 0, 0, IoRestrictionNone, "\\_SB.GPIO", 0, ResourceConsumer, ,) { 0x41 }
                GpioIo (Exclusive, PullNone, 0, 0, IoRestrictionNone, "\\_SB.GPIO", 0, ResourceConsumer, ,) { 0x42 }
                GpioIo (Exclusive, PullNone, 0, 0, IoRestrictionNone, "\\_SB.GPIO", 0, ResourceConsumer, ,) { 0x43 }
                GpioIo (Exclusive, PullNone, 0, 0, IoRestrictionNone, "\\_SB.GPIO", 0, ResourceConsumer, ,) { 0x44 }
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
