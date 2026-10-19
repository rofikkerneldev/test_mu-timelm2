/* SPDX-License-Identifier: GPL-2.0-only */
#ifndef TIMELM_BOARD_WINDOWS_H
#define TIMELM_BOARD_WINDOWS_H
#include "touch_board.h"
#include "../../../Resources/DeviceOverlays/timelm/Drivers/KonaGPIO/TouchBus.h"
typedef struct GENI_BOARD {
    WDFDEVICE Device;
    PUCHAR GccCore, GccVote;
    PUCHAR Engine;
    WDFIOTARGET Pins[4], Provider;
    LARGE_INTEGER PinIds[4];
    TIMELM_TOUCH_BUS Bus;
    TOUCH_BOARD State;
    NTSTATUS LastStatus;
    BOOLEAN Native;
    BOOLEAN InterfaceAcquired;
} GENI_BOARD;
NTSTATUS GeniBoardPrepare(GENI_BOARD *board, WDFDEVICE device, WDFCMRESLIST resources);
NTSTATUS GeniBoardStart(GENI_BOARD *board, PUCHAR engine, ULONG *select);
NTSTATUS GeniBoardConfirmClock(GENI_BOARD *board);
NTSTATUS GeniBoardStop(GENI_BOARD *board);
VOID GeniBoardRelease(GENI_BOARD *board);
VOID GeniRecord(WDFDEVICE device, PCWSTR name, ULONG value);
#endif
