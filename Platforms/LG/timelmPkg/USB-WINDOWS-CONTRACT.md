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

## One-boot Windows trial

UsbWindowsOnce.efi restores and verifies both original boot files first, starts
only the verified primary native host, installs an enabled copy of the candidate
SSDT for that boot, then starts the original Windows Boot Manager. It has a
separate timelm-usb-windows.txt log and usb-windows.json build manifest. It is
distinct from UsbHostProbeOnce, which still tears down and shuts down before OS
boot. Neither app is included in the normal firmware image.

Before hardware changes, the Windows trial requires ACPI table/SDT services,
one known minimal timelm DSDT and no SSDT extensions. Every DSDT byte must match
the versioned template except checksum and the exact data payload ranges patched
by Kona AcpiTableUpdate.c. Opcodes, names, resource bytes, lengths, header and
unpatched fields are not masked. An unsupported namespace stops the trial; it
is not replaced. The generator verifies the template against the overlay SHA256
manifest and compiles a separate enabled SSDT without modifying UsbHost.asl.

After the guarded native start, a sole primary host must have the verified
owner's six methods, core 0/mode 1, operational state, superspeed capability,
two ports and 64-bit addressing. The app installs and reads back the exact
enabled SSDT, then flushes the log before loading the original Windows manager
with inherited load options. It does not retry UEFI bus binding or require a
UEFI mouse cursor. No persistent ACPI table, driver, BCD, firmware variable or
boot-partition change is part of the runtime handoff.

If Windows does not return, firmware exit callbacks and the Windows driver take
over. If any trial step fails or Windows returns, the app removes its own table
when installed, stops the attempted host and restores peripheral mode, then
saves logs and shuts down. Even a failed start is cleaned up. Removal/cleanup
errors are logged and block OS fallback. Both EFI entry files were already
restored before hardware changes, so the next boot is the normal Windows path.
The node is memory-only and disappears on a reboot; no SSDT is read from ESP.

The Qualcomm reference UsbConfigLibExitBootService closes port/core resources
and detaches the USB SMMU domain. Its HostModeSupported/static-config paths also
affect PHY handling. Those are reference-source observations, not verified
behavior of every captured LG method. Confirm the captured firmware handoff
before declaring that clocks/PHY/DMA remain usable in Windows. This launcher
does not bypass or patch native ExitBootServices callbacks. A stopped xHCI
at ExitBootServices can be normal; Windows must initialize its own controller
state, and usable hardware power/role must survive or be reinitialized.

The first Windows success criterion is a started xHCI device and root hub in
Kernel-PnP logs, followed by the mouse's USB VID/PID and HID enumeration. A node
appearing in Device Manager or an INF being present alone is not working OTG.
Windows PMIC currently reports Code 10, so connector power/role may still require
separate integration if the host enumerates but no device attaches.

V4's targeted UEFI bus-binding probe remains available as a diagnostic, but a
working UEFI HID UI is not a prerequisite for building the Windows ACPI path.

For a physical trial after staging the verified Windows variant: leave mass
storage, attach OTG/mouse before selecting Windows, and observe whether Windows
or its existing repair environment accepts input. This variant attempts Windows
boot, so successful handoff does not automatically shut down. On an early gate
failure it saves the ESP log and powers off. Return to mass storage to collect
the ESP log and Windows Kernel-PnP/System/setupapi logs. If input works, shut
Windows down normally before changing modes. Physical OS USB validation is
pending; the known-working boot image and immutable EFI backups are retained.
