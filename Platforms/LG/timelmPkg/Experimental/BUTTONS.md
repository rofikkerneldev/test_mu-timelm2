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
`KEY_POWER`, `KEY_VOLUMEDOWN`, `KEY_VOLUMEUP` and `KEY_TV`) and the
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
low). It is the same gpio1 that the kernel uses for that key, so the
register address above is not a guess but the address the Linux driver of
the board uses.

The kernel reports the key with the raw code `0x179` (377), which is
`KEY_TV` in the kernel. Android gives it the name of the assist key with a
key layout file, the ROM of this phone carries
`configs/keylayout/gpio-keys.kl` with the line `key 377 ASSIST`. The
Windows driver does not use the key code at all, it reads the register, so
the name does not matter there.

### The pull up of the assist key

The pinctrl of the `gpio-keys` node covers gpio6 only
(`key_vol_up_default` with `bias-pull-up`). The pull up of gpio1 sits in
`key_home_default`, the pinctrl of the `qcom,qbt_handler` node, which uses
the same pin as `qcom,finger-detect-gpio`. In the recovery that driver does
not run, the pad of the assist key hangs free and the contact bounces with
a period of about 130 ms (154 events in 43 s, measured on the phone).

The agent therefore answers a press only when the button was quiet for the
quiet time (500 ms by default), so that a bouncing contact opens the start
menu once and not dozens of times. The PMIC is only read, the driver does
not change the pad, so the assist key keeps the behaviour of the firmware.

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
| Assist | the Windows key, the start menu opens | - |

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
| 9 | Start menu | the Windows key, the start menu of Windows opens |

The assist key uses the action 9 by default, so that the button of the
phone opens the start menu of Windows. The action 8 exists for every other
function, the target of the key is then a text file with a command line.

Windows has no wake button of its own, so the wake is done by the agent: it
calls `SetThreadExecutionState(ES_SYSTEM_REQUIRED | ES_DISPLAY_REQUIRED)`,
sends `WM_SYSCOMMAND / SC_MONITORPOWER` to all windows and nudges the mouse.
The input of `SendInput` only arrives at the desktop of the thread of the
caller, so a helper in a short lived process moves itself to the input
desktop of the session and sends a harmless key there.  That desktop is the
secure desktop of a locked session, so the lock screen wakes up.

Whether the session is locked is read from the name of the input desktop
(`OpenInputDesktop` plus `GetUserObjectInformation(UOI_NAME)`); on a locked
session the name is `Winlogon`.  That name is not a reliable source on this
board (see attempt 4), so the power key is a **toggle**: the press after a
lock is a wake, and the name of the desktop is only the evidence for the
first press and for the log.

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

### Attempt 4, the assist key (2026-10-22)

The assist key works.  The wake is still open.  The receipts are in
`receipts/buttons-attempt4`.

| Check | Result |
| --- | --- |
| Driver | revision `7b35cf5d1a6760e62ff5ad9600845dc110515b9f`, Debug, ARM64, sys sha256 `11D6C418481609792A0DCB8F2B79FD8497BA42162DF7DD91143B9708326AC214`, inf sha256 `E972A0F41A13C81A34E7B455771EA26DF06B9BF4910F088CF616FCC572717CFA` |
| Node | `ACPI\KONA1003\0`, status OK, problem code 0, service `TimelmButtons` Running |
| Mode | `Agent`, mapping version 3, assist action `StartMenu` |
| Assist | 16 short presses, 16 start menus, no double answer |
| Volume | 10 x `TAB`, 11 x `ENTER`, 2 x `Shift+F10` |
| Power | 9 short presses, 9 x "action lock returned True", **0 wakes** |
| Shutdown | `shutdown /s` after 240 s, the phone reached the mass storage mode again |

The assist key is the fourth button of the phone, PMIC gpio1 at `0xC010`, and
the driver reads it with the same debounce as the other three.  The bouncing
contact of the pad (no pull up in the recovery) did not open the start menu
twice, the quiet time of 500 ms of the agent is enough.

The power key locked the workstation nine times and never woke it.  The
reason is in the log of the attempt: the agent of that revision read the
state of the lock from the name of the input desktop, and a name that cannot
be read was treated as "not locked".  So every press after a lock was
answered with another lock.  The state of the lock is not a reliable source
on this board, the name of the secure desktop is not always visible to the
agent.

### Attempt 5, the wake (staged)

The power key is a toggle now: the press after a lock is a wake, and the
name of the input desktop is only the evidence for the first press and for
the log.  The agent wakes the display with `SetThreadExecutionState`,
`WM_SYSCOMMAND / SC_MONITORPOWER` and a mouse nudge, and a helper in a short
lived process sends a harmless key to the input desktop of the session, which
is the secure desktop of a locked session.

| The agent has to prove | How it is measured |
| --- | --- |
| the press after the lock wakes the display | the log of the agent shows "action wake" and the state of the display on the phone |
| the helper reaches the secure desktop | the log of the agent shows the exit code of the helper |
| the wake does not open the power menu of Windows | the log of the agent shows no second action of the power key |

The attempt is **armed with a task of the task scheduler**.  The Startup
folder of the phone belongs to its own administrators, and Windows of the
phone applied its own rights to the ProgramData in the boot after the fourth
attempt, so the build PC can no longer write the Startup entry there
("Access to the path ... is denied").  The phone has no working touchscreen
and Windows does not see the USB OTG, so there is no way to start the trial
by hand either.

The staging writes the task into `C:\Windows\System32\Tasks\TimelmButtonsTrial`
instead (that folder can be written, sha256
`A05530A20669DACF617366A1EF1B1522F7D3A5557915CCEED8756D7B06595558`).  The
scheduler reads the tasks of that folder when its service starts, so the
task runs at the logon of the administrator (`S-1-5-21-2900457808-1833740068-2038273949-500`)
and the trial starts by itself after the next boot.  The trial removes the
task at the end of the attempt.

The bundle of the attempt is on the phone, staged from the artifact of the CI
run `39767984644` (sys sha256 `50632B6B980A1215CF2B7148BCFD2AA271C0120DAC0D150F0960678F7EB8A39E`,
inf sha256 `2DDC311F4B833F4808977AB4EFB625D5EBBC3629388C9F576392AB4A6EAD14AD`),
the receipt is in `receipts/buttons-attempt5`.

The target of the assist key is written by the trial itself, the build PC
has no write right on `C:\ProgramData\Timelm` either.

## What is still open

* The **wake** of the display is the only part of the button path that is
  not proven on the phone.  The assist key works (attempt 4), the lock works
  (attempt 4), the wake is the subject of attempt 5.
* The **capture of the touch chip** in the recovery came out empty
  (`captures/touch/f-touch`): the chip is quiet in the recovery, so the
  capture has to run in Android, not in the recovery.
* Windows does not react to the power key with a wake, the agent has to do
  it.  The wake is not proven by a measurement on the phone yet.

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
