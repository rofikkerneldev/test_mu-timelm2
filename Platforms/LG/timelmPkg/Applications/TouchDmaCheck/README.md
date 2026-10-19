# Read-only touch DMA prerequisite check

TouchDmaCheckOnce restores both verified original Windows EFI entries before
reading the known timelm SMMU global page at 0x15000000. It appends its result to
`\timelm-touch-dma-check.txt` on the ESP, then starts the restored Windows Boot
Manager. A successfully restored entry makes the following boot ordinary again.
The existing restore code validates both immutable originals and verifies writes.

This app makes no USB, GPIO, clock, GENI or GPI requests, installs no ACPI table
or driver, and writes no SMMU register. It is separate from all USB host trials.
It is a DMA prerequisite test, not a Windows touchscreen test.

The bounded snapshot requires observed ID0=4c017e57/ID1=6000004a before scanning
valid stream-match registers. It records all valid entries and identifies those
matching stream 0x56, including overlapping masked matches. The supported direct
DMA result requires at least one match, only BYPASS types and an enabled SMMU.
A missing match is reported together with the unmatched-stream fault policy;
the app never creates a new match or forces bypass. Windows must independently
recheck its DMA mapping before using the GPI adapter.

Build with `Resources/Scripts/build_touch_dma_check.sh` and the pinned Mu_Basecore
headers. The output includes an ARM64 EFI application and a hash/reference
manifest. The host snapshot test models unmatched/default fault, valid bypass,
translated/fault mappings, overlapping conflicts, global disable and unknown IDs.
The existing OneShot.h implementation and its restore/chainload tests are reused.

Staging requires an exact phone/ESP identity check, a verified full ESP backup,
matching known Windows originals, readback verification and rollback on error.
No boot partition flash, BCD edit or automatic reboot is needed to stage it.
