/* SPDX-License-Identifier: MIT
 * Private v2 interface: caller must hold exclusive GPIO IO connections for
 * pins 36/37 before enable and until disable. Not a general pinmux API.
 */
#ifndef TIMELM_TOUCH_BUS_H
#define TIMELM_TOUCH_BUS_H
DEFINE_GUID(GUID_TIMELM_TOUCH_BUS,
    0x54991d58, 0x813b, 0x4fd3, 0xa5, 0x4e, 0x9b, 0x29, 0x60, 0xbc, 0xf2, 0x74);
typedef struct TIMELM_TOUCH_BUS {
    INTERFACE Interface;
    NTSTATUS (*SetBus)(PVOID Context, BOOLEAN Enable);
} TIMELM_TOUCH_BUS;

/* Separate GUID preserves the exact v2 query ABI. The caller reserves GPIO
 * 36/37 as exclusive INPUT connections until SetGpioMode(FALSE) succeeds.
 * Release means input/high impedance; this interface never drives a high.
 * Hardware-key TouchBusGpioEnabled DWORD=1 is an additional explicit opt-in.
 * SDA=36 and SCL=37. Only individual register operations hold a spin lock. */
DEFINE_GUID(GUID_TIMELM_TOUCH_BUS_V3,
    0xa43b6365, 0xb5e5, 0x4e40, 0x88, 0x1c, 0xe9, 0x2c, 0x38, 0x91, 0x5a, 0x06);
typedef struct TIMELM_TOUCH_BUS_V3 {
    INTERFACE Interface;
    NTSTATUS (*SetGpioMode)(PVOID Context, BOOLEAN Enable);
    NTSTATUS (*SetLines)(PVOID Context, BOOLEAN ReleaseScl, BOOLEAN ReleaseSda);
    NTSTATUS (*GetLines)(PVOID Context, PBOOLEAN SclHigh, PBOOLEAN SdaHigh);
} TIMELM_TOUCH_BUS_V3;
#endif
