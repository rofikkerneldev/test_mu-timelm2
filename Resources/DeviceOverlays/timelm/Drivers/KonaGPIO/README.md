# Experimental timelm GPIO prerequisite

Apply only to WOA-Kona/Drivers commit
`3dcdec0bd59e3e77be92629b2ed9e095ae6e19e8` using:

```powershell
./Resources/Scripts/build_kona_drivers.ps1 -Source ./kona-source -Destination ./kona-packages -TimelmGpioFixes
```

The patch preserves unrelated pull/drive fields, selects the GPIO mux, honors
GpioClx level/edge mode and polarity, and keeps RAW_STATUS enabled while masking.
Recovery `/proc/interrupts` confirms that timelm SW42902 uses falling-edge TLMM
pin 39. The original driver forced level mode regardless of InterruptMode.

Register encodings were checked against Qualcomm TLMM behavior in
[Linux v6.15 pinctrl-msm.c](https://github.com/torvalds/linux/blob/v6.15/drivers/pinctrl/qcom/pinctrl-msm.c).
The implementation and tests are MIT licensed like the pinned Windows driver;
Linux source is not linked into the package.

ARM64 WDK compilation and host register tests pass in
[Actions run 39200526706](https://github.com/rofikkerneldev/test_mu-timelm/actions/runs/39200526706).
Host tests use ASan/UBSan. They establish field encodings and
preservation, not interrupt delivery on Windows. This package has not been
installed on the phone. The touch SPB host and ACPI contract are still required.
Existing firmware overlay manifests and the booting DSDT are unchanged.
# Windows touch bus interface

`build_kona_drivers.ps1 -TimelmTouchFixes` applies the combined
`timelm-touch.patch` to a clean pinned checkout, including the existing edge
fixes plus ordered MMIO and the private v2 `TouchBus.h` query interface. The
client must reserve GPIO 36/37 through exclusive Resource Hub connections
before selecting qup13/no-pull/2mA. Disable restores the saved low ten control
bits. This is not a general pinmux API or a completed V60 GPI transport.
This option leaves SPMI/PMIC at the pinned baseline. The separate
`-TimelmPowerFixes` option selects the experimental power patch; it is not
required for the GPIO query interface and is not enabled in the touch workflow.
Use a clean checkout: an earlier power-patched checkout is rejected unless
the power option is explicitly selected. The desktop-confirmed package uses
the edge-only GPIO patch and does not yet expose this v2 interface.
See [native touch bring-up](../../../../../Platforms/LG/timelmPkg/TOUCH-WINDOWS-NATIVE.md).

The same touch build now also exposes the separate `GUID_TIMELM_TOUCH_BUS_V3`
query interface, version 3. It is disabled unless `TouchBusGpioEnabled=1` is
present in the GPIO device's hardware key. `TimelmGpioBitbangGate` records the
effective gate read during controller preparation. The v2 ABI remains unchanged.

V3 is limited to SDA GPIO36 and SCL GPIO37. The caller must first hold both
exclusive Resource Hub **input** connections. `SetGpioMode(TRUE)` then saves
the pin configuration and output latches and selects GPIO/open drain. HIGH
means output disabled; LOW means OUT=0 with output enabled. It never drives
HIGH. `SetLines` lowers SCL before changing SDA, and changes SDA before raising
SCL. `GetLines` reads the actual input level, including external clock stretching.
Each callback holds the provider lock only for its own bounded register sequence.

V2 and V3 share one owner. The GPIO input reservations, provider target and
query interface must remain held until `SetGpioMode(FALSE)` succeeds, including
after a partial enable failure. Failed restoration retains ownership and blocks
another enable. Stop, disconnect and release reject an active owner. A caller
that cannot restore must retain its resources until reboot. Hardware removal
and suspend/resume remain unvalidated; this is an experimental fixed-pin path.

`python3 test_touch_bus.py` compiles the actual patched provider callbacks with
an ordered TLMM shim under ASan/UBSan. It checks input-level reads, no HIGH drive,
no artificial SCL pulse when holding LOW, v2/v3 exclusion, configuration restore,
partial enable failure and retained ownership on failed cleanup. These tests
do not establish successful I2C transactions or touchscreen input on hardware.
