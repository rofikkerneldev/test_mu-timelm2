# TimelmButtons - hardware buttons of the LG V60 (timelm)

This folder contains the user mode part of the button support.  The kernel
part lives in the `timelm_Drivers` repository (`src/Buttons`, driver
`TimelmButtons.sys`).

## Hardware ground truth

All four buttons of the LG V60 are wired to the **PM8150 primary PMIC**
(SPMI slave 0), not to the TLMM GPIO controller.  This is confirmed by three
independent sources:

| Source | Evidence |
| --- | --- |
| Live device tree (`diagnostics/recovery.dts`) | `qcom,power-on@800` in `pm8150@0`, `gpio_keys.vol_up` on `pm8150_gpios pinctrl@c000` gpio6, `gpio_keys.hot1_key` on gpio1 with `linux,code = <0x179>`, `pon_1` = 0x00 (KPDPWR), `pon_2` = 0x01 (RESIN) |
| Linux runtime (`/dev/input`) | `qpnp_pon` reports `KEY_POWER` + `KEY_VOLUMEDOWN`, `gpio-keys` reports `KEY_VOLUMEUP` and `KEY_ASSIST` |
| Upstream Linux | `drivers/input/misc/qpnp-power-on.c` (`QPNP_PON_RT_STS = base + 0x10`), `drivers/pinctrl/qcom/pinctrl-spmi-gpio.c` (`PMIC_GPIO_ADDRESS_RANGE 0x100`, `PMIC_MPP_REG_RT_STS 0x10`) |

Resulting register map (slave 0):

| Button | Register | Bit | Pressed when |
| --- | --- | --- | --- |
| Power | `0x0810` (PON RT_STS) | 0 | bit is **set** |
| Volume Down | `0x0810` (PON RT_STS) | 1 | bit is **set** |
| Volume Up | `0xC510` (PMIC GPIO6 MPP RT_STS) | 0 | bit is **clear** (active low) |
| Assist | `0xC010` (PMIC GPIO1 MPP RT_STS) | 0 | bit is **clear** (active low) |

The GPIO pad base of gpio N is `0xC000 + (N - 1) * 0x100`; the live device
tree confirms this through the interrupt numbers (gpio N -> `0xC0 + (N - 1)`,
gpio1 = 0xC0 ... gpio6 = 0xC5).

## Architecture

```
TimelmButtons.sys (kernel, ACPI\KONA1003)
    -> reads the PMIC through GUID_SPMI_INTERFACE of SPMI.sys
    -> samples the four registers every 20 ms, two sample debounce
    -> \\.\TimelmButtons  (control device)
            |
TimelmButtonAgent.ps1 (user mode, interactive session)
    -> WAIT / GET_STATE ioctl
    -> SendInput: TAB / ENTER / Shift+F10 / Win
    -> lock / wake the display / shutdown /s
```

The driver is the **only** access point to the button hardware, so the agent
never touches the PMIC itself.

## Control codes

| Code | Name | Direction |
| --- | --- | --- |
| `0x226000` | `GET_STATE` | out 64 byte `TIMELM_BUTTON_STATE` |
| `0x226004` | `RAW_READ` | in 16 byte `TIMELM_BUTTON_RAW_REQUEST`, out request + data (1..8 bytes) |
| `0x22A008` | `SET_MAPPING` | in 200 byte `TIMELM_BUTTON_MAPPING` |
| `0x22600C` | `GET_MAPPING` | out 200 byte `TIMELM_BUTTON_MAPPING` |
| `0x226010` | `DUMP` | same as `RAW_READ` |
| `0x226014` | `WAIT` | in 8 byte `TIMELM_BUTTON_WAIT_REQUEST`, out 64 byte `TIMELM_BUTTON_STATE` |

The structures are defined in `timelm_Drivers/src/Include/TimelmButtons.h`
and mirrored by the helpers in `TimelmButtonsCommon.ps1`.

The layout is append only, so the scripts work with every driver that was
built so far:

| Version | State | Mapping | Buttons |
| --- | --- | --- | --- |
| 1 | 48 byte | 80 byte | power, volume up, volume down |
| 2 | 56 byte | 152 byte | power, volume up, volume down |
| 3 | 64 byte | 200 byte | power, volume up, volume down, assist |

`Get-TimelmButtonMappingVersion` reads the version from the driver, so the
scripts write a mapping that the installed driver understands.

## Button mapping

| Button | Short press | Long press |
| --- | --- | --- |
| Volume Up | `TAB` | - |
| Volume Down | `ENTER` | `Shift+F10` (800 ms) |
| Power | lock the workstation, wake the display if the session is locked | `shutdown /s` (1500 ms), clean shutdown |
| Assist | start the program of `%ProgramData%\Timelm\assist-target.txt` | - |

The long press is detected with the press duration that the driver reports,
so it does not depend on the accuracy of the polling loop.

Windows has no native lock, so the power key always belongs to the agent.
The volume keys do have a native counterpart, the HID face of the driver can
take them over in the mode `Hid`.

## Usage

```powershell
# one time, from the desktop session of the phone
powershell -ExecutionPolicy Bypass -File Install-TimelmButtonAgent.ps1

# run the agent in the foreground (log to the console)
powershell -ExecutionPolicy Bypass -File TimelmButtonAgent.ps1

# verify the state without touching the keyboard
powershell -ExecutionPolicy Bypass -File TimelmButtonAgent.ps1 -DryRun
```

## Trial on the phone

The trial is a Windows side trial, it does not touch the ESP, the BCD or the
boot order.  The driver package comes from a green CI run of the
`timelm_Drivers` repository, the provenance of the package is written into
`source.json` and `sha256.json` of the artifact.

```powershell
# PC: stage the bundle from the CI artifact "timelm-native-buttons"
powershell -ExecutionPolicy Bypass -File Stage-TimelmButtonsTrial.ps1 `
    -Artifact C:\artifacts\timelm-native-buttons -Output C:\receipts\buttons

# phone: run the trial in the interactive session (elevated)
powershell -ExecutionPolicy Bypass -File E:\TimelmTools\TimelmButtonsTrial\Run-TimelmButtonsTrial.ps1 -Seconds 120
```

The trial removes the driver that currently owns `ACPI\KONA1003` (`PMIC.inf`),
installs `TimelmButtons.inf`, verifies that the selected INF of the device is
byte for byte the INF of the package, starts the agent and samples the button
state into `E:\TimelmLogs\TimelmButtonsTrial\button-state.jsonl`.  Every
failure is written to `trial-error.json`, and the phone always shuts down
cleanly at the end of the attempt, so that the mass storage mode can be
reached again for the log collection.

`Stage-TimelmButtonsTrial.ps1 -Arm` writes a Startup entry as well, so that
the trial starts by itself after the next boot.

### Result of the trial on the phone (2026-10-22)

The second attempt passed completely, the receipts are in
`receipts/buttons-attempt2` on the build PC.

| Check | Result |
| --- | --- |
| Node | `ACPI\KONA1003\0`, name "Timelm Volume and Power Buttons", status **OK**, problem code **0**, service `TimelmButtons` |
| Selected INF | `oem154.inf`, sha256 `350C942F34D29C8D82A56AB301EC3DE037511E82D29313565F7110B3C50D0CE4`, byte for byte the INF of the package |
| Service | `TimelmButtons`, state **Running**, start mode Manual |
| Control device | `\\.\TimelmButtons` opened, `ready` = 1 in every one of the 2314 samples |
| State trace | 2314 samples in 120 s, change counter 0 -> 288, all three buttons seen (bitmask 1, 2, 4 and 7) |
| Agent | Volume Up -> `TAB`, Volume Down -> `ENTER`, Volume Down > 800 ms -> `Shift+F10`, Power short -> lock, Power > 1500 ms -> the shutdown path |
| Shutdown | `shutdown /s` requested, the phone reached the mass storage mode again |

The shutdown action itself was disabled during the attempt
(`-DisableShutdown`), so the trial could not end in the middle of the test.
The long press of the power button was detected at 1517 ms to 1522 ms, the
long press of volume down at 821 ms to 826 ms.

Two defects of the first attempt are fixed in the trial script: the driver of
a device instance is stored in the **instance** key of the enumeration tree
(`Enum\ACPI\KONA1003\0`), not in the key of the hardware id, and a hashtable
literal that is written directly behind the parameter list of a function is
turned into a string by the argument parser.  Every receipt is built in a
variable first, and the collection on the PC removes the receipts of an
earlier attempt before it copies the new ones.

### Result of the third attempt, mode Hid (2026-10-22)

The HID face of the driver works, the receipts are in `receipts/buttons-hid`:

| Check | Result |
| --- | --- |
| Mode | `Hid`, the volume keys are answered by the HID face, the power key stays with the agent |
| Volume | the flyout of Windows opens, the volume follows the button |
| Power short | the session is locked, the display stays off |

The driver of that attempt is the revision `4601ad6`, it has the HID face
but not yet the fourth button and not yet the wake.

### What the next attempt has to prove

* the **assist key** (fourth button, PMIC gpio1 / `0xC010`) reaches the
  agent and starts the program of `assist-target.txt`,
* the **power key wakes** the display again when the session is locked,
* the wake does not trigger the power menu of Windows.

The driver revision for that attempt is
`7b35cf5d1a6760e62ff5ad9600845dc110515b9f`.

## The assist key

The assist key is the way to give a button of the phone a function of your
own.  The agent reads the target from a text file, so the function can be
changed without touching the agent:

```
%ProgramData%\Timelm\assist-target.txt
```

The content is the command line that is started with the shell, for example
`notepad.exe`.  An empty or missing file means that the agent only writes a
note into its log.

```powershell
# PC, from the desktop session of the phone
powershell -ExecutionPolicy Bypass -File Set-TimelmButtonMode.ps1 `
    -Mode Agent -AssistAction LaunchTarget
```

## Discovery

If the default mapping does not react, the real register layout can be
brute forced without rebuilding the driver:

```powershell
# PON block, hold the power button during the second phase
powershell -ExecutionPolicy Bypass -File Discover-TimelmButtons.ps1 -Button Power -Start 0x800 -End 0x8FF

# PMIC GPIO block, hold volume up
powershell -ExecutionPolicy Bypass -File Discover-TimelmButtons.ps1 -Button VolumeUp -Start 0xC000 -End 0xCAFF
```

The script prints every register byte that changed while the button was
held.  The result can be written back with `SET_MAPPING`
(`ConvertTo-TimelmButtonMapping` in `TimelmButtonsCommon.ps1`).

## Notes and risks

* `TimelmButtons.sys` binds to `ACPI\KONA1003`, the PMIC node of the runtime
  DSDT.  Only one driver may own that hardware id, so `PMIC.inf` has to be
  removed first (`pnputil /delete-driver oem2.inf /uninstall`).
* The agent has to run in the interactive user session, `SendInput` and
  `LockWorkStation` do not work from a service.
* Windows itself may also react to the power key through the ACPI button
  driver, which can produce a shutdown prompt in addition to the action of
  the agent.
* The PMIC is read through `SPMI.sys`; if that driver is not running the
  driver stays in the "not ready" state and retries every 500 ms.
