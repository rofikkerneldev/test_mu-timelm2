// SPDX-License-Identifier: BSD-2-Clause-Patent
// Review/compile candidate. NOT included in the booting DSDT or FDF.
// Enabling this node does not start the PHY, select host or provide VBUS.
DefinitionBlock ("", "SSDT", 2, "LGE   ", "TIMLUSBH", 1)
{
    Scope (\_SB)
    {
        // Enable only in a paired native-host/Windows handoff experiment.
        Name (UHEN, Zero)
        Device (XHC0)
        {
            Name (_HID, "TIML0002") // private prototype identity
            Name (_CID, "PNP0D10") // standard ACPI xHCI inbox driver match
            Name (_UID, Zero)
            Name (_CCA, Zero)       // matches the Kona reference, no coherency claim
            Method (_STA, 0, NotSerialized) { Return (UHEN * 0x0F) }
            Name (_CRS, ResourceTemplate ()
            {
                // DWC3 host window: offsets 0..0x7FFF, Linux v6.15 core.h.
                // Do not expose the DWC3 peripheral/global/PHY registers here.
                Memory32Fixed (ReadWrite, 0x0A600000, 0x00008000)
                // Recovery DWC3 interrupt SPI 133 + GIC SPI base 32 = 165.
                Interrupt (ResourceConsumer, Level, ActiveHigh, Shared) {165}
            })
            Device (RHUB)
            {
                Name (_ADR, Zero)
            }
            // No invented _PS0/_PS3, role switch, wake or connector mappings.
        }
    }
}
