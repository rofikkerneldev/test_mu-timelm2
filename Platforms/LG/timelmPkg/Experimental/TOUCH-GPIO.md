# V60 basic touch through GPIO I2C

This explicit bring-up path targets one-finger tap and swipe on the SW42902.
It reuses the existing SPBCx host and SW42902 HID client, replacing only the
bus transport with bounded open-drain GPIO I2C. Physical operation in Windows
is pending; passing the build and model tests is not hardware acceptance.

V60 Recovery DT/vendor evidence establishes GPIO36/37 on QUP13, address0x28,
reset38, VCL67 and VDD68. SDA36/SCL37 lane order is corroborated by SM8250
platform pin documentation. The touch supply node uses GPIO switches rather
than declaring touch regulator supplies. Therefore a small GPIO transport can
be tested independently of unfinished GENI/GPI/SMMU ownership and PEP power
integration. It does not replace a complete platform power implementation.

## Explicit resource and ownership contract

`TouchGpioWindows.asl` is disabled by default and excluded from normal firmware.
Its host `TIML0001`, UID14, TBCF0x54420501 has four exclusive GPIO connections:
reset38, VCL67, VDD68 and the bus pair36/37. There are no host memory or IRQ
resources. The child `LGSW4290` retains address0x28, a100kHz speed ceiling and
falling-edge GPIO39 IRQ. It depends on the host and GPIO provider.

The new GPIO provider V3 has a separate GUID and exact interface ABI; V2 is
unchanged. It requires both bus pins reserved through ResourceHub and the
additional GPIO device opt-in `TouchBusGpioEnabled=1`. It saves/restores only
the two pins' fields/latches and excludes the V2 QUP-mux owner. LOW always
means output with a verified low latch. HIGH means input/high impedance.
Clock transitions are ordered to avoid accidental START/STOP edges. No callback
drives HIGH. Failed restoration retains the owner and reservations, logs the
failure and blocks restart; reboot is required. The first test does not support
suspend/resume or controller restart after a successful start.

The host selects this path only with `NativeGpioI2cEnabled=1` and all native
GENI/GPI/IOMMU/firmware-handoff/source-clock/probe flags zero. Default INF values
are zero. It does not map GENI/GCC/GPI/SMMU, allocate DMA, vote clocks, initialize
PEP or touch another controller. Existing native DMA paths remain separate.

## Transfer and chip acceptance

The portable bus core fixes target0x28, limits one atomic request to1–2messages
and256bytes, implements repeated START, clock stretching, NACK, cancellation,
arbitration and bounded STOP cleanup. Half-period10us limits the initial bus
to at most50kHz. Stretching is bounded to1ms and a whole transaction to100ms;
the Windows request path uses a90ms deadline within the client's100ms timeout.
Busy/arbitration releases both pins without issuing STOP on another owner's bus.

Power order follows the V60 driver: resetLOW, VCLHIGH,1ms, VDDHIGH,10ms,
resetHIGH,90ms. The host first reads chip identity with write26 44 / read8 and
accepts only `B3W68TIM`. A missing ACK, stuck line or wrong identity fails host
startup before the HID client can begin scan configuration. Diagnostics record
idle levels, product bytes, stage, transfer failures and cleanup state.

After the host starts, the existing SW42902 client verifies the product again,
applies the reviewed scan sequence and translates156-byte reports into basic
HID tap/swipe at1080x2460. No controller firmware is flashed.

## Build and controlled trial

- `build_geni_i2c.ps1` builds both existing transports and the GPIO path.
- `build_kona_drivers.ps1 -TimelmTouchFixes` builds the V3 GPIO provider; power
  experiments remain a separate flag. Only the GPIO package is used for touch.
- `build_sw42902_touch.ps1` builds the HID client.
- `build_touch_gpio_trial.sh` creates an ARM64 restore-first EFI launcher and
  enabled memory-only SSDT. It restores both original Windows EFI entries
  before publishing the table, verifies the known timelm namespace and does
  not install an IORT or perform firmware GPIO requests.
- `Build-TouchGpioPackage.ps1` assembles the verified bundle from the three
  driver packages, the launcher/SSDT and the phone's installed INF set. Only
  that bundle may be staged.
- `Stage-TouchGpioTrial.ps1` arms the bundle on the identified phone from the
  build PC and records the restore-first backups.

GPIO/host/client installation, certificate trust, activation flags and device
restart must be guarded by package hashes and the V60 installation identity.
Collect before/after logs and provide a short desktop interaction window.
Require hardware evidence in order: GPIO V3 available, idle lines HIGH,
identity B3W68TIM, host Code0, touch Code0, received IRQ/reports, real tap/swipe.
If an update needs reboot, record it and stop that trial cleanly instead of
pretending the new provider is already active.

Tests execute the production transport, Windows adapter and provider callbacks
with failure injection, electrical edge/ACK models and ASan/UBSan. The GPIO
provider patch is checked against the pinned Kona source. ARM64 WDK compilation
and ACPICA validate the driver/table ABI and syntax, not the board wiring.
