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
