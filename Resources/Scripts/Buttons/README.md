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
| Linux runtime (`/dev/input`) | `qpnp_pon` reports `KEY_POWER` + `KEY_VOLUMEDOWN`, `gpio-keys` reports `KEY_VOLUMEUP` (0x73) and `KEY_TV` (0x179) |
| ROM key layout | `configs/keylayout/gpio-keys.kl` of the ROM: `key 377 ASSIST`, so Android names the raw code of the kernel ASSIST |
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

The pad of gpio1 has no pull up in the pinctrl of the `gpio-keys` node, the
pull up is in `key_home_default`, the pinctrl of the `qcom,qbt_handler` node
that uses the same pin as `qcom,finger-detect-gpio`. In the recovery that
driver does not run, the contact of the assist key bounces with a period of
about 130 ms. The agent answers a press only after the button was quiet for
the quiet time (`-QuietMillis`, 500 ms by default).

## Architecture

```
TimelmButtons.sys (kernel, ACPI\KONA1003)
    -> reads the PMIC through GUID_SPMI_INTERFACE of SPMI.sys
    -> samples the four registers every 20 ms, two sample debounce
    -> \\.\TimelmButtons  (control device)
            |
TimelmButtonAgent.ps1 (user mode, interactive session)
    -> WAIT / GET_STATE ioctl
    -> SendInput: TAB / ENTER / Shift+F10 / Win / Alt+F4
    -> display off and on / unlock the lock screen / shutdown /s
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
| Volume Up | `UP` (the cursor moves up) | `RIGHT` (800 ms) |
| Volume Down | `DOWN` (the cursor moves down) | `LEFT` (800 ms) |
| Power | the Windows key, the start menu opens | `shutdown /s` (1500 ms), clean shutdown |
| Assist | `ENTER` | `TAB` (800 ms) |

The long press is detected with the press duration that the driver reports,
so it does not depend on the accuracy of the polling loop.

Every action of the mapping is a parameter, the mapping of the trial is
written into the driver before the agent starts and it is read back into
`button-mode.json` of the receipt.

The **power key does not lock the session**.  A lock without a way to open
it again is a trap on this phone: the touch screen does not work and there
is no keyboard, so the lock screen would be the end of the session.  The
eighth attempt showed exactly that.

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
| 9 | Start menu | the Windows key, the start menu of Windows opens |
| 10 | Display toggle | the display of the phone goes off, the next press brings it back |
| 11 | Unlock | open the lock screen of a locked session |
| 12 | Close | `Alt+F4`, close the window that has the focus |
| 13 | Up | the cursor moves up |
| 14 | Right | the cursor moves right |
| 15 | Down | the cursor moves down |
| 16 | Left | the cursor moves left |

The driver does **not** check the numbers, it only carries them from the
mapping of the tool into the agent, so the new actions need no new build of
the driver.

The display is turned off with `WM_SYSCOMMAND / SC_MONITORPOWER` and the
value 0, it is turned on again with the value 1 and a small movement of the
mouse.  The message is posted and not sent, a window that does not answer
would block the agent for ever.  The agent holds
`ES_CONTINUOUS | ES_SYSTEM_REQUIRED | ES_DISPLAY_REQUIRED` while it runs, so
the idle timer of Windows does not turn the display off and the state of the
display is only changed by the power key of the phone.

The lock screen of a locked session lives on the secure desktop of
`winlogon.exe`.  A process of the session cannot open that desktop (the
error 5 "the access was denied" and the error 170 "the desktop was in
use").  The unlock works with the identity of `winlogon.exe` instead: the
token of that process is copied, the agent works as that identity for a
moment, opens the `Winlogon` desktop and sends the return key there.  The
account of the phone has **no password** (`AutoAdminLogon = 1`,
`DefaultUserName = Administrator` and no `DefaultPassword`), so the return
key signs the user in.

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

The two scripts on the PC side are run with `pwsh`, the shell of the CI.  The
Windows PowerShell of the build PC has no `Get-FileHash`, and the scripts
need it for the hashes of the receipts.

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File Stage-TimelmButtonsTrial.ps1 `
    -Artifact C:\artifacts\timelm-native-buttons -Output C:\receipts\buttons
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

That write needs the write right on the Startup folder of the phone, and the
folder belongs to the administrators of the phone.  Once Windows of the phone
has applied its own rights to the ProgramData, the build PC has no write
right there and the staging fails with "the Startup folder of the phone is
not writable from the build PC".

The phone has no working touchscreen and Windows does not see the USB OTG, so
there is no way to start the trial by hand.  The staging has a second way to
arm it: `-ArmTask` writes a task of the task scheduler into
`C:\Windows\System32\Tasks\TimelmButtonsTrial`.  The scheduler reads the
tasks of that folder when its service starts, so the task runs at the logon
of the administrator and the trial starts by itself.  The trial removes the
task at the end of the attempt, so it does not run again at the next logon.

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File Stage-TimelmButtonsTrial.ps1 `
    -Artifact C:\artifacts\timelm-native-buttons -Output C:\receipts\buttons `
    -ButtonMode Agent -AssistAction StartMenu -Seconds 240 -ArmTask
```

The receipt of the staging carries the way of the arming in `arm_method`,
the path of the task in `task_path` and its hash in `task_sha256`.

The target of the assist key is written by the trial itself, into
`C:\ProgramData\Timelm\assist-target.txt`.  The build PC has no write right
on that folder either, so it only passes the value on to the phone.

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

### Result of the fourth attempt, mode Agent, the assist key (2026-10-22)

The assist key works, the receipts are in `receipts/buttons-attempt4`:

| Check | Result |
| --- | --- |
| Driver | revision `7b35cf5d1a6760e62ff5ad9600845dc110515b9f`, the fourth button is in the mapping |
| Node | `ACPI\KONA1003\0`, status **OK**, problem code **0**, service `TimelmButtons` **Running** |
| Mapping | version 3, mode `Agent`, assist action `StartMenu` |
| Assist | 16 short presses, 16 start menus, no double answer |
| Volume | 10 x `TAB`, 11 x `ENTER`, 2 x `Shift+F10` |
| Power | 9 short presses, 9 x "action lock returned True", 0 wakes |
| Shutdown | `shutdown /s` after 240 s, the phone reached the mass storage mode again |

The wake is the one part that is not proven.  The agent of that revision read
the state of the lock from the name of the input desktop and treated a name
that cannot be read as "not locked", so every press after a lock was
answered with another lock.

### What the next attempt has to prove

* the **power key wakes** the display again when the session is locked,
* the wake does not trigger the power menu of Windows.

The power key is a toggle now: the press after a lock is a wake.  The name of
the input desktop is only the evidence for the first press and for the log.
The wake sends the display on and moves a short lived helper to the input
desktop of the session, which is the secure desktop of a locked session.

The driver revision for that attempt is
`7b35cf5d1a6760e62ff5ad9600845dc110515b9f`.

### Result of the seventh attempt (2026-10-22)

The trial passed completely on the phone, the receipts are in
`receipts/buttons-attempt7`:

```
2026-10-22 22.18.52 the trial starts, user TIMELM-V60\Administrator, session 1, elevated True
2026-10-22 22.19.29 agent started, pid 2264
2026-10-22 22.23.29 the test window is closed
```

The trial was armed with a **Startup entry**, and the entry was removed by
the trial itself at the end of the attempt.

Two findings are important for the next attempt:

* the **task of the scheduler never fires**.  The task file was written and
  it was there, but the scheduler never registered it (the removal answered
  "ERROR: The system cannot find the file specified").  The Startup entry
  is the way that works.
* the **build PC has to be elevated** for the Startup entry.  The denial of
  the write is the token of the shell of the build PC (UAC), not a lock of
  the phone on the folder.  The staging therefore runs as
  `Start-Process pwsh -Verb RunAs`.

The attempt had no button event at all, the window of 240 seconds was too
short for the test.

### Result of the eighth attempt (2026-10-22)

The eighth attempt ran from 22:56 until 23:07, the receipts are in
`receipts/buttons-attempt8/trial-logs`.

The **button path** is good:

| Key | Result |
| --- | --- |
| Assist short | the start menu opens |
| Volume Up short | `TAB` |
| Volume Down short | `ENTER` |
| Volume Down long | `Shift+F10` |

The **power key** is the part that fails.  The agent answered every press
with `action lock returned True` and the wake never came back:

```
wake input desktop error 5      (the access to the secure desktop was denied)
wake input desktop error 170    (the desktop was in use)
the input desktop is ????|0     (the name could not be read)
the input desktop is <none>|5
```

The lock of a session that cannot be opened again is a trap on this phone,
the touch screen does not work and there is no keyboard, so the user was
left in the lock screen and no key could leave it.  The mapping of the
ninth attempt is therefore different:

* the short press of the power key turns the **display** off and on again
  and does not lock the session,
* the long press of the **volume up** key opens the lock screen of a
  session that was locked by Windows itself,
* the long press of the **assist** key closes the window that has the
  focus (`Alt+F4`).

### Result of the ninth attempt (2026-10-22)

The ninth attempt ran with the mapping of the eighth attempt (the power key
turns the display off and on, the volume up key opens the lock screen, the
assist key closes the window).  The report of the user:

* the **short press** of the power key did not show a lock screen.  That is
  the mapping that was armed: the power key turns the display off and on
  again, it does not lock the session.
* the **long press** of the power key did not shut the phone down.  The
  trial ran the agent with `-DisableShutdown`, so the action was skipped on
  purpose.  The shutdown of the agent is allowed now, the trial switches it
  off only with `-DisableShutdownAction`.

The log of the attempt is still on the phone, the next staging archives it
into `previous-trial-logs` of the receipt.

### Result of the tenth attempt, the mapping for the daily use

The user asked for a mapping that is easier to use, and the mapping is now
a parameter of the trial and of the tool:

| Button | Short press | Long press |
| --- | --- | --- |
| Volume Up | `UP` | `RIGHT` (800 ms) |
| Volume Down | `DOWN` | `LEFT` (800 ms) |
| Assist | `ENTER` | `TAB` (800 ms) |
| Power | the start menu | `shutdown /s` (1500 ms) |

The four arrow keys are new actions of the agent (13, 14, 15 and 16).  The
driver carries the number of the action without looking at it, so no new
build of the driver is needed for them.

```powershell
# PC, stage the attempt with the mapping
pwsh -NoProfile -ExecutionPolicy Bypass -File Stage-TimelmButtonsTrial.ps1 `
    -Artifact C:\artifacts\timelm-native-buttons -Output C:\receipts\buttons `
    -ButtonMode Agent -PowerAction StartMenu -PowerLongAction Shutdown `
    -VolumeUpAction Up -VolumeUpLongAction Right `
    -VolumeDownAction Down -VolumeDownLongAction Left `
    -AssistAction Enter -AssistLongAction Tab -Seconds 900 -Arm
```

## The status of the buses

`Collect-TimelmPciStatus.ps1` collects the state of the buses of the
machine, it is the evidence for the touch driver.  The trial calls it at
the beginning of the attempt, before the buttons are tested, so that a
problem of the machine is told apart from a problem of the driver of the
buttons.

```powershell
powershell -ExecutionPolicy Bypass -File Collect-TimelmPciStatus.ps1 `
    -OutputDirectory C:\TimelmLogs\TimelmPciStatus
```

The report has two files, `pci-status.json` for the machines and
`pci-status.txt` for the eye:

| Part | Content |
| --- | --- |
| summary | the number of the devices of every class, the number of the devices with a problem, the number of the devices that are not there |
| pci | every device of the bus PCI with its status, its problem code, its driver and its place in the bus |
| problems | every device of every class with a problem code (the code 45 means "not there" and is not a problem) |
| acpi | the devices of the class ACPI, the touch controller of the phone is behind one of them |
| i2c | the controllers of the class I2C |
| registry | the entries of `Enum\PCI` and `Enum\ACPI` with their driver and their device parameters |
| events | the entries of the system log that talk about `PCI`, `PCIe`, `WHEA`, `ACPI`, `I2C` or the touch |
| pnputil | the output of `pnputil /enum-devices /problem` |

The class of a device of the bus PCI is not always "PCI", a root complex
of a laptop shows up as a device of the class System.  The report therefore
uses the name of the instance (`PCI\...`) and not the class.


## The assist key

The assist key of the phone is bound to the **Windows key** by default, so
that a press opens the start menu of Windows.

```powershell
# PC, from the desktop session of the phone
powershell -ExecutionPolicy Bypass -File Set-TimelmButtonMode.ps1 `
    -Mode Agent -AssistAction StartMenu
```

For every other function the agent reads the target from a text file, so the
function can be changed without touching the agent:

```
%ProgramData%\Timelm\assist-target.txt
```

The content is the command line that is started with the shell, for example
`notepad.exe`.  An empty or missing file means that the agent only writes a
note into its log.

```powershell
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
  the switch of the input desktop do not work from a service.
* The trial hides its own console window, otherwise the `Alt+F4` of the
  assist key would close the console of the trial instead of the window
  that has the focus.
* Windows itself may also react to the power key through the ACPI button
  driver, which can produce a shutdown prompt in addition to the action of
  the agent.
* The PMIC is read through `SPMI.sys`; if that driver is not running the
  driver stays in the "not ready" state and retries every 500 ms.
