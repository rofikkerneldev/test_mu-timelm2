# Hardware buttons of the LG V60 (timelm)

Windows on the LG V60 has no usable power, volume up, volume down or assist
key. The buttons exist in the hardware and are read by the PMIC, but no
Windows driver owns them, so the running system cannot be locked, woken or
shut down from the device. This path makes exactly those four buttons usable,
and it does it with **one new driver plus a user mode agent on top of it**.

Nothing in this path changes the firmware, the SSDT, the EFI, the BCD or the
boot order. The hardware is reached through the PMIC that the existing
`SPMI.sys` driver already exposes, so the trial cannot slip into a state in
which the phone no longer boots Windows.

## Hardware ground truth

All four buttons are wired to the **PM8150 primary PMIC** (SPMI slave 0), not
to the TLMM GPIO controller. The evidence is the live device tree
(`diagnostics/recovery.dts`), the Linux runtime (`/dev/input` reports
`KEY_POWER`, `KEY_VOLUMEDOWN`, `KEY_VOLUMEUP` and `KEY_ASSIST`) and the
upstream Linux drivers (`qpnp-power-on.c`, `pinctrl-qcom-pinctrl-spmi-gpio.c`).

| Button | Register | Bit | Pressed when |
| --- | --- | --- | --- |
| Power | `0x0810` (PON RT_STS) | 0 | bit is **set** |
| Volume Down | `0x0810` (PON RT_STS) | 1 | bit is **set** |
| Volume Up | `0xC510` (PMIC GPIO6 MPP RT_STS) | 0 | bit is **clear** (active low) |
| Assist | `0xC010` (PMIC GPIO1 MPP RT_STS) | 0 | bit is **clear** (active low) |

The GPIO pad base of gpio N is `0xC000 + (N - 1) * 0x100`, so gpio1 is
`0xC000 + 0x10 = 0xC010` and gpio6 is `0xC500 + 0x10 = 0xC510`. The interrupt
numbers in the live device tree confirm the same base (gpio1 = 0xC0 ...
gpio6 = 0xC5).

The assist key is the `hot1_key` node of the live device tree
(`gpios = <0x661 0x01 0x01>`, `linux,code = <0x179>`, flags 0x01 = active
low). It is the same gpio1 that the kernel uses for `KEY_ASSIST`, so the
register address above is not a guess but the address the Linux driver of the
board uses.

## Ownership of the hardware

`TimelmButtons.sys` is the **only** access point to the button registers:

```
TimelmButtons.sys (kernel, ACPI\KONA1003)
    -> PMIC reads through GUID_SPMI_INTERFACE of SPMI.sys
    -> samples the four registers every 20 ms, two sample debounce
    -> \\.\TimelmButtons  (control device)
            |
TimelmButtonAgent.ps1 (user mode, interactive session)
    -> WAIT / GET_STATE ioctl
    -> SendInput: TAB / ENTER / Shift+F10 / Win
    -> lock the workstation / wake the display / shutdown /s
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
| Power | lock the workstation, wake the display if the session is locked | `shutdown /s` (1500 ms), clean shutdown |
| Assist | start the program of `assist-target.txt` (or the start menu) | - |

The long press is detected with the press duration that the driver reports,
so it does not depend on the accuracy of the polling loop. The power long
press is the only path that ends the session, and it uses `shutdown /s`, so
Windows still shuts down cleanly.

The agent has to run in the interactive user session: `SendInput` and
`LockWorkStation` do not work from a service in session 0.

### Who answers a press

Windows has no native counterpart for the lock, so the power key always
belongs to the agent. The two volume keys do have one, so the HID face of
the driver can take them over. Three modes are possible:

| Mode | Volume keys | Power key | Assist key |
| --- | --- | --- | --- |
| `Agent` | TAB / ENTER / Shift+F10 through the agent | agent | agent |
| `Hid` | the volume flyout of Windows, through the HID face of the driver | agent (lock or wake) | agent |
| `Both` | both at once, only good for a test | both at once | agent |

The mode is written into the driver, so it can be changed while Windows runs
(`Set-TimelmButtonMode.ps1`).

### The actions of the agent

| Number | Name | Meaning |
| --- | --- | --- |
| 0 | none | - |
| 1 | Tab | `TAB` |
| 2 | Enter | `ENTER` |
| 3 | Shift+F10 | context menu |
| 4 | Lock | lock the workstation |
| 5 | Shutdown | `shutdown /s` |
| 6 | Wake | turn the display on again |
| 7 | Lock or wake | lock when the session is open, wake when it is locked |
| 8 | Assist target | start the program of `%ProgramData%\Timelm\assist-target.txt` |
| 9 | Start menu | the Windows key |

Windows has no wake button of its own, so the wake is done by the agent: it
calls `SetThreadExecutionState(ES_SYSTEM_REQUIRED | ES_DISPLAY_REQUIRED)`,
sends `WM_SYSCOMMAND / SC_MONITORPOWER` to all windows and nudges the mouse.
Whether the session is locked is read from the name of the input desktop
(`OpenInputDesktop` plus `GetUserObjectInformation(UOI_NAME)`); on a locked
session the name is `Winlogon`.

## Control codes

| Code | Name | Direction |
| --- | --- | --- |
| `0x226000` | `GET_STATE` | out 64 byte `TIMELM_BUTTON_STATE` |
| `0x226004` | `RAW_READ` | in 16 byte `TIMELM_BUTTON_RAW_REQUEST`, out request + data (1..8 bytes) |
| `0x22A008` | `SET_MAPPING` | in 200 byte `TIMELM_BUTTON_MAPPING` |
| `0x22600C` | `GET_MAPPING` | out 200 byte `TIMELM_BUTTON_MAPPING` |
| `0x226010` | `DUMP` | same as `RAW_READ` |
| `0x226014` | `WAIT` | in 8 byte `TIMELM_BUTTON_WAIT_REQUEST`, out 64 byte `TIMELM_BUTTON_STATE` |

The mapping is runtime configurable, so the register layout can be corrected
on the board without rebuilding the driver. The raw read and the discovery
script in `Resources/Scripts/Buttons` exist for exactly that case.

### The versions of the structures

The layout of the structures is **append only**, so the first bytes of the
current version carry the same values as the older versions:

| Version | `TIMELM_BUTTON_STATE` | `TIMELM_BUTTON_MAPPING` | Buttons |
| --- | --- | --- | --- |
| 1 | 48 byte | 80 byte | power, volume up, volume down |
| 2 | 56 byte | 152 byte | power, volume up, volume down |
| 3 | 64 byte | 200 byte | power, volume up, volume down, assist |

The fourth button is appended at the end of the mapping (the source at byte
152, the action at byte 176) and at the end of the state (the press count at
byte 56, the hold time at byte 60). A driver of an older version therefore
still works with the scripts of the current version, and a driver of the
current version still reads the mapping of an older version. The scripts
read the version field and the length of the answer, so they work with every
driver that was built so far.

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

### Attempt 2, mode Agent (2026-10-22)

The trial passed completely on the phone.  The receipts of the attempt are in
`receipts/buttons-attempt2` on the build PC.

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

### Attempt 3, mode Hid (2026-10-22)

The HID face of the driver works, the receipts are in `receipts/buttons-hid`.

| Check | Result |
| --- | --- |
| Mode | `Hid`, the volume keys are answered by the HID face, the power key stays with the agent |
| Volume | the flyout of Windows opens, the volume follows the button |
| Power short | the session is locked, the display stays off |

The driver of this attempt is the revision `4601ad6`, it has the HID face
but not yet the fourth button and not yet the wake.

## What is still open

* The **assist key** (fourth button, `0xC010`) and the **wake** of the
  display are implemented in the driver revision
  `7b35cf5d1a6760e62ff5ad9600845dc110515b9f` and in the scripts, they are
  not on the phone yet.  The next trial has to prove the assist key and the
  wake.
* The **capture of the touch chip** in the recovery came out empty
  (`captures/touch/f-touch`): the chip is quiet in the recovery, so the
  capture has to run in Android, not in the recovery.
* Windows does not react to the power key with a wake, the agent has to do
  it.  The wake is proven by the name of the input desktop, not yet by a
  measurement on the phone.

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
