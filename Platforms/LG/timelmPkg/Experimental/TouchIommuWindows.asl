// SPDX-License-Identifier: BSD-2-Clause-Patent
// Windows-owned translated GPI DMA. Pair ONLY with TimelmTouchIort candidate.
// Disabled SSDT does NOT make an installed IORT passive; see TOUCH-IOMMU.md.
DefinitionBlock ("", "SSDT", 2, "LGE   ", "TIMLTDMA", 1)
{
    External (\_SB.GPIO, DeviceObj)
    Scope (\_SB)
    {
        Name (TWEN, Zero)
        Device (TI2C)
        {
            Name (_HID, "TIML0001")
            Name (_UID, 14)
            Name (_CCA, Zero)
            Name (_DEP, Package () {\_SB.GPIO})
            Method (_STA, 0, NotSerialized) { Return (TWEN * 0x0F) }
            // Revision 3: four MMIO resources, no driver-owned SMMU page.
            Method (TBCF, 0, NotSerialized) { Return (0x54420301) }
            Name (_CRS, ResourceTemplate ()
            {
                Memory32Fixed (ReadWrite, 0x00A94000, 0x00004000)
                Memory32Fixed (ReadWrite, 0x00118000, 0x00001000)
                Memory32Fixed (ReadWrite, 0x00152000, 0x00001000)
                Memory32Fixed (ReadWrite, 0x00A00000, 0x00070000)
                // GPI1 / GPII0; raw GSIV311, translated vector assigned by Windows.
                Interrupt (ResourceConsumer, Level, ActiveHigh, Exclusive) {311}
                // Resource connection order: reset, VCL, VDD, reserved bus pins.
                GpioIo (Exclusive, PullNone, 0, 0, IoRestrictionOutputOnly,
                    "\\_SB.GPIO", 0, ResourceConsumer, ,) {38}
                GpioIo (Exclusive, PullNone, 0, 0, IoRestrictionOutputOnly,
                    "\\_SB.GPIO", 0, ResourceConsumer, ,) {67}
                GpioIo (Exclusive, PullNone, 0, 0, IoRestrictionOutputOnly,
                    "\\_SB.GPIO", 0, ResourceConsumer, ,) {68}
                GpioIo (Exclusive, PullNone, 0, 200, IoRestrictionInputOnly,
                    "\\_SB.GPIO", 0, ResourceConsumer, ,) {36, 37}
            })
        }
        Device (TSCV)
        {
            Name (_HID, "LGSW4290")
            Name (_UID, Zero)
            Name (_DEP, Package () {\_SB.TI2C, \_SB.GPIO})
            Method (_STA, 0, NotSerialized) { Return (TWEN * 0x0F) }
            Name (_CRS, ResourceTemplate ()
            {
                I2cSerialBusV2 (0x0028, ControllerInitiated, 100000,
                    AddressingMode7Bit, "\\_SB.TI2C", 0,
                    ResourceConsumer, , Exclusive)
                GpioInt (Edge, ActiveLow, Exclusive, PullUp, 0,
                    "\\_SB.GPIO", 0, ResourceConsumer, ,) {39}
            })
        }
    }
}
