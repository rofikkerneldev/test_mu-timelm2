/* SPDX-License-Identifier: GPL-2.0-only */
#ifndef TIMELM_BITBANG_WINDOWS_H
#define TIMELM_BITBANG_WINDOWS_H
#include "bitbang_i2c.h"
#include "../../../Resources/DeviceOverlays/timelm/Drivers/KonaGPIO/TouchBus.h"
/* The ACPI bus pair 36/37 may reach the driver as one connection resource or
 * as one resource per pin. Both shapes are accepted; the three power pins
 * always come first because ACPI keeps _CRS order. */
#define BB_WINDOWS_MAX_PINS 5
#define BB_WINDOWS_POWER_PINS 3
typedef struct BB_WINDOWS {
    WDFDEVICE Device;
    WDFIOTARGET Pins[BB_WINDOWS_MAX_PINS], Provider;
    LARGE_INTEGER PinIds[BB_WINDOWS_MAX_PINS];
    TIMELM_TOUCH_BUS_V3 Bus;
    BB_IO Io;
    WDFREQUEST Request;
    ULONG Connections;
    BOOLEAN Acquired, Muxed, Powered, Ready, StartedOnce, Retained;
    NTSTATUS LastStatus;
    ULONG Transfers, Failures;
    /* Per-op trial evidence (Phase B). NTSTATUS is stored unsigned; these are
     * registry snapshots, so a *later* write per index wins. FailOp stays the
     * first failed step of the boot (BitbangStatus/FailOp reset at prepare). */
    ULONG OpenStatus[BB_WINDOWS_MAX_PINS], WriteStatus[BB_WINDOWS_MAX_PINS];
    ULONG WriteBytes[BB_WINDOWS_MAX_PINS], PinOrdinals[BB_WINDOWS_MAX_PINS];
    ULONG Attempt, FailOp;
} BB_WINDOWS;
NTSTATUS BbWindowsPrepare(BB_WINDOWS *bus,WDFDEVICE device,WDFCMRESLIST resources);
NTSTATUS BbWindowsStart(BB_WINDOWS *bus);
NTSTATUS BbWindowsStop(BB_WINDOWS *bus);
BOOLEAN BbWindowsRelease(BB_WINDOWS *bus);
NTSTATUS BbWindowsTransfer(BB_WINDOWS *bus,WDFREQUEST request,BB_MESSAGE *messages,ULONG count);
#endif
