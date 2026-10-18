# timelm Windows driver replacement

The requested replacement source is N1kroks' WOA-Kona/Drivers, pinned to
3dcdec0bd59e3e77be92629b2ed9e095ae6e19e8. This commit is attributed to the
GitHub account N1kroks. Build with the manual `Build N1kroks Kona DEBUG drivers`
workflow, or Resources/Scripts/build_kona_drivers.ps1 on a Windows WDK host.
The build targets ARM64 Debug with KMDF 1.33 for Windows 11 22H2.

The source implements GPIO (KONA1001), SPMI (KONA1002), and PMIC (KONA1003).
It does not contain replacements for every driver in the old QC8250 package.
The timelm DEBUG candidate now supplies the matching GPIO/SPMI/PMIC ACPI
devices. SPMI resource order follows the driver contract, and PMIC PCFG uses
the five SID pairs found in the live timelm Recovery device tree: 0/1, 2/3,
4/5, 8/9, A/B. The upstream 6/7 pair is omitted. GPIO uses three logical
banks sharing GSIV 240 and one tile-offset MMIO span. Hardware behavior
and interrupt handling still require validation.

Recovery read-only inspection matched 134 installed OEM INFs to QC8250 and
28 to ANYSOC. Keep an exact hash manifest and native DISM export before any
offline removal. Preserve inbox storage/ACPI drivers, including storufs.
Do not remove old packages until replacement packages and rollback are ready.
The rejected qcppx service remains disabled in the current diagnostic install.

ARM64 DEBUG build, catalogue signability checks, and PE machine checks passed
in GitHub Actions run 39163181015. The updated UEFI DEBUG build passed the
49-image validation step; its Android boot image SHA256 is
f31066e31819dea94f89225e98704d8189a6bfd0e669eec3e5312fd4f8cb3926.
Native driver servicing and Windows Setup completion remain pending device
results. Touch, graphics, Wi-Fi and other unsupported peripherals are not
provided by these three drivers.
