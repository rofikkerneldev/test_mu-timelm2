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
