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
#endif
