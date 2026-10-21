/* SPDX-License-Identifier: GPL-2.0-only */
#ifndef TIMELM_BITBANG_WINDOWS_H
#define TIMELM_BITBANG_WINDOWS_H
#include "bitbang_i2c.h"
#include "../../../Resources/DeviceOverlays/timelm/Drivers/KonaGPIO/TouchBus.h"
typedef struct BB_WINDOWS {
    WDFDEVICE Device;
    WDFIOTARGET Pins[4], Provider;
    LARGE_INTEGER PinIds[4];
    TIMELM_TOUCH_BUS_V3 Bus;
    BB_IO Io;
    WDFREQUEST Request;
    BOOLEAN Acquired, Muxed, Powered, Ready, StartedOnce, Retained;
    NTSTATUS LastStatus;
    ULONG Transfers, Failures;
} BB_WINDOWS;
NTSTATUS BbWindowsPrepare(BB_WINDOWS *bus,WDFDEVICE device,WDFCMRESLIST resources);
NTSTATUS BbWindowsStart(BB_WINDOWS *bus);
NTSTATUS BbWindowsStop(BB_WINDOWS *bus);
BOOLEAN BbWindowsRelease(BB_WINDOWS *bus);
NTSTATUS BbWindowsTransfer(BB_WINDOWS *bus,WDFREQUEST request,BB_MESSAGE *messages,ULONG count);
#endif
