# Standalone I2C clock query app

This ARM64 UEFI application asks the existing EFI_CLOCK_PROTOCOL for IDs,
enabled/on status and configured frequency of the touch engine/wrapper clocks.
It does not read MMIO, enable clocks, change rates, select pins, reset hardware
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
