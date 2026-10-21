// SPDX-License-Identifier: BSD-2-Clause-Patent
// GPIO open-drain I2C: no GENI/GCC/GPI/SMMU memory or DMA resources.
DefinitionBlock ("", "SSDT", 2, "LGE   ", "TIMLTGPI", 1)
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
            Method (TBCF, 0, NotSerialized) { Return (0x54420501) }
            Name (_CRS, ResourceTemplate ()
            {
                GpioIo (Exclusive, PullNone, 0, 0, IoRestrictionOutputOnly,
                    "\\_SB.GPIO", 0, ResourceConsumer, ,) {38}
                GpioIo (Exclusive, PullNone, 0, 0, IoRestrictionOutputOnly,
                    "\\_SB.GPIO", 0, ResourceConsumer, ,) {67}
                GpioIo (Exclusive, PullNone, 0, 0, IoRestrictionOutputOnly,
                    "\\_SB.GPIO", 0, ResourceConsumer, ,) {68}
                // Provider v3 toggles only OE with a LOW output latch.
                // These exclusive reservations remain open until mux restore.
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
                // 100 kHz is the bus speed limit; initial GPIO transport <=50 kHz.
                I2cSerialBusV2 (0x0028, ControllerInitiated, 100000,
                    AddressingMode7Bit, "\\_SB.TI2C", 0,
                    ResourceConsumer, , Exclusive)
                GpioInt (Edge, ActiveLow, Exclusive, PullUp, 0,
                    "\\_SB.GPIO", 0, ResourceConsumer, ,) {39}
            })
        }
    }
}
