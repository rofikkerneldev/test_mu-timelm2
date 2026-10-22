# One-boot GPIO touch trial

`Build-TouchGpioPackage.ps1` assembles the verified bundle on the build PC:

```powershell
./Resources/Scripts/TouchGpio/Build-TouchGpioPackage.ps1 `
  -GpioPackage <kona-packages\GPIO> -HostPackage <KonaGeniI2c\out\ARM64\Debug\kona_geni> `
  -TouchPackage <Sw42902Touch\out\ARM64\Debug\sw42902> -Trial <Build\TouchGpio> `
  -InstalledInfFolder <mounted phone Windows\INF> -Output <new bundle folder>
```

It reads only build outputs and the phone's installed INF set. Each package
must contain the expected INF, catalog and SYS; a missing certificate is taken
from the signer of the signed driver. The INF catalog and hardware ID must
match the manifest identity, and every installed INF matching that hardware ID
is recorded as a reviewed replacement. The launcher, SSDT and their recorded
hashes must match, the launcher must be an ARM64 EFI application and the
metadata must describe a restore-first GPIO-only trial. The finished bundle is
re-read with the runtime manifest check, so a bundle that the phone bootstrap
would reject is never produced. The output directory must not exist.

`Stage-TouchGpioTrial.ps1 -Artifact <verified bundle> -Output <new PC receipt folder>`
checks the exact USB serial, disk size, Windows/ESP partition geometry, marker,
package hashes, reviewed installed INF hashes, SSDT and original Windows EFI.
Both restore-first EFI backups and PC copies must verify before startup/EFI
are armed. BCD and boot partitions are not modified. Any staging failure rolls
back changed EFI entries and this trial's startup file; copied helper files
remain unarmed for inspection. Existing trial directories are never rearmed.

The trial SSDT only exists in the one boot that passes the trial EFI: the EFI
restores the original Windows boot manager first and then installs the SSDT, so
the table is gone again on every later boot. The staging therefore arms two
things that must meet in the *same* boot: the trial EFI on the ESP, and the
Startup entry that starts the runner at the next logon. The order is:

1. the phone is in mass storage (Windows stopped) and the staging runs,
2. the phone is powered off completely and powered on again,
3. that boot passes the trial EFI, the SSDT is present, the auto logon fires the
   Startup entry and the runner finds the SSDT in its baseline.

If the phone logs on without having been rebooted after the staging, the
runner aborts with `Expected GPIO-only trial SSDT missing`; that is a lost
trial, not a driver fault, and the fix is to re-stage and to reboot the phone
rather than to change the drivers.

The artifact contains `TouchGpioOnce.efi`, `touch-gpio.json`, `TouchGpio.aml`,
`package.json` and `Drivers/{GPIO,Host,Touch}` with exactly four files per package
(INF/CAT/SYS/CER). `package.json` schema1 has trial `touch-gpio-v1`, SSDT SHA256,
`files` entries `{path,size,sha256}` and three `packages` entries
`{name,inf,catalog,certificate,certificate_thumbprint,replaces_inf_sha256}`. File paths
use `/`. Package basenames are GPIO, kona_geni and vhidmini respectively;
the touch catalog is `sw42902.cat` as declared by its INF.
The optional replacement hashes must cover every matching installed INF.

The ARM64 desktop built-in Administrator bootstrap creates and starts one
on-demand SYSTEM task, `TimelmTouchGpioOnce`, with a 30-minute execution limit.
This final guard covers the bounded PnP/collector operations and test window
even when several operations complete near their individual time limits.
An existing task is never replaced or rearmed. The SYSTEM runner has an atomic one-attempt
marker, disarms its startup file, collects baseline data, verifies the one-boot
SSDT and imports only the three package certificates on the phone. It advances
the phone clock to the staged PC UTC only if certificate validity requires it.
It upgrades GPIO then restarts that exact provider with TouchBusGpioEnabled=1;
it installs the host, enables only NativeGpioI2cEnabled=1 and restarts TI2C;
then it installs the SW42902 client. Native GENI/GPI/IOMMU gates stay zero.
After each install it follows that device's selected class key to its published
OEM INF and verifies the new package hash. A successful PnPUtil exit that leaves
an older package selected fails the trial before that provider's gate is enabled.
PnPUtil exit code 259 (ERROR_NO_MORE_ITEMS) is not a failure: it is the normal
answer when the package is already the selected driver for that device. The exit
code is recorded and the selected INF of the exact device is verified
separately, so the package identity is still proven.

A second Startup entry opens Device Manager expanded in the logged-on desktop
session, so the loaded drivers can be read while the trial runs. The helper
only displays: it expands the console tree through UI Automation, refreshes it
after every hardware phase receipt the runner publishes, and records what it saw
in `device-manager-phases.json`. A process of the SYSTEM task stays in session 0
and can never show a window, which is why the display helper runs from the
Startup folder instead. The entry is disarmed by the same rule as the trial
entry: only an entry that the staging script wrote byte for byte is removed, and
a foreign entry is never touched.

The runner records the enumeration timeline of the trial as plain text. It
samples the device node list around every provider restart, because the ACPI
child of the bus host may exist for a moment before Windows removes it again;
each sample is one JSON line in `watch-*.jsonl`. It snapshots the rolling
SetupAPI log after every install, and it records a live ETW trace of the kernel
PnP and ACPI providers that the build PC converts to CSV with `tracerpt`.

A successful provider restart is not proof of the v3 interface. The host's
query-interface and basic identity read must prove the path. If GPIO's gate is
not observed, logs identify the failed host/interface stage for the next test.
The host records `TimelmBitbangPinCount` plus `TimelmBitbangPinId0..4`, so a
trial log states whether Windows published the 36/37 bus pair as one connection
resource or as one resource per pin, and in which order the connections
arrived. After host activation, the desktop remains available for 120 seconds for taps/swipes.
A process-scoped execution-state request keeps the display/system awake throughout
baseline collection, installation, the test window and final collection, restoring
the request in finally before shutdown; no power plan is edited. If that request
fails, the helper refuses hardware activation because initial bring-up has no D0 resume.
The runner then collects diagnostics, removes its verified task and requests normal shutdown. A 3010 exit
records a required second boot and shuts down after collection; it never forces
an automatic reboot. Logs and gate snapshots stay under TimelmLogs/TouchGpioTrial.

`Test-TouchGpioGuards.ps1 [-Artifact <bundle>]` is safe on the x64 build PC:
it parses scripts, optionally verifies package files, and executes the runtime
runner only to prove its very first machine guard rejects the PC. It also runs
`Test-TouchGpioPackage.ps1`, which builds a synthetic bundle to prove the
builder accepts a correct package and rejects a wrong hardware ID, a wrong
catalog, a mismatched trial hash and an existing output directory.

## What the phone shows about the failing stage (23.10.2026)

The build that is installed on the phone was identified by the hash of the
files in the driver store, not by the name of the folder:

| Node | INF | Driver store | File | SHA-256 |
| --- | --- | --- | --- | --- |
| `ACPI\TIML0001\E` | `oem153.inf` (DriverVer 10/22/2026,2.50.18.606) | `kona_geni.inf_arm64_acad333869a973e5` | `kona_geni.sys` 93624 bytes | `5FE2FEEC01053F50CC33C93102BFAA449A12D487D77D6AA2CA472A8EF671C89C` |
| `ACPI\KONA1001\0` | `oem152.inf` (DriverVer 10/22/2026,2.50.19.609) | `gpio.inf_arm64_895fd6fa0c8d01ca` | `GPIO.sys` 48208 bytes | `9A34626BF80FD15DD7C2CEA70DF209D57CE35682BDF9FA1CFDEDCEB5C3BA4A32` |

Both files are the pair of `artifacts/LGV60-touch-GPIO-ad746ba`: the host is
the bitbang build (it holds `TimelmBitbangStage`, `TimelmBitbangPinCount`
and `TimelmBitbangStatus` and queries `GUID_TIMELM_TOUCH_BUS_V3`), the
provider registers `GUID_TIMELM_TOUCH_BUS` (version 2) and
`GUID_TIMELM_TOUCH_BUS_V3` (version 3).  The query of the interface at
`bitbang_windows.c:119` can therefore be answered.

**`BbWindowsPrepare` was never entered on the phone.**  Its first action is
`GeniRecord(device, L"TimelmBitbangStage", 1)`, and the device parameters of
`ACPI\TIML0001\E` hold no `TimelmBitbangStage`, no `TimelmBitbangPinCount`
and no `TimelmBitbangStatus` (read on 22.10. 01:16, 22.10. 03:31 and
23.10.).

The `TimelmHostStatus` of that node is `3221225635` (`0xC0000003`,
`STATUS_INVALID_INFO_CLASS`).  The current source cannot write that value on
a path that leaves `TimelmBitbangStage` away:

* `driver.c:186` writes the answer of `BbWindowsPrepare`, so the stage value
  would be there,
* `driver.c:199` writes `0xC00000A3` (`STATUS_DEVICE_NOT_READY`),
* `driver.c:275`, `:297` and `:311` write the answer of the start of a device
  that was prepared successfully,
* `probe_windows.c:90` writes `0xC00000A3`.

The value is therefore left over from an older build, and the host did not
run the prepare at all after the last gate was set.  The last GPIO trial
stops exactly one step before that: `operations.json` of the fifth trial of
the 22.10. holds `install-GPIO`, `restart-GPIO` and `install-Host`, but no
`restart-Host`, and `gates-before.json` shows all gates at `0`.

The runner now proves the step instead of assuming it: after the restart of
the host it writes `host-parameters.json` and `host-bitbang.json` and stops
the trial when the driver wrote no `TimelmBitbangStage`.
