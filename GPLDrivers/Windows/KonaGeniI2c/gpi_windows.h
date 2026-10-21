/* SPDX-License-Identifier: GPL-2.0-only */
#ifndef TIMELM_GPI_WINDOWS_H
#define TIMELM_GPI_WINDOWS_H
#include "geni_gpi.h"
#include "iommu_windows.h"
typedef struct GPI_WINDOWS {
    WDFDEVICE Device;
    WDFINTERRUPT Interrupt;
    PUCHAR Registers, Smmu;
    PDMA_ADAPTER Adapter;
    PVOID Allocation;
    PHYSICAL_ADDRESS Logical;
    GP_IO Io;
    KEVENT Wake;
    volatile LONG Error, Irqs, InterruptEnabled;
    SPBREQUEST CurrentRequest;
    BOOLEAN Retained;
    BOOLEAN UseIommu;
    TIMELM_IOMMU Dma;
} GPI_WINDOWS;
NTSTATUS GpiWindowsPrepare(GPI_WINDOWS *g, WDFDEVICE device, WDFCMRESLIST raw, WDFCMRESLIST translated);
NTSTATUS GpiWindowsStart(GPI_WINDOWS *g, ULONG clockSelect);
NTSTATUS GpiWindowsCheckReady(PVOID context);
NTSTATUS GpiWindowsTransfer(GPI_WINDOWS *g, SPBREQUEST request, UCHAR *data,
    ULONG length, BOOLEAN read, BOOLEAN hold, ULONGLONG deadline);
NTSTATUS GpiWindowsStop(GPI_WINDOWS *g);
BOOLEAN GpiWindowsRelease(GPI_WINDOWS *g);
#endif
