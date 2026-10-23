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

## The lost eighth attempt and the ninth attempt (23.10.2026)

The eighth attempt of 23.10. 2026 was a lost trial, not a driver fault. The
runner found no trial SSDT in its baseline and stopped with `Expected GPIO-only
trial SSDT missing`. Its `gates-before.json` shows the host gate armed
(`NativeGpioI2cEnabled` 1) with every other gate at 0, and `complete.json`
records `normal_shutdown` true, so the phone shut down cleanly instead of
crashing.

The trial SSDT only exists in the boot that passes the trial EFI, and the ESP
keeps the log of that EFI in `timelm-touch-gpio.txt`. That log holds eight
identical blocks. Every block reports `Restore status`, `Enumeration namespace
gate`, `Install enumeration SSDT`, `Enumeration table readback`, `LoadImage`
and `child LoadedImage` at `0x0000000000000000` and ends in `Windows stage:
BEFORE StartImage (original Windows Boot Manager)`. The trial EFI therefore
restores the original Windows boot manager first, installs the GPIO only SSDT
and hands the boot over in each of those eight boots. The SSDT of three older
attempts is byte for byte the AML of the bundle (`79aab95e...`, OEM table id
`TIMLTGPI`), so the table does reach Windows when the boot passes the EFI.

The eighth attempt never passed the trial EFI: its baseline holds no `SSDT.dat`
and the collector says `SSDT was not enumerated`. The same bundle that failed
at 20:36 on 22.10. produced the SSDT at 19:59, so the loss is in the boot
path and not in the build. The ESP log is read through the volume path of
partition 29, because a normal drive letter walk does not show it.

The ninth attempt is staged from commit `8dc48d83...` under the same rules:
the launcher is the ARM64 EFI `964ff1bb...` (12 800 bytes) in
`EFI\Microsoft\Boot\bootmgfw.efi` and in `EFI\Boot\bootaa64.efi`, the original
Windows boot manager is kept in the two `*.timelm-i2c-original.efi` backups,
the BCD is not modified and the only armed gate is `NativeGpioI2cEnabled` (1)
while `WindowsIommuEnabled`, `NativeBoardInitEnabled`, `NativeGpiEnabled`,
`FirmwareHandoffVerified`, `SourceClockHz` and
`ReadOnlyHardwareProbeEnabled` stay at 0.

The ninth attempt needs the one boot that carries the trial EFI: stage, then
reboot the phone so that the boot passes the firmware. A boot that reaches
Windows without the trial EFI has no trial SSDT and loses the attempt, which
is what the eighth attempt did.

## The staged tenth attempt (23.10.2026)

The ninth attempt turned its open questions into evidence. Its runtime guard
threw `Pre-existing hardware gate enabled: NativeGpioI2cEnabled` at
05:13:50Z before any baseline existed, because the staging had armed the host
gate for a clean bundle: the installed host INF was the older `ad746bac`
build, so the runner refused the pre-armed value. The same boot records how
the driver saw the trial's four `GpioIo` connections: the resource hub calls
them `IdLowPart` 1..4 instead of the physical TLMM numbers 38, 67, 68 and 36,
and the bus connection (id 4, read access) opened while the power
connections (ids 1..3, write access) failed with `0xC00000BB`.

The tenth attempt therefore changes the namespace and the staging rule.

* The trial DSDT's GPIO controller self-references its own pins: its `_CRS`
  carries one `GpioIo` entry per TLMM pin 0..68 (the SOUTH range that the
  driver's `TileOffsets` model walks), so the connection position a consumer
  addresses equals the physical pin number. The registered expectation is
  that the driver records the pin ids 38, 67, 68 and 36 instead of 1..4,
  and that the file system test that follows keeps its first pin check at
  38. A result that still lists the sequential 1..4 refutes the registry
  idea and moves the question to the connection-id semantics of Windows.
* Staging writes `NativeGpioI2cEnabled` 0 for a clean bundle and 1 only when
  this bundle's own host INF is already installed (a resumed attempt). A
  fresh boot enumerates the host with the gate at zero - the code 10 that
  the 19:59 boot already proved harmless - and the runner arms the gate
  itself after its driver upgrade, while the stopped device allows the
  write. The `host-gate.json` receipt now carries `value` 0 or 1 and
  `stage-status.json` records `host_gate_resume`.
* The staging retires a previous attempt's leftovers by family identity:
  the retired bundle still has to pass the full driver manifest check and
  carry a `touch-gpio.json` that describes the same restore-first,
  non-SMMU GPIO trial for this exact Windows image. A foreign or altered
  leftover is refused. The ninth attempt's own bundle and log are what the
  tenth staging retires this way.

## The lost tenth attempt (23.10.2026)

The staged tenth attempt lost at the EFI's first contract phase, in front of
Windows. The ESP log records the whole run: `Restore status=0x0`, then
`Enumeration namespace gate=0x8000000000000021`, then `Trial returned;
shutdown. Original Windows restored for next boot.` Every earlier boot in
this log printed zero there, and nothing else differs: the binary, the SSDT
and the flow come out of the same source; only the baked `mTimelmDsdt`
fingerprint inside the launcher moved.

`0x8000000000000021` is this base's `EFI_COMPROMISED_DATA` - `ENCODE_ERROR(33)`
in MdePkg, where Mu renumbers the extended statuses. At that check
`TrialTables(Sdt, FALSE)` refuses a firmware DSDT that is not the known
table: `TrialKnownDsdt` requires the live length to equal
`sizeof(mTimelmDsdt)`. Windows' stock boot of the next cycle reads a 952-byte
DSDT - the pre-registry platform table - while the built launcher bakes the
pin-registry DSDT of 3369 bytes. That launcher never installs a DSDT: its own
log line says `No firmware GPIO/MMIO or IORT change`, because the DSDT is
owned by the flashed platform firmware.

The pin-registry experiment therefore cannot ride a one-boot trial alone.
It needs the registry DSDT inside the platform image itself, which is what
`prepare_timelm.py` already prepares Silicium-ACPI for, and the launcher
fingerprint then has to stay aligned with the flashed table: the second
boot's DSDT readback (952 bytes, `b759e921...`) still differs from the
repository's pre-registry AML (`b1446886...`) at masked positions only, so
compiler fingerprints differ by build even for the same source, and the
mask mechanism of nine earlier zero-gate boots is what lets those builds
share one contract.

The flash side now follows the same rule. `prepare_timelm.py` no longer
recompiles the table with a local iasl: it copies the overlay assets and
verifies that the platform tree's `DSDT.aml` still carries the manifest
fingerprint, since `AcpiTables.inf` embeds the AML verbatim into the
firmware volume. The flashed DSDT is therefore the same CI-compiled
pin-registry table the launcher bakes, and the remaining live-versus-baked
differences are exactly the masked runtime-patch fields.

Everything else held. Restore-first worked: both boot managers are back to
the stock `fae47d78...` image. The refusal shut the machine down before any
Windows change existed. `gates-before.json` of the stock cycle records all
seven gate checks at 0, so the staged clean-bundle zero gate survived. The
runner's SSDT-missing cycle healed cleanly - before/after device snapshots,
`Expected GPIO-only trial SSDT missing`, normal shutdown, its entries
disarmed - and the driver store of 579 INFs checked stayed the same. The
phone carries no active GPIO trial state besides the standing button
watcher.

## Contract reset to the live baseline, and per-milestone evidence (23.10.2026)

Both follow-ups apply the closed-session analysis collected under
`docs/touch-gpio-handoff-20261023` after the lost tenth attempt.

The pin-registry platform flash is on hold: forcing "connection ID equals
physical pin number" has no basis in the Windows contract, so nothing may
borrow that premise as a reason to flash. The trial contract instead returns
to the baseline platform DSDT the firmware already serves. The launcher now
bakes the captured 952-byte table itself, `b759e921...`, byte-identical on
the two boots behind the trial 9 and trial 10 evidence, behind the same
narrow runtime mask. A diff against the pre-registry AML `b1446886...`
differs in 83 bytes and the reviewed mask covers every one of them (85
masked bytes, 8.9 percent), so the guard stays strict. The SSDT side no
longer needs iasl either: the 451-byte `TIMLTGPI` SSDT that trial 9 already
enumerated cleanly is baked byte for byte, `79aab95e...`. The generator pins
both SHA-256 values and refuses any other snapshot, the default iasl flow
for CI is untouched, and `build_touch_gpio_trial.sh` accepts
`TIMELM_TOUCH_DSDT_SNAPSHOT` and `TIMELM_TOUCH_SSDT_SNAPSHOT` for the
snapshot mode. The launcher built on this contract is 12800 bytes,
SHA-256 `5a3a3a27...7727f5`, and its `windows_reference` still matches the
stock boot managers (`fae47d78...`, 3120648 bytes) every restore lands on.
While the platform readback stays `b759e921...`, the namespace gate passes
with no platform flash at all.

The driver wave then makes the next failure attributable without a kernel
dump. The runner will write a per-boot `TimelmTouchAttemptId` to the device
instance key; the adapter reads it in prepare and echoes it as
`TimelmBitbangAttempt`, so every value in the collection binds to one boot.
`TimelmBitbangFailOp` names the first failed milestone of the boot - zero is
none, then contract, memory, class, count, open bus, links, provider,
interface, open output, write low, GPIO-mode, VCL, VDD, reset, sample,
identity at 1 through 16 - and this numbering is a log ABI that must never
be renumbered. Per-pin evidence arrives as `TimelmBitbangOpenStatus0..4` and
`TimelmBitbangWriteStatus0..4` (status of each open and write),
`TimelmBitbangWriteBytes0..4` (bytes each write moved),
`TimelmBitbangPinIdHigh0..4` (the high dword of each ResourceHub id),
`TimelmBitbangConnOrdinal0..4` (the resource ordinal each connection came
from), `TimelmBitbangResourceCount` (the raw resource total) and
`TimelmBitbangIfaceVer`/`TimelmBitbangIfaceSize` (the negotiated provider
interface identity); `TimelmHostBackend` names the selected backend (1
bitbang, 2 probe, 3 native FIFO, 4 GPI) on every boot. The
`TIMELM_TOUCH_BUS_V3` interface ABI is untouched.

The adapter tests grow the same evidence surface: registry mocks for the
attempt id, an assertion that the attempt plumbing survives the split-bus
resource shape, and forced-failure checks that map each broken call to its
exact milestone value. All three local test suites pass under
ASan and UBSan.

The orchestration scripts encode the four staging lessons the same way.
The runner now takes the persisted driver registry snapshot and phase
receipts BEFORE it refuses a host start, so a Code 10 moment leaves the
next analysis nothing missing. It asserts the provider's effective gate as
soon as the replacement provider restarts: a restart that publishes
`TimelmGpioBitbangGate=0` stops the trial there and never lets the host eat
a boot with a gateless provider. It binds every boot to one attempt id:
staging writes `TimelmTouchAttemptId` into the device parameters key of
`ACPI\TIML0001` through the phone hive, the runner keeps that value
(generating one only when staging skipped it) and the adapter reports it
back as `TimelmBitbangAttempt`, recorded next to the stage and statuses in
`host-bitbang.json`. The staging resume decision moved to the package the
device itself selected: the offline gate script follows the binding from
the Enum tree into the Class nodes and hashes that INF, refusing to guess
from the store listing; the bundle's own INF on disk is still recorded, and
the reference pass and the final gate/attempt write run as two verified
Arm calls. All of it is pinned by `Test-TouchGpioGuards.ps1`, which now
refuses a runner whose snapshot lands behind its own refusal, a staging
that never reads the selected package, and a staged boot without an
attempt id.
