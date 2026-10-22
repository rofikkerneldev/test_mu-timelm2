# Hardware buttons of the LG V60 (timelm)

Windows on the LG V60 has no usable power, volume up or volume down key. The
buttons exist in the hardware and are read by the PMIC, but no Windows driver
owns them, so the running system cannot be locked or shut down from the
device. This path makes exactly those three buttons usable, and it does it
with **one new driver plus a user mode agent on top of it**.

Nothing in this path changes the firmware, the SSDT, the EFI, the BCD or the
boot order. The hardware is reached through the PMIC that the existing
`SPMI.sys` driver already exposes, so the trial cannot slip into a state in
which the phone no longer boots Windows.

## Hardware ground truth

All three buttons are wired to the **PM8150 primary PMIC** (SPMI slave 0), not
to the TLMM GPIO controller. The evidence is the live device tree
(`diagnostics/recovery.dts`), the Linux runtime (`/dev/input` reports
`KEY_POWER`, `KEY_VOLUMEDOWN` and `KEY_VOLUMEUP`) and the upstream Linux
drivers (`qpnp-power-on.c`, `pinctrl-qcom-pinctrl-spmi-gpio.c`).

| Button | Register | Bit | Pressed when |
| --- | --- | --- | --- |
| Power | `0x0810` (PON RT_STS) | 0 | bit is **set** |
| Volume Down | `0x0810` (PON RT_STS) | 1 | bit is **set** |
| Volume Up | `0xC510` (PMIC GPIO6 MPP RT_STS) | 0 | bit is **clear** (active low) |

The GPIO pad base of gpio N is `0xC000 + (N - 1) * 0x100`, so gpio6 is
`0xC500 + 0x10 = 0xC510`. The interrupt numbers in the live device tree
confirm the same base (gpio1 = 0xC0 ... gpio6 = 0xC5).

## Ownership of the hardware

`TimelmButtons.sys` is the **only** access point to the button registers:

```
TimelmButtons.sys (kernel, ACPI\KONA1003)
    -> PMIC reads through GUID_SPMI_INTERFACE of SPMI.sys
    -> samples the three registers every 20 ms, two sample debounce
    -> \\.\TimelmButtons  (control device)
            |
TimelmButtonAgent.ps1 (user mode, interactive session)
    -> WAIT / GET_STATE ioctl
    -> SendInput: TAB / ENTER / Shift+F10
    -> lock the workstation / shutdown /s
```

The agent never touches the PMIC itself. The driver reads the registers
through the SPMI interface of the existing `SPMI.sys` driver, so there is no
conflict with `GPIO.sys` and no second owner of the same hardware.

The driver binds to `ACPI\KONA1003`, the PMIC node of the runtime DSDT. Only
one driver may own that hardware id, therefore the old `PMIC.inf`
(`pnputil /delete-driver oem2.inf /uninstall`) has to be removed before the
button package is installed. That driver was already failing with
Problem Code 10 on this board.

The driver samples in a work item at `PASSIVE_LEVEL`. The KMDF timer is a
DPC and only re-arms itself and hands the sample over, so the PMIC is never
read at `DISPATCH_LEVEL`. The SPMI interface is acquired at `PASSIVE_LEVEL`
as well and is retried while `SPMI.sys` is not up yet.

## Mapping

| Button | Short press | Long press |
| --- | --- | --- |
| Volume Up | `TAB` | - |
| Volume Down | `ENTER` | `Shift+F10` (800 ms) |
| Power | lock the workstation | `shutdown /s` (1500 ms), clean shutdown |

The long press is detected with the press duration that the driver reports,
so it does not depend on the accuracy of the polling loop. The power long
press is the only path that ends the session, and it uses `shutdown /s`, so
Windows still shuts down cleanly.

The agent has to run in the interactive user session: `SendInput` and
`LockWorkStation` do not work from a service in session 0.

## Control codes

| Code | Name | Direction |
| --- | --- | --- |
| `0x226000` | `GET_STATE` | out 48 byte `TIMELM_BUTTON_STATE` |
| `0x226004` | `RAW_READ` | in 16 byte `TIMELM_BUTTON_RAW_REQUEST`, out request + data (1..8 bytes) |
| `0x22A008` | `SET_MAPPING` | in 80 byte `TIMELM_BUTTON_MAPPING` |
| `0x22600C` | `GET_MAPPING` | out 80 byte `TIMELM_BUTTON_MAPPING` |
| `0x226010` | `DUMP` | same as `RAW_READ` |
| `0x226014` | `WAIT` | in 8 byte `TIMELM_BUTTON_WAIT_REQUEST`, out 48 byte `TIMELM_BUTTON_STATE` |

The mapping is runtime configurable, so the register layout can be corrected
on the board without rebuilding the driver. The raw read and the discovery
script in `Resources/Scripts/Buttons` exist for exactly that case.

## Build and provenance

The driver is developed in the `timelm_Drivers` repository (`src/Buttons`) and
is built for ARM64 by GitHub Actions only, because the build PC has no WDK.
The green run of the `Timelm ARM64 baseline` workflow produces the package
`Buttons` with the test signed `TimelmButtons.sys`, the catalog and the INF.
The `mu-timelm` job `windows-buttons` rebuilds the same package from a pinned
driver revision and uploads it as the artifact `timelm-native-buttons`; the
revision, the configuration and the hashes of every file are part of the
artifact (`source.json`, `sha256.json`).

The CI build uses `/W4 /WX`, so every conversion in the driver is explicit.

## Controlled trial

- `Stage-TimelmButtonsTrial.ps1` copies the verified package and the trial
  scripts from the artifact onto the Windows partition of the identified
  phone. It refuses any disk that is not the V60 USB disk (serial `8509C01F`),
  it checks the partition geometry and the installation marker, and it never
  writes to the ESP, the BCD or the boot order.
- `Run-TimelmButtonsTrial.ps1` runs on the phone in the interactive session.
  It removes the driver that currently owns `ACPI\KONA1003`, installs
  `TimelmButtons.inf`, verifies that the selected INF of the device is byte
  for byte the INF of the package, starts the agent, samples the button state
  into `button-state.jsonl` and always shuts the phone down cleanly at the
  end. Every failure is written to `trial-error.json`.

The acceptance order is: driver started, node `ACPI\KONA1003` without a
problem code, `\\.\TimelmButtons` reachable, state changes on a press, then
the input reaction (TAB, ENTER, Shift+F10, lock, clean shutdown).

## Trial result

The trial passed completely on the phone on 2026-10-22.  The receipts of the
attempt are in `receipts/buttons-attempt2` on the build PC.

| Check | Result |
| --- | --- |
| Node | `ACPI\KONA1003\0`, "Timelm Volume and Power Buttons", status OK, problem code 0, service `TimelmButtons` |
| Selected INF | `oem154.inf`, sha256 `350C942F34D29C8D82A56AB301EC3DE037511E82D29313565F7110B3C50D0CE4`, identical with the INF of the package |
| Service | `TimelmButtons`, state Running, start mode Manual |
| Control device | `\\.\TimelmButtons` open, `ready` = 1 in every sample |
| State trace | 2314 samples in 120 s, change counter 0 -> 288, all three buttons seen |
| Agent | TAB, ENTER, Shift+F10 after 821 ms, lock after a short power press, the shutdown path after 1517 ms |
| Shutdown | `shutdown /s` requested, the mass storage mode was reached again |

The shutdown action was disabled during the attempt, the trial ends with one
controlled shutdown of its own.  The first attempt failed before the agent
was started: the driver of a device instance is stored in the instance key
of the enumeration tree, not in the key of the hardware id, and a hashtable
literal that is written directly behind a parameter list becomes a string.
Both are fixed, the receipts of the failed attempt are kept in
`receipts/buttons-attempt1`.

## Risks

* Windows itself may react to the power key through the ACPI button driver,
  which can produce a shutdown prompt in addition to the action of the
  agent. The trial runs the agent with the shutdown action disabled and
  ends with one controlled `shutdown /s`.
* The button package replaces the PMIC driver on that node. If the button
  driver does not start, the node stays without a working driver, which is
  the state the board was in before this path.
* The PMIC is read through `SPMI.sys`. While that driver is not running the
  button driver stays in the "not ready" state and retries every 500 ms.
