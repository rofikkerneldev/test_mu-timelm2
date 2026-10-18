# timelm Windows driver replacement

The requested replacement source is N1kroks' WOA-Kona/Drivers, pinned to
3dcdec0bd59e3e77be92629b2ed9e095ae6e19e8. This commit is attributed to the
GitHub account N1kroks. Build with the manual `Build N1kroks Kona DEBUG drivers`
workflow, or Resources/Scripts/build_kona_drivers.ps1 on a Windows WDK host.
The build targets ARM64 Debug with KMDF 1.33 for Windows 11 22H2.

The source implements GPIO (KONA1001), SPMI (KONA1002), and PMIC (KONA1003).
It does not contain replacements for every driver in the old QC8250 package.
Current minimal timelm ACPI needs matching device descriptions before these
drivers can enumerate. The common/alioth PMIC configuration is not a validated
timelm configuration. Build success does not establish hardware support.

Recovery read-only inspection matched 134 installed OEM INFs to QC8250 and
28 to ANYSOC. Keep an exact hash manifest and native DISM export before any
offline removal. Preserve inbox storage/ACPI drivers, including storufs.
Do not remove old packages until replacement packages and rollback are ready.
The rejected qcppx service remains disabled in the current diagnostic install.

GPIO/SPMI/PMIC integration and native Windows Setup repair are pending.
