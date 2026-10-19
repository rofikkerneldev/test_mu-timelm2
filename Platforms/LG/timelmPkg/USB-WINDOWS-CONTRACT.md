# Primary USB host contract for the V60

The physical cc6a440 probe with OTG attached publishes an operational UEFI
USB2_HC on primary core 0 after the known LG native host request. This is enough
to investigate Windows ACPI enumeration without first requiring a UEFI mouse
cursor. It does not establish peripheral enumeration or an OS handoff. The test
stops the host, restores peripheral mode and shuts down before Windows.

## Verified resources and driver match

| Item | Evidence and value |
| --- | --- |
| Primary core base | Native protocol and Recovery DWC3 DT: 0x0A600000 |
| xHCI register subrange | Linux v6.15 DWC3 core.h: offsets 0x0000..0x7FFF |
| Host IRQ | Recovery dwc3@a600000: SPI 133, level high; ACPI GSIV 165 |
| Reference IRQ agreement | Kona usb.asl and alioth URS0.USB0 both use 165 |
| Firmware host | One operational HC, superspeed, two ports, 64-bit addressing |
| Windows inbox driver | Installed ARM64 usbxhci.inf 10.0.26100.9444 matches ACPI\\PNP0D10 |
| Cache attribute | Kona USB reference uses _CCA=0; retained in the candidate |

Microsoft documents a vendor hardware ID, the standard xHCI compatible ID
PNP0D10, and memory/interrupt resources for ACPI-enumerated SoC USB hosts:
[USB host controllers and devices](https://learn.microsoft.com/en-us/windows-hardware/drivers/bringup/other-acpi-namespace-objects#usb-host-controllers-and-devices).
The register subrange comes from the original
[Linux v6.15 DWC3 definitions](https://github.com/torvalds/linux/blob/v6.15/drivers/usb/dwc3/core.h),
not a guessed full wrapper/PHY memory range.

Experimental/UsbHost.asl provides a reviewable, standalone host-only SSDT
candidate with private _HID TIML0002 and standard _CID PNP0D10. It is disabled
by UHEN=0 and excluded from the booting DSDT/FDF. A root hub _ADR=0 is included;
connector topology, wake, power methods and role-switch functionality are not
invented. Compilation is not hardware validation or deployment. Do not install
this candidate alongside another enabled owner of the same DWC3 controller.

## Why the reference dual-role node is a separate path

WOA-Kona/Drivers common/usb.asl uses a PNP0CA1 role-switch parent with USB host
and function children. Alioth's URS0 also depends on PEP0 and UCP0. The current
V60 DSDT exposes neither of those dependencies. Its installed urssynopsys.inf
matches PNP0CA1/QCOM24B6, while usbxhci.inf directly matches PNP0D10.
Copying the dual-role parent is not equivalent to the minimal host-only trial.
Never expose host and function controllers concurrently over the same registers.

## Remaining handoff work

A paired Windows trial needs to restore the original boot files first, start
only the verified primary native host, install the candidate table for that
boot, and start the original Windows Boot Manager. Native host/owner/table
failures must not expose an active ACPI node against a peripheral controller.
The persistent DSDT and known-working boot image should remain available for
rollback. The current shutdown-only probe is not that Windows launcher.

The Qualcomm reference UsbConfigLibExitBootService closes port/core resources
and detaches the USB SMMU domain. Its HostModeSupported/static-config paths also
affect PHY handling. Those are reference-source observations, not verified
behavior of every captured LG method. Confirm the captured firmware handoff
before declaring that clocks/PHY/DMA remain usable in Windows. A stopped xHCI
at ExitBootServices can be normal; Windows must initialize its own controller
state, and usable hardware power/role must survive or be reinitialized.

The first Windows success criterion is a started xHCI device and root hub in
Kernel-PnP logs, followed by the mouse's USB VID/PID and HID enumeration. A node
appearing in Device Manager or an INF being present alone is not working OTG.
Windows PMIC currently reports Code 10, so connector power/role may still require
separate integration if the host enumerates but no device attaches.

V4's targeted UEFI bus-binding probe remains available as a diagnostic, but a
working UEFI HID UI is not a prerequisite for building the Windows ACPI path.
