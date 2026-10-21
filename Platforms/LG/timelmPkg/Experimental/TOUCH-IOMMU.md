# V60 SW42902 ACPI and translated DMA integration

This is an experimental source integration. It is not a claim that Windows
touch or Windows IOMMU operation has passed on the phone. The normal timelm
ACPI table list and boot image are not changed by this profile.

## Hardware contract

| Function | V60 resource | Evidence |
| --- | --- | --- |
| Touch controller | SW42902, 7-bit I2C address 0x28 | Recovery identity read, product B3W68TIM |
| Serial engine | QUPv3 SE13, wrapper1 local SE5, A94000/4000 | Captured Recovery DT and working transactions |
| Bus pins | GPIO36/37, QUP function; reset38, IRQ39 | Captured DT and GPIO state |
| Touch enables | GPIO67 VCL, GPIO68 VDD | Captured DT; existing board lifecycle |
| GPI engine | GPI1 A00000/70000, GPII0, EE offset6000 | Captured DT / GPI transport source |
| GPI interrupt | GSIV311, level high | DT SPI279 + 32 |
| DMA stream | apps-SMMU stream0x56, mask0 | GPI node iommus property |
| SMMU | 15000000/100000, architectural v2 model | DT qcom,qsmmu-v500 |
| SMMU globals | GSIV96/97, level | Captured DT |
| Context banks | ID1 6000004a -> 74 | Pre-Windows read-only hardware snapshot |
| Context IRQs | First74 of96 DT entries, firstGSIV129 | DT plus Linux arm-smmu truncation rule |
| HID coordinates | 1080x2460 | Panel/touch DT and Windows display API |

`TimelmTouchDma.json` records the DT and hardware snapshot SHA256 values.
The generic Kona/Alioth IORT has128 context IRQs starting at135, with different
trigger flags. It is not the V60 input for this generator. The selected generic
v2 SMMU model and Windows HAL handling of Qualcomm's v500 remain hardware tests.

## What was learned from the supplied Kernel folder and G8 port

The user supplied `Kernel/touch_42000` and `Kernel/touch_sw42902`. The latter's
`touch_sw42902.h` lines33-85 define a12-byte report header, a24-byte pen block,
then10 finger records of12 bytes. The first V60 finger is byte36; the G8's
SW42000 finger array starts at12. C bitfields are decoded explicitly as
little-endian words in the Windows port rather than relying on compiler layout.
`TouchKernelEvidence.json` records hashes of the four audited kernel C/header
files and the pinned G8 Windows reference commit.

`touch_sw42902.c` implements register read/write framing, normal initialization
and `sw42902_tc_driving`. The basic Windows path agrees with those semantics:
register600 report read156 bytes, disable unused SPI through FE4, device control
C00, interrupt control C01, STOP at C03=4 with30ms delay, then normal finger
scan C03=8303 when active pen is disabled. Scan activation occurs after Windows
arms the interrupt. No firmware update or Android production-test path is used.

The [Project-Aloha SW42000 Windows port](https://github.com/Project-Aloha/sw42000-touch/tree/98ef6043ff3d2c6ec388a492e27aeb1639e98de5)
uses Resource Hub/SPB to communicate with an existing I2C controller. Its
`driver/vhidmini.c` handles GPIO interrupt -> SPB write/read -> HID reports.
It does not supply the V60 GENI/GPI/SMMU implementation. The V60 client already
contains the SW42902 packet and basic tap/swipe adaptation; this change supplies
the experimental translated host path underneath that client.

## Paired tables and driver settings

`TouchIommuWindows.asl` creates `\\_SB.TI2C` (TIML0001) and `TSCV` (LGSW4290),
with explicit `_DEP` on the GPIO provider and I2C host. TWEN defaults to zero.
Its TBCF contract is54420301: four MMIO resources for GENI/GCC/GPI and no
driver-owned SMMU register page. The old BYPASS profile has a different contract
54420201 and five MMIO resources; interchanging them is rejected.

The generated IORT named component uses canonical path `\\_SB_.TI2C`, one input
ID0, and one output SID56. IORT NumIds=0 encodes exactly one ID, not zero IDs;
the wildcard/single-mapping flag is clear. The Windows ACPI creation config uses
InputMappingBase=0 and MappingsCount=1. Stream56 is not the I2C peripheral address,
not the SE number, and not a physical or logical buffer address.

The host INF defaults NativeBoardInitEnabled, NativeGpiEnabled and
WindowsIommuEnabled to0. All three would need1 for a controlled hardware trial,
together with the matching tables and the GPIO private-v2 pinmux interface.
The booting GPIO package lacks that private interface. Build its additive
touch overlay with `build_kona_drivers.ps1 -TimelmTouchFixes`; SPMI/PMIC power
experiments now require a separate `-TimelmPowerFixes` switch.

## DMA lifetime

`iommu_windows.c` requests the public Windows IOMMU v2 interface, validates one
input mapping on the actual ACPI PDO, creates its own translated domain and
attaches only that device. It maps an uncached8KB allocation into an explicit
IOVA10000000 within its new empty domain. GPI ring and payload addresses are
derived from that mapped IOVA; they are never CPU virtual addresses or borrowed
Recovery addresses. The domain does not use a HAL logical allocator, so the
explicit IOVA is required by MapLogicalRangeEx.

The host acquires the domain and mapping in the pre-power check before opening
touch output GPIOs. A missing IORT, unsupported API, wrong input mapping,
attachment failure or mapping failure prevents GPI startup. There is no
automatic passthrough fallback and no SMMU register write in this backend.

After GPI channels and event ring stop, cleanup detaches its own attachment,
unmaps the IOVA, flushes, deletes the domain/device and frees the buffer. A
failed stop/detach/unmap/flush/delete retains memory and state until reboot.
An unsuccessful AttachDeviceEx never causes detachment of another owner.
Registry diagnostics record TimelmDmaMode, TimelmIommuStage/Status/Ready/Retained
and the GPI logical address. Idle, suspend/resume and restart recovery are not
hardware validated.

## Shared SMMU handoff is still unresolved

The actual DT has `qcom,skip-init`. Linux uses that option to preserve existing
stream/context-bank configuration. Existing streams include UFS/display-related
mappings. An IORT describes an entire SMMU to Windows; disabling TI2C with _STA
does **not** prevent OS initialization of the SMMU node. IORT itself cannot
encode the Qualcomm skip-init behavior.

Consequently, the generator emits `TimelmTouchIort.candidate.aml` and a manifest
with deployable=false. It does not copy either table into the normal firmware,
flash boot_a, change BCD or install drivers. A complete firmware handoff review
and controlled one-shot hardware trial must establish that the Windows HAL can
manage the advertised SMMU without disrupting existing storage/display streams.
Passing the source tests below does not answer that question.

## Reproduce validation

From the repository root:

```sh
python3 Resources/Scripts/build_timelm_touch_iort.py
python3 Resources/Scripts/tests/test_timelm_touch_iort.py
iasl -ve -p Build/TouchIommu/TouchIommuWindows Platforms/LG/timelmPkg/Experimental/TouchIommuWindows.asl
iasl -d Build/TouchIommu/TimelmTouchIort.candidate.aml
gcc -std=c11 -Wall -Wextra -Werror -fsanitize=address,undefined -g \
  -IGPLDrivers/Windows/KonaGeniI2c/tests/iommu_shim \
  GPLDrivers/Windows/KonaGeniI2c/tests/iommu_test.c \
  GPLDrivers/Windows/KonaGeniI2c/iommu_windows.c -o /tmp/touch-iommu-test
/tmp/touch-iommu-test
```

The host test executes the production backend with API doubles, including each
acquisition/cleanup failure, unknown mappings, missing callbacks, a different
IOVA from physical memory, repeated acquisition and unsafe teardown retention.
It cannot validate the WDK ABI or hardware; the ARM64 WDK job compiles against
the real headers and links the public kernel imports. The IORT tests parse
the binary independently to verify lengths, offsets, checksum, IRQ counts,
path and the single0->56 mapping. ACPICA also disassembles the resulting table.

## Primary references

- [Microsoft IOMMU interface v2](https://learn.microsoft.com/windows-hardware/drivers/ddi/wdm/ns-wdm-dma_iommu_interface_v2)
- [IoGetIommuInterfaceEx and remapping opt-in](https://learn.microsoft.com/windows-hardware/drivers/ddi/wdm/nf-wdm-iogetiommuinterfaceex)
- [ARM64 ACPI device creation](https://learn.microsoft.com/windows-hardware/drivers/ddi/wdm/nc-wdm-iommu_device_create)
- [ACPI input mapping config](https://learn.microsoft.com/windows-hardware/drivers/ddi/wdm/ns-wdm-iommu_device_creation_configuration_acpi)
- [MapLogicalRangeEx and explicit IOVA contract](https://learn.microsoft.com/windows-hardware/drivers/ddi/wdm/nc-wdm-iommu_map_logical_range_ex)
- [Device attachment ownership](https://learn.microsoft.com/windows-hardware/drivers/ddi/wdm/nc-wdm-iommu_domain_attach_device_ex)
- [Linux arm-smmu, skip-init and context IRQ handling](https://android.googlesource.com/kernel/msm/+/refs/heads/android-msm-coral-4.14-android10/drivers/iommu/arm-smmu.c)
- [Arm IORT specification](https://developer.arm.com/documentation/den0049/)
- Repository `Mu_Basecore/MdePkg/Include/IndustryStandard/IoRemappingTable.h`
  for the packed table layout and level/edge flag encoding.
