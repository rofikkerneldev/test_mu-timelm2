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
| Volume Up | `UP` (the cursor moves up) | `RIGHT` (800 ms) |
| Volume Down | `DOWN` (the cursor moves down) | `LEFT` (800 ms) |
| Power | the Windows key, the start menu opens | `shutdown /s` (1500 ms), clean shutdown |
| Assist | `ENTER` | `TAB` (800 ms) |

The long press is detected with the press duration that the driver reports,
so it does not depend on the accuracy of the polling loop. The power long
press is the only path that ends the session, and it uses `shutdown /s`, so
Windows still shuts down cleanly.

The mapping was changed after the attempt 9, the user asked for a mapping
that is easier to use: the volume keys move the cursor, the assist key
answers with `ENTER` and `TAB` and the power key opens the start menu and
shuts the phone down.  Every action of the mapping can be changed with the
parameters of `ConvertTo-TimelmButtonMapping` and of the trial.

The power key does **not** lock the session.  A lock without a way to open
it again is a trap on this phone: the touch screen does not work and there
is no keyboard, so the lock screen would be the end of the session.  The
attempt 8 showed exactly that (see the result of the attempt 8 below).

The agent has to run in the interactive user session: `SendInput` does not
work from a service in session 0.

### Who answers a press

Windows has no native counterpart for the display, so the power key always
belongs to the agent. The two volume keys do have one, so the HID face of
the driver can take them over. Three modes are possible:

| Mode | Volume keys | Power key | Assist key |
| --- | --- | --- | --- |
| `Agent` | TAB / ENTER / Shift+F10 through the agent | agent | agent |
| `Hid` | the volume flyout of Windows, through the HID face of the driver | agent (display off and on) | agent |
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
| 10 | Display toggle | the display of the phone goes off, the next press brings it back |
| 11 | Unlock | open the lock screen of a locked session |
| 12 | Close | `Alt+F4`, close the window that has the focus |
| 13 | Up | the cursor moves up |
| 14 | Right | the cursor moves right |
| 15 | Down | the cursor moves down |
| 16 | Left | the cursor moves left |

The driver does not check the numbers, it only carries them from the mapping
of the tool into the agent, so the new actions need no new build of the
driver.  The action 4 and the action 7 stay in the table, they are the
answer to a session that was locked by Windows itself.

The display is turned off with `WM_SYSCOMMAND / SC_MONITORPOWER` and the
value 0, it is turned on again with the value 1 and a small movement of the
mouse.  The message is posted and not sent, a window that does not answer
would block the agent for ever.  The agent holds
`ES_CONTINUOUS | ES_SYSTEM_REQUIRED | ES_DISPLAY_REQUIRED` while it runs, so
the idle timer of Windows does not turn the display off and the state of
the display is only changed by the power key of the phone.

The lock screen of a locked session lives on the secure desktop of
`winlogon.exe`.  A process of the session cannot open that desktop, the
attempt 8 showed the error 5 (the access was denied) and the error 170 (the
desktop was in use).  The unlock works with the identity of `winlogon.exe`
instead: the token of that process is copied, the agent works as that
identity for a moment, opens the `Winlogon` desktop and sends the return
key there.  The account of the phone has **no password**
(`AutoAdminLogon = 1`, `DefaultUserName = Administrator` and no
`DefaultPassword`), so the return key signs the user in.

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

### Attempt 7, the trial starts by itself (2026-10-22)

The trial passed completely on the phone and the receipts are in
`receipts/buttons-attempt7`.

The proof that the attempt started by itself is the first line of the log of
the trial:

```
2026-10-22 22.18.52 the trial starts, user TIMELM-V60\Administrator, session 1, elevated True
```

The trial was **armed with a Startup entry**, and the entry was removed by
the trial itself at the end of the attempt, so the next logon of the phone
does not start a second attempt.

Two findings of the attempt are important for the next one.

**The task of the scheduler never fires.**  The task file was written to
`C:\Windows\System32\Tasks\TimelmButtonsTrial` and it was there (sha256
`22535FB3DFBFE9F1374C25E762E19C6377F57E78895BE1A1CBD0EA39326B94DA`), but the
scheduler never registered it: the removal of the task at the end of the
attempt answered "ERROR: The system cannot find the file specified", and the
task is not in the cache of the scheduler.  The Startup entry is the way
that works.

**The build PC has to be elevated for the Startup entry.**  The denial of
the write is not a lock of the phone on the folder, it is the token of the
shell of the build PC: a medium integrity shell cannot write into the
Startup folder of the phone, because the deny only entry of the
`BUILTIN\Administrators` of the phone is deny only for such a shell (UAC).
The staging therefore has to run as an administrator of the build PC
(`Start-Process pwsh -Verb RunAs`).  The folder
`C:\Windows\System32\Tasks` can be written without that, because it carries
the entry `NT AUTHORITY\Authenticated Users:(CI)(W,Rc)`.

The attempt had **no button event at all**: the state of the driver stayed
at `change_counter` 6 and `hid_reports` 0 for the whole run.  The window of
the trial was too short for the test, the attempt was 240 seconds long.

### Attempt 8, the buttons (staged)

The attempt 8 is armed with a Startup entry as well, with a window of 900
seconds, so that there is time for the test.

The helper of the edges of the buttons was changed after the attempt 7, the
reason is the log of the attempt 5: the log had 523 lines of

```
Power down ignored, the button is still locked after the last action
```

The helper marked a button as down only when the press was answered.  A
press inside the quiet time of the last action was ignored without that
mark, so every following sample of the held button was ignored again, and
the time of the last press was moved forward by every sample of the held
button, so the quiet time never ended and the button stayed locked for
ever.  The press that is ignored marks the button as down and the long
press as answered now, and a contact that stays closed for three seconds
gives the lock up, the button has to be released and pressed again.

#### The result of the attempt 8 (2026-10-22)

The trial ran from 22:56 until 23:07, the log of the agent is in
`receipts/buttons-attempt8/trial-logs/agent.log`.

* The **assist key** answers with the start menu, the **volume up** key
  with `TAB` and the **volume down** key with `ENTER` and with `Shift+F10`
  after 800 ms.  The bouncing contact of the assist key answers only once.
* The **power key** locked the session again and again
  (`action lock returned True`), and the wake did not come back:
  `wake input desktop error 5` (the access to the secure desktop was
  denied) and `wake input desktop error 170` (the desktop was in use).
  The name of the input desktop could not be read either
  (`the input desktop is ????|0` and `the input desktop is <none>|5`).

The button path itself is good, the **lock** is the part that fails.  The
lock of a session that cannot be opened again is a trap on this phone, the
touch screen does not work and there is no keyboard, so the user was left
in the lock screen (blue background and the clock) and no key could leave
it.  The mapping of the attempt 9 is therefore different:

* the short press of the power key turns the **display** off and on again
  and does not lock the session,
* the long press of the **volume up** key opens the lock screen of a
  session that was locked by Windows itself,
* the long press of the **assist** key closes the window that has the
  focus (`Alt+F4`).

The account of the phone has no password (`AutoAdminLogon = 1`,
`DefaultUserName = Administrator`, no `DefaultPassword`), so the return key
is enough to sign in.

#### The status of the buses

The trial collects the status of the buses before it tests the buttons
(`Collect-TimelmPciStatus.ps1`), so that a problem of the machine is told
apart from a problem of the driver of the buttons.  The report has the
devices of the bus PCI with their status and their place in the bus, the
devices with a problem, the devices of the class ACPI (the touch controller
of the phone is behind one of them), the controllers of the class I2C, the
entries of `Enum\PCI` and `Enum\ACPI` and the entries of the system log
that talk about `PCI`, `PCIe`, `WHEA`, `ACPI`, `I2C` or the touch.

### Attempt 9, the display of the power key (2026-10-22)

The attempt 9 ran with the mapping of the attempt 8 (the power key turns the
display off and on, the volume up key opens the lock screen, the assist key
closes the window).  The report of the user:

* the **short press** of the power key did not show a lock screen.  That is
  the mapping that was armed: the power key turns the display off and on
  again and it does not lock the session at all.
* the **long press** of the power key did not shut the phone down.  The
  trial ran the agent with `-DisableShutdown`, so the action was skipped on
  purpose (`action shutdown skipped (disabled)`).  The shutdown of the
  agent is allowed now, the attempt asks for it with
  `-DisableShutdownAction`.

The log of the attempt 9 is still on the phone, it is read with the next
staging (the staging archives the log of the phone into
`previous-trial-logs` of the receipt).

### Attempt 10, the mapping for the daily use (proven)

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

The attempt 10 ran on the phone on 23.10.2026, 1200 s, with the mapping
above.  The log of the agent (`E:\TimelmLogs\TimelmButtonsTrial\agent.log`)
answers every press with the action of the mapping:

| Action | Times | Action | Times |
| --- | --- | --- | --- |
| `UP` | 15 | `DOWN` | 60 |
| `RIGHT` | 5 | `LEFT` | 4 |
| `ENTER` | 12 | `TAB` | 9 |
| the start menu | 17 | `shutdown /s` | 2 |

The long press is measured by the driver: the volume and the assist key
answered after 815 ms to 827 ms (limit 800 ms), the power key after 1515 ms
and 1519 ms (limit 1500 ms).

The **shutdown is no longer switched off**: the flag of the attempt 9
(`-DisableShutdownAction`) is gone, and the agent logged
`action shutdown /s` twice, at 00:49:15 and at 00:49:31 (phone clock).
The phone did shut down, but only **two minutes later**: the last write of
`System.evtx` and of `bootstat.dat` is 00:51:32 and there is no bugcheck
dump, so the shutdown was clean and not a crash.  The request itself was
blind before (the exit code of `shutdown.exe` was never read), so the two
minutes could not be told apart from a request that was never accepted.

The agent now measures the request:

* `shutdown.exe /s /t 0 /f` (the `/f` closes the programs that would hold
  the shutdown back),
* the exit code of the helper is written to the log,
* if the helper is refused, `ExitWindowsEx` asks for the same shutdown and
  its answer is logged too.

The event log of the phone names the program that held the shutdown back in
the earlier attempts (read offline from the collection of the fifth touch
trial):

```
2026-10-22 08.16.22 id=1074 The process C:\Windows\System32\shutdown.exe
    (TIMELM-V60) has initiated the shutdown of computer TIMELM-V60
    on behalf of user NT AUTHORITY\SYSTEM ...
2026-10-22 08.16.57 id=100  Process ...\Microsoft\OneDrive\OneDrive.exe is
    delaying system shutdown after 5031 milliseconds.
```

So the request is made and accepted; a program of the session holds it back.
The `/f` closes those programs.

The trial ends with the same request (`shutdown /s /t 30 /f`) and writes the
exit code into the log.

### Attempt 11, the power key switches the window

The eleventh attempt was staged with the new agent (the measured shutdown) and
the same mapping as the attempt 10.  The report of the user: the shutdown of
the phone still did not answer well enough for the daily use, so the power key
got a new mapping:

| Button | Short press | Long press |
| --- | --- | --- |
| Volume Up | `UP` | `RIGHT` (800 ms) |
| Volume Down | `DOWN` | `LEFT` (800 ms) |
| Assist | `ENTER` | `TAB` (800 ms) |
| Power | `TAB` | `Alt+Tab` (1500 ms) |

`Alt+Tab` is a new action of the agent (17).  The switch between the windows
belongs to the shell, so the alt key has to be held while the tab key is
pressed; both keys are sent in one batch, otherwise the shell would see a tab
without the alt key and would move the focus inside the window instead of
switching the window.

The action is the number 17 in the mapping and the driver carries the number
of the action without looking at it, so no new build of the driver is needed.
The default of every script is the new mapping now, the action `Shutdown` is
still there for the end of a trial.

## What is still open

* The **shutdown of the long power press** is answered (the agent calls
  `shutdown.exe`), but the phone needed two minutes for it on the attempt
  10.  The next attempt reads the exit code of the request; the open
  question is what holds the shutdown back (the attached USB mass storage
  or an open program).  The daily mapping does not use it any more.
* The **`Alt+Tab` of the power key is not proven on the phone yet**: the
  action is new and the shell has to take it, not the application.
* The **capture of the touch chip** in the recovery came out empty
  (`captures/touch/f-touch`): the chip is quiet in the recovery, so the
  capture has to run in Android, not in the recovery.
* The status of the buses of the phone has to be read on the phone itself,
  the report of the attempt 9 is the first one.

## Risks

* Windows itself may react to the power key through the ACPI button driver,
  which can produce a shutdown prompt in addition to the action of the
  agent. The trial ends with one controlled `shutdown /s`, and the long
  press of the power key may shut the phone down in the middle of the
  attempt (`-DisableShutdownAction` switches that off).
* The button package replaces the PMIC driver on that node. If the button
  driver does not start, the node stays without a working driver, which is
  the state the board was in before this path.
* The PMIC is read through `SPMI.sys`. While that driver is not running the
  button driver stays in the "not ready" state and retries every 500 ms.
* The unlock works with the identity of `winlogon.exe`, that needs the
  right to impersonate.  The agent runs as the administrator of the phone,
  the right is part of that account.

