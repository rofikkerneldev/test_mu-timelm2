# One-boot V60 touch enumeration

This is the first hardware stage after building the translated DMA candidate.
It exposes the actual `TI2C` / `TIML0001` and `TSCV` / `LGSW4290` resources from
`TouchIommuWindows.asl`, enabled in a separately generated SSDT `TIMLTENU`.
It does **not** install an IORT or initialize clocks, GPIO, touch, GPI or SMMU.
No host/client driver may already be installed when this trial is staged.
It cannot demonstrate working I2C, DMA, touch interrupts or input.

Build `Resources/Scripts/build_touch_enumeration.sh`. The ARM64 EFI launcher
uses the existing `OneShot.h` restoration and the exact size/CRC boot-manager
reference. Before installing its in-memory SSDT it restores and verifies both
original Windows EFI entry files. The existing DSDT must match the known timelm
template except the narrow data payloads patched by Kona AcpiTableUpdate.c;
existing SSDTs or IORTs are rejected. Installation is verified by readback.
Returned Windows/error paths remove only the trial's table and shut down.
On a non-returning Windows handoff the table lasts until reboot. Subsequent
boots use the restored Windows EFI files and normal firmware ACPI tables.

Staging requirements:

- Identify V60 USB serial `8509C01F`, Windows partition 30 and ESP partition 29
  by size and offset; never infer the target from its current drive letter.
- Back up and verify both EFI entries and BCD on the PC. Verify current Windows
  EFI files match the launcher's reference and both immutable restoration files.
- Check every installed Windows INF for `TIML0001` and `LGSW4290`. Refuse staging
  when a matching package exists; do not install or remove drivers in this trial.
- Install a one-attempt desktop collector with a fresh log directory; preserve
  prior diagnostics. Record PnP status/resources and ACPI tables, then request a
  normal shutdown. Do not alter BCD, autologon, OOBE or boot partitions.
- Verify staged file hashes, flush both volumes and dismount before unplugging.

Expected evidence: `timelm-touch-enumeration.txt` on ESP with restoration,
namespace, SSDT/readback and Windows load/start checkpoints; Windows collector
output showing the enabled SSDT and host PDO. Code 28/no driver for the host is
expected. The touch child may remain blocked by its host dependency. Missing
nodes, dependency problems or boot failure must be investigated before the DMA
stage. A successful desktop with these nodes still does not validate SMMU
handoff. The IORT candidate remains undeployed.

Portable `trial_test.c` tests the actual trial implementation with firmware
protocol mocks, including existing IORT/SSDT rejection, corrupted/duplicate
DSDT, enumeration bounds, install/readback/checkpoint failures, cleanup failure,
returned boot manager and non-returning handoff. Existing one-shot tests cover
boot-file restoration and chainloading. Neither replaces device testing.

## Observed V60 enumeration result, 21 October 2026

Windows reached the desktop, collected logs and shut down normally. The
508-byte `TIMLTENU` SSDT read from Windows exactly matched the build artifact.
`ACPI\TIML0001\E` appeared with Code 28 and no service, with GSIV 311 and all
four expected MMIO ranges. `LGSW4290` did not appear, consistent with its
unsatisfied host dependency; the dependency reason has not been independently
queried. GPIO and SPMI remained Code 0; the pre-existing PMIC Code 10 remained.
IORT was absent. Both Windows EFI entries were restored to their original
SHA256, and all BCD registry values were unchanged. No DMA or touch transfer
was attempted. The display remained 1080 x 2460.

## Next stage: default-off Windows host load

`Stage-Enumeration.ps1 -HostLoadTrial -HostPackage <reviewed package>` uses the
same tested EFI/SSDT and a distinct one-attempt `TouchHostLoadProbe` helper.
It still requires no matching package at staging. After Windows starts, the
helper first captures and verifies the exact SSDT, absent IORT, Code 28 host,
no matching installed INF and no previously enabled hardware gates. Only then
does it install the hash-pinned ARM64 host package from successful run
39528696059 using PnPUtil. Host source has not changed since that build.

All five INF activation/clock values remain zero. The reviewed `GeniPrepare`
therefore records stage 1 / `STATUS_DEVICE_NOT_READY` (0xC00000A3) and fails
before MMIO mapping, power, GPIO or DMA setup. Code 10 with these diagnostic
values is the expected result: it proves execution reached the host's gate,
not that I2C works. An earlier signature, dependency, KMDF or SPBCx failure
instead requires investigating SetupAPI and Code Integrity logs. No GPIO,
PMIC, SPMI or touch-client package is installed in this stage.

The helper imports only the pinned test certificate into the **phone's**
LocalMachine Root and TrustedPublisher stores. If the phone clock is earlier
than the certificate's validity, it sets it to the PC UTC time captured during
staging and logs both times. This corrects the observed March 2024 RTC; the
certificate starts October 2026. It does not change the PC clock or stores.
The package/certificate remain available for subsequent tests. The host is a
demand-start PnP service; the one-boot ACPI node disappears on the next normal
boot. PnPUtil is not given `/reboot`. Before/after logs are preserved and the
helper requests normal shutdown, including after a recorded install failure.

References: [PnPUtil syntax](https://learn.microsoft.com/en-us/windows-hardware/drivers/devtest/pnputil-command-syntax)
and [installing test certificates](https://learn.microsoft.com/en-us/windows-hardware/drivers/install/installing-test-certificates).
