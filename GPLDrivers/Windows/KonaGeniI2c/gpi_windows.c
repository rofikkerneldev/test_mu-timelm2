/* SPDX-License-Identifier: GPL-2.0-only */
#include <ntddk.h>
#include <wdf.h>
#include <spbcx.h>
#include "board_windows.h"
#include "gpi_windows.h"
#include "dma_policy.h"
#define GP_ALLOCATION_SIZE 8192u
typedef struct IRQ_CONTEXT { GPI_WINDOWS *Gpi; } IRQ_CONTEXT;
WDF_DECLARE_CONTEXT_TYPE_WITH_NAME(IRQ_CONTEXT, GpiGetIrqContext)
EVT_WDF_INTERRUPT_ISR GpiIsr;
EVT_WDF_INTERRUPT_ENABLE GpiEnable;
EVT_WDF_INTERRUPT_DISABLE GpiDisable;
static GI_U32 Read(void *context, GI_U32 offset)
{
    GPI_WINDOWS *g = context;
    return READ_REGISTER_ULONG((PULONG)(g->Registers + offset));
}
static void Write(void *context, GI_U32 offset, GI_U32 value)
{
    GPI_WINDOWS *g = context;
    WRITE_REGISTER_ULONG((PULONG)(g->Registers + offset), value);
}
static void Barrier(void *context) { UNREFERENCED_PARAMETER(context); KeMemoryBarrier(); }
static GI_U64 Now(void *context) { UNREFERENCED_PARAMETER(context); return KeQueryInterruptTime()/10u; }
static int Cancel(void *context)
{
    GPI_WINDOWS *g = context;
    return g->CurrentRequest && WdfRequestIsCanceled((WDFREQUEST)g->CurrentRequest);
}
static int Error(void *context) { return ((GPI_WINDOWS *)context)->Error != 0; }
static void Pause(void *context)
{
    GPI_WINDOWS *g = context;
    /* The ISR is an aid, not the source of truth: producer pointers and
     * control completion remain polled with bounded deadlines. */
    KeClearEvent(&g->Wake);
    KeStallExecutionProcessor(20);
}
static NTSTATUS Status(enum GP_RESULT result)
{
    switch (result) {
    case GpOk: return STATUS_SUCCESS;
    case GpInvalid: return STATUS_INVALID_PARAMETER;
    case GpBusy: return STATUS_DEVICE_BUSY;
    case GpTimeout: return STATUS_IO_TIMEOUT;
    case GpCancelled: return STATUS_CANCELLED;
    case GpNack: return STATUS_NO_SUCH_DEVICE;
    case GpNotReady: return STATUS_DEVICE_NOT_READY;
    case GpShort: return STATUS_DEVICE_DATA_ERROR;
    default: return STATUS_IO_DEVICE_ERROR;
    }
}
static VOID Record(GPI_WINDOWS *g, NTSTATUS status)
{
    ULONG i;
    static const PCWSTR names[] = {L"TimelmGpiEvent0",L"TimelmGpiEvent1",L"TimelmGpiEvent2",L"TimelmGpiEvent3"};
    GeniRecord(g->Device, L"TimelmGpiStatus", (ULONG)status);
    GeniRecord(g->Device, L"TimelmGpiStage", g->Io.Stage);
    GeniRecord(g->Device, L"TimelmGpiUnsafe", g->Io.Unsafe);
    GeniRecord(g->Device, L"TimelmGpiIrqs", (ULONG)g->Irqs);
    for (i = 0; i < 4; ++i) GeniRecord(g->Device, names[i], g->Io.LastEvent[i]);
}
/* The known minimal firmware has no Windows SMMU/IORT provider for this
 * device. This first adapter supports verified firmware BYPASS only. It
 * neither programs SMMU state nor treats Recovery IOVAs as DMA addresses. */
static GI_U32 SmmuRead(void *context, GI_U32 offset)
{
    return READ_REGISTER_ULONG((PULONG)(((GPI_WINDOWS *)context)->Smmu + offset));
}
static BOOLEAN DirectDmaAllowed(GPI_WINDOWS *g)
{
    GP_DMA_SNAPSHOT snapshot;
    int allowed = GpDirectDmaAllowed(g,SmmuRead,&snapshot);
    GeniRecord(g->Device,L"TimelmGpiSmmuControl",snapshot.Control);
    GeniRecord(g->Device,L"TimelmGpiSmmuSmr",snapshot.Smr);
    GeniRecord(g->Device,L"TimelmGpiSmmuS2cr",snapshot.S2cr);
    GeniRecord(g->Device,L"TimelmGpiDmaBypassVerified",allowed != 0);
    return allowed != 0;
}
NTSTATUS GpiWindowsPrepare(GPI_WINDOWS *g, WDFDEVICE device, WDFCMRESLIST raw, WDFCMRESLIST translated)
{
    ULONG i, irqIndex = MAXULONG, rawIndex = MAXULONG, gpiCount = 0, smmuCount = 0, irqs = 0, rawIrqs = 0;
    PCM_PARTIAL_RESOURCE_DESCRIPTOR gp = NULL, smmu = NULL;
    WDF_INTERRUPT_CONFIG config;
    WDF_OBJECT_ATTRIBUTES attributes;
    NTSTATUS status;
    g->Device = device;
    KeInitializeEvent(&g->Wake, NotificationEvent, FALSE);
    for (i = 0; i < WdfCmResourceListGetCount(translated); ++i) {
        PCM_PARTIAL_RESOURCE_DESCRIPTOR r = WdfCmResourceListGetDescriptor(translated,i);
        if (r && r->Type == CmResourceTypeMemory) {
            if (r->u.Memory.Start.QuadPart == 0xa00000 && r->u.Memory.Length == 0x70000) { gp = r; ++gpiCount; }
            if (r->u.Memory.Start.QuadPart == 0x15000000 && r->u.Memory.Length == 0x1000) { smmu = r; ++smmuCount; }
        } else if (r && r->Type == CmResourceTypeInterrupt) {
            if (r->Flags & CM_RESOURCE_INTERRUPT_LATCHED)
                return STATUS_DEVICE_CONFIGURATION_ERROR;
            irqIndex = i; ++irqs;
        }
    }
    for (i = 0; i < WdfCmResourceListGetCount(raw); ++i) {
        PCM_PARTIAL_RESOURCE_DESCRIPTOR r = WdfCmResourceListGetDescriptor(raw,i);
        if (r && r->Type == CmResourceTypeInterrupt) {
            if (r->u.Interrupt.Vector != 311 || (r->Flags & CM_RESOURCE_INTERRUPT_LATCHED))
                return STATUS_DEVICE_CONFIGURATION_ERROR;
            rawIndex = i; ++rawIrqs;
        }
    }
    if (gpiCount != 1 || smmuCount != 1 || irqs != 1 || rawIrqs != 1)
        return STATUS_DEVICE_CONFIGURATION_ERROR;
    g->Registers = MmMapIoSpaceEx(gp->u.Memory.Start,0x70000,PAGE_READWRITE|PAGE_NOCACHE);
    g->Smmu = MmMapIoSpaceEx(smmu->u.Memory.Start,0x1000,PAGE_READONLY|PAGE_NOCACHE);
    if (!g->Registers || !g->Smmu) { status = STATUS_INSUFFICIENT_RESOURCES; goto Fail; }
    WDF_INTERRUPT_CONFIG_INIT(&config,GpiIsr,NULL);
    config.PassiveHandling = TRUE;
    config.AutomaticSerialization = FALSE;
    config.InterruptRaw = WdfCmResourceListGetDescriptor(raw,rawIndex);
    config.InterruptTranslated = WdfCmResourceListGetDescriptor(translated,irqIndex);
    config.EvtInterruptEnable = GpiEnable;
    config.EvtInterruptDisable = GpiDisable;
    WDF_OBJECT_ATTRIBUTES_INIT_CONTEXT_TYPE(&attributes,IRQ_CONTEXT);
    status = WdfInterruptCreate(device,&config,&attributes,&g->Interrupt);
    if (!NT_SUCCESS(status)) goto Fail;
    GpiGetIrqContext(g->Interrupt)->Gpi = g;
    g->Io.Context = g;
    g->Io.Read = Read; g->Io.Write = Write; g->Io.Barrier = Barrier;
    g->Io.NowUs = Now; g->Io.Pause = Pause; g->Io.Cancelled = Cancel; g->Io.HardwareError = Error;
    return STATUS_SUCCESS;
Fail:
    (void)GpiWindowsRelease(g);
    return status;
}
NTSTATUS GpiWindowsStart(GPI_WINDOWS *g, ULONG clockSelect)
{
    DEVICE_DESCRIPTION description;
    ULONG maps = 0;
    NTSTATUS status;
    GI_U64 dma;
    g->Io.Stage = 10;
    InterlockedExchange(&g->Error,0);
    if (!DirectDmaAllowed(g)) { status = STATUS_DEVICE_CONFIGURATION_ERROR; goto Exit; }
    GeniRecord(g->Device,L"TimelmGpiDmaBypassVerified",1);
    RtlZeroMemory(&description,sizeof(description));
    description.Version = DEVICE_DESCRIPTION_VERSION3;
    description.Master = TRUE;
    description.ScatterGather = TRUE;
    description.DmaAddressWidth = 64;
    description.InterfaceType = Internal;
    description.MaximumLength = GP_ALLOCATION_SIZE;
    g->Adapter = IoGetDmaAdapter(WdfDeviceWdmGetPhysicalDevice(g->Device),&description,&maps);
    if (!g->Adapter || !g->Adapter->DmaOperations->AllocateCommonBuffer ||
        !g->Adapter->DmaOperations->FreeCommonBuffer ||
        !g->Adapter->DmaOperations->PutDmaAdapter) { status = STATUS_NOT_SUPPORTED; goto Exit; }
    g->Allocation = g->Adapter->DmaOperations->AllocateCommonBuffer(g->Adapter,
        GP_ALLOCATION_SIZE,&g->Logical,FALSE);
    if (!g->Allocation) { status = STATUS_INSUFFICIENT_RESOURCES; goto Exit; }
    dma = (GI_U64)g->Logical.QuadPart;
    /* Addresses submitted to GPI always come from the DMA adapter. In the
     * verified direct-bypass profile require a matching physical backing,
     * rather than submit an IOVA to hardware whose translation is bypassed. */
    if (MmGetPhysicalAddress(g->Allocation).QuadPart != g->Logical.QuadPart ||
        MmGetPhysicalAddress((PUCHAR)g->Allocation+GP_ALLOCATION_SIZE-1).QuadPart !=
            g->Logical.QuadPart+GP_ALLOCATION_SIZE-1 || (dma & 4095u) ||
        (dma >> 32) != ((dma+GP_ALLOCATION_SIZE-1) >> 32)) {
        status = STATUS_DEVICE_CONFIGURATION_ERROR; goto Exit;
    }
    RtlZeroMemory(g->Allocation,GP_ALLOCATION_SIZE);
    g->Io.Events = g->Allocation; g->Io.EventDma = dma;
    g->Io.Tx = (GP_ELEMENT *)((PUCHAR)g->Allocation+4096); g->Io.TxDma = dma+4096;
    g->Io.Rx = (GP_ELEMENT *)((PUCHAR)g->Allocation+5120); g->Io.RxDma = dma+5120;
    g->Io.TxBytes = (PUCHAR)g->Allocation+6144; g->Io.TxBytesDma = dma+6144;
    g->Io.RxBytes = (PUCHAR)g->Allocation+6400; g->Io.RxBytesDma = dma+6400;
    g->Io.ClockSelect = clockSelect;
    status = Status(GpStart(&g->Io));
Exit:
    Record(g,status);
    return status;
}
NTSTATUS GpiWindowsCheckReady(PVOID context)
{
    GPI_WINDOWS *g = context;
    NTSTATUS status = STATUS_SUCCESS;
    if (g->Retained) status = STATUS_DEVICE_BUSY;
    else if (!g->Registers || !g->Smmu || !DirectDmaAllowed(g)) status = STATUS_DEVICE_CONFIGURATION_ERROR;
    else if (((Read(g,GP_CH(0)) | Read(g,GP_CH(1)) | Read(g,GP_EV)) & 0xf00000u) ||
        (Read(g,GP_IRQ_MASK) & 127u)) status = STATUS_DEVICE_BUSY;
    Record(g,status);
    return status;
}
NTSTATUS GpiWindowsTransfer(GPI_WINDOWS *g, SPBREQUEST request, UCHAR *data,
    ULONG length, BOOLEAN read, BOOLEAN hold, ULONGLONG deadline)
{
    NTSTATUS status;
    g->CurrentRequest = request;
    status = Status(GpTransfer(&g->Io,data,length,read,hold,deadline));
    g->CurrentRequest = NULL;
    if (!NT_SUCCESS(status)) { Record(g,status); (void)GpiWindowsStop(g); }
    return status;
}
NTSTATUS GpiWindowsStop(GPI_WINDOWS *g)
{
    NTSTATUS status = STATUS_SUCCESS;
    if (g->Io.EventOwned || g->Io.ChannelOwned[0] || g->Io.ChannelOwned[1])
        status = Status(GpStop(&g->Io));
    GeniRecord(g->Device,L"TimelmGpiStopStatus",(ULONG)status);
    return status;
}
BOOLEAN GpiWindowsRelease(GPI_WINDOWS *g)
{
    BOOLEAN safe = TRUE;
    if (g->Io.Read && !NT_SUCCESS(GpiWindowsStop(g))) safe = FALSE;
    if (g->Interrupt) { WdfObjectDelete(g->Interrupt); g->Interrupt = NULL; }
    if (safe) {
        if (g->Allocation) g->Adapter->DmaOperations->FreeCommonBuffer(g->Adapter,
            GP_ALLOCATION_SIZE,g->Logical,g->Allocation,FALSE);
        if (g->Adapter) g->Adapter->DmaOperations->PutDmaAdapter(g->Adapter);
    } else {
        /* This explicit DMA allocation has no WDF device parent that could
         * auto-free active ring memory. Retain buffer AND adapter until reboot.
         * No code/stack/request memory was ever submitted as a DMA target. */
        g->Retained = TRUE;
        GeniRecord(g->Device,L"TimelmGpiDmaRetainedUntilReboot",1);
    }
    g->Allocation = NULL; g->Adapter = NULL;
    if (g->Registers) { MmUnmapIoSpace(g->Registers,0x70000); g->Registers = NULL; }
    if (g->Smmu) { MmUnmapIoSpace(g->Smmu,0x1000); g->Smmu = NULL; }
    return safe;
}
BOOLEAN GpiIsr(WDFINTERRUPT interrupt, ULONG message)
{
    GPI_WINDOWS *g = GpiGetIrqContext(interrupt)->Gpi;
    ULONG type;
    UNREFERENCED_PARAMETER(message);
    if (!g || !g->Registers || !g->InterruptEnabled) return FALSE;
    type = Read(g,GP_IRQ_TYPE) & 0x4cu;
    if (!type) return FALSE;
    InterlockedIncrement(&g->Irqs);
    if (type & 4u) {
        ULONG error = Read(g,GP_GLOB_STATUS);
        if (error) InterlockedOr(&g->Error,(LONG)error);
        Write(g,GP_GLOB_CLEAR,error);
    }
    if (type & 64u) {
        ULONG error = Read(g,GP_GEN_STATUS);
        if (error) InterlockedOr(&g->Error,(LONG)error);
        Write(g,GP_GEN_CLEAR,error);
    }
    if (type & 8u) Write(g,GP_IEOB_CLEAR,1);
    KeSetEvent(&g->Wake,IO_NO_INCREMENT,FALSE);
    return TRUE;
}
NTSTATUS GpiEnable(WDFINTERRUPT interrupt, WDFDEVICE device)
{
    GPI_WINDOWS *g = GpiGetIrqContext(interrupt)->Gpi;
    UNREFERENCED_PARAMETER(device);
    InterlockedExchange(&g->InterruptEnabled,1);
    Write(g,GP_IRQ_MASK,g->Io.Ready ? 0x4cu : 0);
    return STATUS_SUCCESS;
}
NTSTATUS GpiDisable(WDFINTERRUPT interrupt, WDFDEVICE device)
{
    GPI_WINDOWS *g = GpiGetIrqContext(interrupt)->Gpi;
    UNREFERENCED_PARAMETER(device);
    Write(g,GP_IRQ_MASK,0);
    InterlockedExchange(&g->InterruptEnabled,0);
    return STATUS_SUCCESS;
}
