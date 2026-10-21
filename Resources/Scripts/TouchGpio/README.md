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

A successful provider restart is not proof of the v3 interface. The host's
query-interface and basic identity read must prove the path. If GPIO's gate is
not observed, logs identify the failed host/interface stage for the next test.
After host activation, the desktop remains available for 120 seconds for taps/swipes.
A process-scoped execution-state request keeps the display/system awake throughout
baseline collection, installation, the test window and final collection, restoring
the request in finally before shutdown; no power plan is edited. If that request
fails, the helper refuses hardware activation because initial bring-up has no D0 resume.
The runner then collects diagnostics, removes its verified task and requests normal shutdown. A 3010 exit
records a required second boot and shuts down after collection; it never forces
an automatic reboot. Logs and gate snapshots stay under TimelmLogs/TouchGpioTrial.

`Test-TouchGpioGuards.ps1 [-Artifact <bundle>]` is safe on the x64 build PC:
it parses scripts, optionally verifies package files, and executes the runtime
runner only to prove its very first machine guard rejects the PC.
