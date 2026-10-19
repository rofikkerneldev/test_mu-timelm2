# Standalone I2C clock query app

This ARM64 UEFI application asks the existing EFI_CLOCK_PROTOCOL for IDs,
enabled/on status and configured frequency of the touch engine/wrapper clocks.
It does not read MMIO directly, enable clocks, change rates, select pins, reset hardware
or issue I2C transfers. It is not included in the normal firmware image.

Build with the pinned Mu_Basecore headers and clang/lld:

```sh
git submodule update --init --depth 1 Mu_Basecore
bash Resources/Scripts/build_i2c_clockdiag.sh
```

The output is `Build/I2cClockDiag/I2cClockDiag.efi`. The script checks ARM64 PE,
EFI application subsystem and an empty import table. It links no Windows CRT,
boot services library, or Mu runtime. The clock protocol header's original
Linux Foundation BSD license remains in its existing QcomPkg location.

For a future manual UEFI Shell session on the phone, put the app on the ESP,
select that filesystem (verify its mapping first), then run for example:

```text
fs0:\I2cClockDiag.efi
```

The app displays console output and appends the same report to
`timelm-i2c-clockdiag.txt` in the root of the filesystem from which it was
launched. Previous captures are preserved. It does not change boot files,
partition metadata, Windows registry or hardware state. If launched from FV
or a read-only filesystem, the log operation reports an error and the console
output is still available. This app has not yet been run on the phone.

An absent clock protocol, unsupported older ABI or unknown clock name is useful
diagnostic output; it does not justify calling an unverified ABI or touching
GCC registers. An enabled clock now does not prove retention after
ExitBootServices, nor firmware/pinmux/reset ownership. Those still need proof
before setting the Windows host's FirmwareHandoffVerified gate.

## Once-only Windows boot launcher

For devices without a file browser/Shell, the build also produces
`I2cClockOnce.efi`. This variant is intended to temporarily occupy both
`EFI/Microsoft/Boot/bootmgfw.efi` and `EFI/Boot/bootaa64.efi` on the ESP, with
immutable original copies next to them named `bootmgfw.timelm-i2c-original.efi`
and `bootaa64.timelm-i2c-original.efi`. Staging must verify the current original
images against WindowsBootReference.json, back them up to the PC and ESP, then
verify both replacement files before unmounting. BCD and partition layout are
not edited. Do not deploy this variant as a general boot manager replacement.

On execution, it checks both backups against the expected size/CRC32 and checks
their bytes match. It restores both normal boot entries and reads them back
before calling any clock protocol function. Restore failure stops before clock
queries or chainload. On success, it saves a checkpoint, queries clocks, saves
the log and starts the restored canonical Windows Boot Manager with its original
load options. A missing clock protocol is logged and still permits Windows boot.
The backup files remain available for Recovery rollback. Restoring boot files
is filesystem I/O, with normal power-interruption limits; the restore behavior
has host tests, not a completed V60 boot test yet.

WindowsBootReference.json contains only observed size/CRC32/SHA256, not Windows
binary data. CRC32 is used as a runtime corruption check; installation must
use the stronger SHA256 comparison. This exact-image check intentionally
requires updating the reference after a Windows Boot Manager update.
