# LG V60 ThinQ 5G (timelm) development port

This is an experimental Mu-Silicium port for the LG V60 / Snapdragon 865
(SM8250), tested on an LM-V600 JP, rev_10/subrev_1 device. The LG G8 mh2Pkg
layout is the platform reference; resources and drivers use the Kona path.

## Observed status

Update 2026-10-19: Windows 11 26H2 ARM64 build 26300.9457 reaches OOBE with the
rebuilt Kona GPIO/SPMI/PMIC packages. Recovery inspection confirms that Windows
records an active 1080x2460 display. Touch remains unavailable: the current
ACPI namespace has no I2C controller or touchscreen. See
[current findings](BRINGUP-2026-10-19.md) and the experimental
[SW42902 source candidate](../../../GPLDrivers/Windows/Sw42902Touch/README.md).
The historical observations below describe the earlier 22621 bring-up.

- DEBUG Android boot images have been flashed to both boot slots and booted.
- UEFI menu navigation, the inherited display framebuffer/SimpleGOP and
  internal Windows Boot Manager have been observed working.
- Windows 11 ARM64 22H2 build 22621.1 reaches Starting services / Getting ready.
  A native ARM64 WinPE 22621.1 helper also boots and accesses ESP and Windows.
- Windows installation has **not** completed OOBE or reached a verified desktop.
  The latest failure is the Setup unexpected-restart state after repairing BCD.
- UEFI USB mass storage remains unstable (CBW/Tx failures and host disk-service
  stalls). The fixed-media Inquiry change is an experiment, not a transport fix.
- Touch, GPU acceleration, Wi-Fi, audio, cameras, sensors, charging and suspend
  are not validated. The WOA-Kona GPIO/SPMI/PMIC source is a future reference,
  not an integrated driver package in this firmware port.

## Build (Linux / WSL)

Initialize the repository's pinned submodules, then install the normal
Mu-Silicium build dependencies described in the root README. The tested
environment uses Python 3.14 with edk2 Python dependencies in a virtualenv,
LLVM/Clang 21, an AArch64 GNU toolchain, and ACPICA iasl 20251212.

```sh
git submodule update --init --recursive
# Activate your Python environment containing the Mu build dependencies.
bash Resources/Scripts/build_timelm.sh DEBUG
```

The default mode is DEBUG. Output is `Mu-timelm-0.img`. Use `RELEASE` as the
argument to build a release candidate. The helper verifies and copies the
tracked timelm assets into the Binaries and Silicium-ACPI submodules and
compiles DSDT.asl; no unpublished submodule commit is required. It refuses
to overwrite a differing local non-document asset.

## Boot layout and platform contracts

- Packaging follows N1kroks/Mu-Silicium commit
  e3db358e29ca5cf0050f896208758ed018ec92ab: Android boot header v1, base zero,
  page size 4096, and mainline DTB appended to the gzip-compressed kernel.
- Firmware FD is at 0x9FC00000, size 0x300000.
- SimpleGOP uses framebuffer 0x9C000000, 1080x2460, stride 4320.
- Minimal ACPI declares eight CPUs and UFS QCOM24A5 at 0x01D84000,
  size 0x1C000, GSIV 297, child ADR 8, CCA 0.
- The read-only UFS/SMMU diagnostic DXE records ReadyToBoot and
  ExitBootServices snapshots. ESP diagnostic output is best effort before
  handoff; MMIO diagnostics do not write controller registers.
- Binary/ACPI assets and their hashes are versioned under
  `Resources/DeviceOverlays/timelm`; the upstream submodule pins are retained.

## Windows bring-up findings

The supplied `LG_V60_Windows_Drivers.7z` included a qcppx8250.sys identical to
the experimental WOA-Project Kona BSP. It was not established as a validated
V60 driver set. Its boot-start PCIe PEP triggered signature/policy errors
0xC0000428 and 0xC0430007. Disabling only the qcppx service allowed Windows
to reach Setup. The current minimal ACPI does not expose its QCOM25A2 target.
Successful INF integration alone is not hardware compatibility evidence.

The Windows ESP must have the EFI System Partition GPT type (EF00). A later
22H2 Setup log resolved the correct ESP but rejected BCD as not a system
store. Native WinPE BCDBoot rebuilt that store successfully; Setup retry
still encounters the prior child-process completion state. This remains
under investigation. Windows registry/partition backups, OS images, device
identifiers and private diagnostic captures are kept outside this source repo.

Reference projects:
- https://github.com/Project-Silicium/Mu-Silicium
- https://github.com/Project-Silicium/Silicium-ACPI
- https://github.com/Project-Silicium/Device-Binaries
- https://github.com/WOA-Kona/Drivers
