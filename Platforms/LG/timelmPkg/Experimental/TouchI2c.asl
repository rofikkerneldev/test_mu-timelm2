// SPDX-License-Identifier: BSD-2-Clause-Patent
// Standalone review/compile candidate. NOT included in the booting DSDT/FDF.
DefinitionBlock ("", "SSDT", 2, "LGE   ", "TIMLTOUC", 1)
{
    External (\_SB.GPIO, DeviceObj)
    Scope (\_SB)
    {
        // Do not change until firmware clock/pinmux/power ownership is proven.
        Name (TIEN, Zero)
        Device (TI2C)
        {
            Name (_HID, "TIML0001") // private prototype ID, not a Qualcomm match
            Name (_UID, 14)
            Name (_CCA, Zero)
            Method (_STA, 0, NotSerialized) { Return (TIEN * 0x0F) }
            Name (_CRS, ResourceTemplate ()
            {
                Memory32Fixed (ReadWrite, 0x00A94000, 0x00004000)
                // Reserved for a later interrupt-driven host. Prototype polls
                // GENI status and keeps SE_IRQ_EN gated, without a WDF ISR.
                Interrupt (ResourceConsumer, Level, ActiveHigh, Exclusive) {390}
            })
        }
        Device (TSCV)
        {
            Name (_HID, "LGSW4290")
            Name (_UID, Zero)
            Name (_DEP, Package () {\_SB.TI2C, \_SB.GPIO})
            Method (_STA, 0, NotSerialized) { Return (TIEN * 0x0F) }
            Name (_CRS, ResourceTemplate ()
            {
                I2cSerialBusV2 (0x0028, ControllerInitiated, 100000,
                    AddressingMode7Bit, "\\_SB.TI2C", 0,
                    ResourceConsumer, , Exclusive)
                GpioInt (Edge, ActiveLow, Exclusive, PullUp, 0,
                    "\\_SB.GPIO", 0, ResourceConsumer, ,) {39}
            })
            // No fake _PS0/_PS3: verified reset/supply lifecycle is required.
        }
    }
}
