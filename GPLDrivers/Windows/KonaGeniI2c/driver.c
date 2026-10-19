/* SPDX-License-Identifier: GPL-2.0-only
 * SPBCx glue uses the public DDI demonstrated by Microsoft's SkeletonI2C.
 * No Qualcomm Windows binary or driver source is incorporated. */
#include <ntddk.h>
#include <wdf.h>
#include <spbcx.h>
#include <reshub.h>
#include "geni_fifo.h"

typedef struct DEVICE_CONTEXT {
    PUCHAR Registers;
    GI_IO Io;
    SPBREQUEST CurrentRequest;
    BOOLEAN HandoffVerified, Started;
} DEVICE_CONTEXT;
WDF_DECLARE_CONTEXT_TYPE_WITH_NAME(DEVICE_CONTEXT, GetDeviceContext)

#pragma pack(push, 1)
typedef struct I2C_CONNECTION {
    PNP_SERIAL_BUS_DESCRIPTOR Descriptor;
    ULONG Speed;
    USHORT Address;
} I2C_CONNECTION;
#pragma pack(pop)

DRIVER_INITIALIZE DriverEntry;
EVT_WDF_DRIVER_DEVICE_ADD GeniAdd;
EVT_WDF_DEVICE_PREPARE_HARDWARE GeniPrepare;
EVT_WDF_DEVICE_RELEASE_HARDWARE GeniRelease;
EVT_WDF_DEVICE_D0_ENTRY GeniD0Entry;
EVT_WDF_DEVICE_D0_EXIT GeniD0Exit;
EVT_SPB_TARGET_CONNECT GeniConnect;
EVT_SPB_CONTROLLER_IO_READ GeniRead;
EVT_SPB_CONTROLLER_IO_WRITE GeniWrite;
EVT_SPB_CONTROLLER_IO_SEQUENCE GeniSequence;

static GI_U32 ReadRegister(void *context, GI_U32 offset)
{
    DEVICE_CONTEXT *device = context;
    return READ_REGISTER_ULONG((PULONG)(device->Registers + offset));
}
static void WriteRegister(void *context, GI_U32 offset, GI_U32 value)
{
    DEVICE_CONTEXT *device = context;
    WRITE_REGISTER_ULONG((PULONG)(device->Registers + offset), value);
}
static GI_U64 NowUs(void *context)
{
    UNREFERENCED_PARAMETER(context);
    return KeQueryInterruptTime() / 10u;
}
static int Cancelled(void *context)
{
    DEVICE_CONTEXT *device = context;
    return device->CurrentRequest && WdfRequestIsCanceled(device->CurrentRequest);
}
static void Pause(void *context)
{
    UNREFERENCED_PARAMETER(context);
    KeStallExecutionProcessor(20); /* bounded bring-up polling, not streaming */
}
static NTSTATUS ResultStatus(enum GI_RESULT result)
{
    switch (result) {
    case GiOk: return STATUS_SUCCESS;
    case GiNotReady: return STATUS_DEVICE_NOT_READY;
    case GiInvalid: return STATUS_INVALID_PARAMETER;
    case GiNack: return STATUS_NO_SUCH_DEVICE;
    case GiTimeout: return STATUS_IO_TIMEOUT;
    case GiCancelled: return STATUS_CANCELLED;
    default: return STATUS_IO_DEVICE_ERROR;
    }
}

NTSTATUS DriverEntry(PDRIVER_OBJECT object, PUNICODE_STRING path)
{
    WDF_DRIVER_CONFIG config;
    WDF_DRIVER_CONFIG_INIT(&config, GeniAdd);
    return WdfDriverCreate(object, path, WDF_NO_OBJECT_ATTRIBUTES, &config, WDF_NO_HANDLE);
}

NTSTATUS GeniAdd(WDFDRIVER driver, PWDFDEVICE_INIT init)
{
    WDF_PNPPOWER_EVENT_CALLBACKS pnp;
    WDF_OBJECT_ATTRIBUTES attributes;
    WDFDEVICE device;
    SPB_CONTROLLER_CONFIG spb;
    NTSTATUS status;
    UNREFERENCED_PARAMETER(driver);
    status = SpbDeviceInitConfig(init);
    if (!NT_SUCCESS(status)) return status;
    WDF_PNPPOWER_EVENT_CALLBACKS_INIT(&pnp);
    pnp.EvtDevicePrepareHardware = GeniPrepare;
    pnp.EvtDeviceReleaseHardware = GeniRelease;
    pnp.EvtDeviceD0Entry = GeniD0Entry;
    pnp.EvtDeviceD0Exit = GeniD0Exit;
    WdfDeviceInitSetPnpPowerEventCallbacks(init, &pnp);
    WDF_OBJECT_ATTRIBUTES_INIT_CONTEXT_TYPE(&attributes, DEVICE_CONTEXT);
    attributes.ExecutionLevel = WdfExecutionLevelPassive;
    attributes.SynchronizationScope = WdfSynchronizationScopeDevice;
    status = WdfDeviceCreate(&init, &attributes, &device);
    if (!NT_SUCCESS(status)) return status;
    SPB_CONTROLLER_CONFIG_INIT(&spb);
    spb.ControllerDispatchType = WdfIoQueueDispatchSequential;
    spb.PowerManaged = WdfTrue;
    spb.EvtSpbTargetConnect = GeniConnect;
    spb.EvtSpbIoRead = GeniRead;
    spb.EvtSpbIoWrite = GeniWrite;
    spb.EvtSpbIoSequence = GeniSequence;
    /* Separate lock/unlock requests are unsupported. Atomic sequences only. */
    return SpbDeviceInitialize(device, &spb);
}

NTSTATUS GeniPrepare(WDFDEVICE device, WDFCMRESLIST raw, WDFCMRESLIST translated)
{
    DEVICE_CONTEXT *context = GetDeviceContext(device);
    WDFKEY key;
    ULONG verified = 0, sourceHz = 0, i, memoryCount = 0;
    NTSTATUS status;
    UNICODE_STRING handoffName = RTL_CONSTANT_STRING(L"FirmwareHandoffVerified");
    UNICODE_STRING clockName = RTL_CONSTANT_STRING(L"SourceClockHz");
    PCM_PARTIAL_RESOURCE_DESCRIPTOR memory = NULL;
    UNREFERENCED_PARAMETER(raw);
    /* This gate precedes ALL MMIO reads. It is intentionally off in the INF.
     * A successful build does not establish clocks, ownership or pinmux. */
    status = WdfDeviceOpenRegistryKey(device, PLUGPLAY_REGKEY_DEVICE,
        KEY_READ, WDF_NO_OBJECT_ATTRIBUTES, &key);
    if (!NT_SUCCESS(status)) return status;
    status = WdfRegistryQueryULong(key, &handoffName, &verified);
    if (NT_SUCCESS(status)) status = WdfRegistryQueryULong(key, &clockName, &sourceHz);
    WdfRegistryClose(key);
    if (!NT_SUCCESS(status) || verified != 1 || sourceHz != 19200000u)
        return STATUS_DEVICE_NOT_READY;
    for (i = 0; i < WdfCmResourceListGetCount(translated); ++i) {
        PCM_PARTIAL_RESOURCE_DESCRIPTOR r = WdfCmResourceListGetDescriptor(translated, i);
        if (r && r->Type == CmResourceTypeMemory) { memory = r; ++memoryCount; }
    }
    if (memoryCount != 1 || memory->u.Memory.Start.QuadPart != 0xa94000 ||
        memory->u.Memory.Length != 0x4000) return STATUS_DEVICE_CONFIGURATION_ERROR;
    context->Registers = MmMapIoSpaceEx(memory->u.Memory.Start, 0x4000,
        PAGE_READWRITE | PAGE_NOCACHE);
    if (!context->Registers) return STATUS_INSUFFICIENT_RESOURCES;
    context->HandoffVerified = TRUE;
    context->Io.Context = context;
    context->Io.Read = ReadRegister;
    context->Io.Write = WriteRegister;
    context->Io.NowUs = NowUs;
    context->Io.Cancelled = Cancelled;
    context->Io.Pause = Pause;
    return STATUS_SUCCESS;
}

NTSTATUS GeniRelease(WDFDEVICE device, WDFCMRESLIST resources)
{
    DEVICE_CONTEXT *context = GetDeviceContext(device);
    UNREFERENCED_PARAMETER(resources);
    context->Io.Ready = 0;
    context->HandoffVerified = FALSE;
    if (context->Registers) {
        MmUnmapIoSpace(context->Registers, 0x4000);
        context->Registers = NULL;
    }
    return STATUS_SUCCESS;
}

NTSTATUS GeniD0Entry(WDFDEVICE device, WDF_POWER_DEVICE_STATE previous)
{
    DEVICE_CONTEXT *context = GetDeviceContext(device);
    enum GI_RESULT result;
    UNREFERENCED_PARAMETER(previous);
    if (!context->HandoffVerified || context->Started) return STATUS_DEVICE_NOT_READY;
    result = GiInitialize(&context->Io);
    if (result == GiOk) context->Started = TRUE;
    return ResultStatus(result);
}
NTSTATUS GeniD0Exit(WDFDEVICE device, WDF_POWER_DEVICE_STATE next)
{
    DEVICE_CONTEXT *context = GetDeviceContext(device);
    UNREFERENCED_PARAMETER(next);
    if (context->Io.Ready) {
        WriteRegister(context, GI_IRQ_ENABLE, 0);
        WriteRegister(context, GI_IRQ_GATE, 0);
        context->Io.Ready = 0;
    }
    return STATUS_SUCCESS;
}

NTSTATUS GeniConnect(WDFDEVICE device, SPBTARGET target)
{
    SPB_CONNECTION_PARAMETERS parameters;
    PRH_QUERY_CONNECTION_PROPERTIES_OUTPUT_BUFFER connection;
    I2C_CONNECTION descriptor;
    UNREFERENCED_PARAMETER(device);
    SPB_CONNECTION_PARAMETERS_INIT(&parameters);
    SpbTargetGetConnectionParameters(target, &parameters);
    connection = parameters.ConnectionParameters;
    if (!connection || connection->PropertiesLength < sizeof(descriptor))
        return STATUS_INVALID_PARAMETER;
    RtlCopyMemory(&descriptor, connection->ConnectionProperties, sizeof(descriptor));
    if (descriptor.Descriptor.SerialBusType != 1 ||
        (descriptor.Descriptor.TypeSpecificFlags & 1u) ||
        descriptor.Address != 0x28 || descriptor.Speed != 100000u)
        return STATUS_NOT_SUPPORTED;
    return STATUS_SUCCESS;
}

/* Pre-map complete MDL chains before starting an atomic sequence. No mapping
 * or length failure can strand a previous transfer with STOP_STRETCH set. */
typedef struct TRANSFER {
    SPB_TRANSFER_DESCRIPTOR Descriptor;
    struct { PUCHAR Address; ULONG Length; } Segments[8];
    ULONG SegmentCount;
    UCHAR Bytes[GI_MAX_BYTES];
} TRANSFER;

static NTSTATUS PrepareTransfer(SPBREQUEST request, ULONG index, TRANSFER *transfer)
{
    PMDL mdl;
    size_t remaining;
    SPB_TRANSFER_DESCRIPTOR_INIT(&transfer->Descriptor);
    SpbRequestGetTransferParameters(request, index, &transfer->Descriptor, &mdl);
    remaining = transfer->Descriptor.TransferLength;
    if (!remaining || remaining > GI_MAX_BYTES || transfer->Descriptor.DelayInUs ||
        (transfer->Descriptor.Direction != SpbTransferDirectionFromDevice &&
         transfer->Descriptor.Direction != SpbTransferDirectionToDevice)) return STATUS_NOT_SUPPORTED;
    transfer->SegmentCount = 0;
    while (remaining && mdl) {
        ULONG count = MmGetMdlByteCount(mdl), slot = transfer->SegmentCount;
        PUCHAR address;
        if (!count || slot >= 8) return STATUS_INVALID_BUFFER_SIZE;
        if (count > remaining) count = (ULONG)remaining;
        address = MmGetSystemAddressForMdlSafe(mdl, NormalPagePriority | MdlMappingNoExecute);
        if (!address) return STATUS_INSUFFICIENT_RESOURCES;
        transfer->Segments[slot].Address = address;
        transfer->Segments[slot].Length = count;
        ++transfer->SegmentCount;
        remaining -= count;
        mdl = mdl->Next;
    }
    if (remaining) return STATUS_INVALID_BUFFER_SIZE;
    if (transfer->Descriptor.Direction == SpbTransferDirectionToDevice) {
        ULONG i, offset = 0;
        for (i = 0; i < transfer->SegmentCount; ++i) {
            ULONG count = transfer->Segments[i].Length;
            RtlCopyMemory(transfer->Bytes + offset, transfer->Segments[i].Address, count);
            offset += count;
        }
    }
    return STATUS_SUCCESS;
}

static void Execute(WDFDEVICE device, SPBREQUEST request, ULONG count)
{
    DEVICE_CONTEXT *context = GetDeviceContext(device);
    TRANSFER transfers[2];
    SPB_REQUEST_PARAMETERS parameters;
    ULONG i;
    ULONG_PTR information = 0;
    NTSTATUS status = STATUS_SUCCESS;
    GI_U64 deadline;
    if (KeGetCurrentIrql() != PASSIVE_LEVEL || count < 1 || count > 2) {
        SpbRequestComplete(request, STATUS_NOT_SUPPORTED); return;
    }
    SPB_REQUEST_PARAMETERS_INIT(&parameters);
    SpbRequestGetParameters(request, &parameters);
    if (parameters.Position != SpbRequestSequencePositionSingle) {
        SpbRequestComplete(request, STATUS_NOT_SUPPORTED); return;
    }
    for (i = 0; i < count; ++i) {
        status = PrepareTransfer(request, i, &transfers[i]);
        if (!NT_SUCCESS(status)) break;
    }
    if (!NT_SUCCESS(status)) { SpbRequestComplete(request, status); return; }
    context->CurrentRequest = request;
    deadline = NowUs(context) + 50000u;
    for (i = 0; i < count; ++i) {
        TRANSFER *transfer = &transfers[i];
        BOOLEAN read = transfer->Descriptor.Direction == SpbTransferDirectionFromDevice;
        enum GI_RESULT result = GiTransfer(&context->Io, transfer->Bytes,
            (GI_U32)transfer->Descriptor.TransferLength, read, i + 1u < count, deadline);
        status = ResultStatus(result);
        if (!NT_SUCCESS(status)) {
            if (context->Io.Ready) (void)GiAbort(&context->Io);
            break;
        }
        if (read) {
            ULONG j, offset = 0;
            for (j = 0; j < transfer->SegmentCount; ++j) {
                ULONG length = transfer->Segments[j].Length;
                RtlCopyMemory(transfer->Segments[j].Address, transfer->Bytes + offset, length);
                offset += length;
            }
        }
        information += transfer->Descriptor.TransferLength;
    }
    context->CurrentRequest = NULL;
    WdfRequestSetInformation(request, information);
    SpbRequestComplete(request, status);
}
void GeniRead(WDFDEVICE device, SPBTARGET target, SPBREQUEST request, size_t length)
{
    UNREFERENCED_PARAMETER(target); UNREFERENCED_PARAMETER(length);
    Execute(device, request, 1);
}
void GeniWrite(WDFDEVICE device, SPBTARGET target, SPBREQUEST request, size_t length)
{
    UNREFERENCED_PARAMETER(target); UNREFERENCED_PARAMETER(length);
    Execute(device, request, 1);
}
void GeniSequence(WDFDEVICE device, SPBTARGET target, SPBREQUEST request, ULONG count)
{
    UNREFERENCED_PARAMETER(target);
    Execute(device, request, count);
}
