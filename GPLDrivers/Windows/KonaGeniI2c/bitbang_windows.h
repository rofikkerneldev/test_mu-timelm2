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
    TIMELM_TOUCH_BUS_V4 Bus;
    BB_IO Io;
    WDFREQUEST Request;
    ULONG Connections;
    BOOLEAN Acquired, Muxed, Powered, Ready, StartedOnce, Retained, Cleaning, FailureValid;
    NTSTATUS LastStatus;
    ULONG Transfers, Failures;
    /* Start writes and cleanup have separate records. FirstFailure is latched
     * before cleanup and invalidated only by a new preparation generation. */
    ULONG OpenStatus[BB_WINDOWS_MAX_PINS], WriteStatus[BB_WINDOWS_MAX_PINS];
    ULONG WriteBytes[BB_WINDOWS_MAX_PINS], PinOrdinals[BB_WINDOWS_MAX_PINS];
    ULONG Attempt, FailOp;
    ULONG OpPin, OpValue, OpBytes;
    ULONG FailurePin, FailureValue, FailureStatus, FailureBytes;
    ULONGLONG Generation, ProviderGeneration;
} BB_WINDOWS;
NTSTATUS BbWindowsPrepare(BB_WINDOWS *bus,WDFDEVICE device,WDFCMRESLIST resources);
NTSTATUS BbWindowsStart(BB_WINDOWS *bus);
NTSTATUS BbWindowsStop(BB_WINDOWS *bus);
BOOLEAN BbWindowsRelease(BB_WINDOWS *bus);
NTSTATUS BbWindowsTransfer(BB_WINDOWS *bus,WDFREQUEST request,BB_MESSAGE *messages,ULONG count);
#endif
