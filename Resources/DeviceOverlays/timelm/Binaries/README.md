# timelm firmware assets

These files are the device assets used by this LG V60 firmware bring-up.
They are firmware components, not Windows drivers.

The initial directory layout came from Project-Silicium Device-Binaries at
a1501e0c2e642d6ac0d8f52c85af2a67b75a7799. The original alioth documentation
is retained as UPSTREAM-REFERENCE.md for attribution; its device name and
patch list must not be interpreted as a timelm compatibility report.

An audit of the driver's firmware sections referenced by this platform
matched the captured LG V60 XBL sections before the later USB experiment.
The current candidate includes an explicit four-byte fixed-media Inquiry
change in UsbMsdDxe. Earlier tests still had CBW/Tx failures and host disk-service
stalls. A later physical session successfully exposed raw LU0 to a Windows PC,
mounted win as NTFS, and allowed verified ESP file access. That observation does
not establish that the Inquiry change alone fixed transport, nor does successful
USB device-mode mass storage establish working UEFI USB host/OTG support.

Raw configuration/panel files include the LG BOE SW43103 references. The
boot-tested display path uses the inherited framebuffer with SimpleGOP;
native Windows panel/display support is not established.

Preserve the upstream project and binary component attribution when reusing
these assets. A SHA256 manifest accompanies the device overlay.
