/* SPDX-License-Identifier: GPL-2.0-only
 * SPBCx glue uses the public DDI demonstrated by Microsoft's SkeletonI2C.
 * No Qualcomm Windows binary or driver source is incorporated. */
#include <ntddk.h>
#include <wdf.h>
#include <spbcx.h>
#include <reshub.h>
#include "geni_fifo.h"
#include "board_windows.h"
#include "gpi_windows.h"
#include "bitbang_windows.h"
#include "trace_windows.h"

typedef struct DEVICE_CONTEXT {
    PUCHAR Registers;
    GI_IO Io;
    SPBREQUEST CurrentRequest;
    BOOLEAN ResourcesReady, Started;
    GENI_BOARD Board;
    GPI_WINDOWS Gpi;
    BOOLEAN UseGpi;
    BOOLEAN UseBitbang;
    BB_WINDOWS Bitbang;
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
EVT_SPB_CONTROLLER_READ GeniRead;
EVT_SPB_CONTROLLER_WRITE GeniWrite;
EVT_SPB_CONTROLLER_SEQUENCE GeniSequence;
NTSTATUS GeniReadOnlyProbe(WDFDEVICE device, WDFCMRESLIST raw, WDFCMRESLIST translated);

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
    return device->CurrentRequest && WdfRequestIsCanceled((WDFREQUEST)device->CurrentRequest);
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

/* AddDevice runs before a device key exists; failures go to the service
 * Parameters key so a Code 31 identifies the failing call. */
static NTSTATUS AddRecord(WDFDRIVER driver, ULONG stage, NTSTATUS status)
{
    WDFKEY key;
    UNICODE_STRING stageName = RTL_CONSTANT_STRING(L"TimelmAddStage");
    UNICODE_STRING statusName = RTL_CONSTANT_STRING(L"TimelmAddStatus");
    if (NT_SUCCESS(WdfDriverOpenParametersRegistryKey(driver, KEY_SET_VALUE,
        WDF_NO_OBJECT_ATTRIBUTES, &key))) {
        (void)WdfRegistryAssignULong(key, &stageName, stage);
        (void)WdfRegistryAssignULong(key, &statusName, (ULONG)status);
        WdfRegistryClose(key);
    }
    return status;
}

NTSTATUS GeniAdd(WDFDRIVER driver, PWDFDEVICE_INIT init)
{
    WDF_PNPPOWER_EVENT_CALLBACKS pnp;
    WDF_OBJECT_ATTRIBUTES attributes;
    WDFDEVICE device;
    SPB_CONTROLLER_CONFIG spb;
    NTSTATUS status;
    status = SpbDeviceInitConfig(init);
    if (!NT_SUCCESS(status)) return AddRecord(driver, 1, status);
    WDF_PNPPOWER_EVENT_CALLBACKS_INIT(&pnp);
    pnp.EvtDevicePrepareHardware = GeniPrepare;
    pnp.EvtDeviceReleaseHardware = GeniRelease;
    pnp.EvtDeviceD0Entry = GeniD0Entry;
    pnp.EvtDeviceD0Exit = GeniD0Exit;
    WdfDeviceInitSetPnpPowerEventCallbacks(init, &pnp);
    WDF_OBJECT_ATTRIBUTES_INIT_CONTEXT_TYPE(&attributes, DEVICE_CONTEXT);
    attributes.ExecutionLevel = WdfExecutionLevelPassive;
    status = WdfDeviceCreate(&init, &attributes, &device);
    if (!NT_SUCCESS(status)) return AddRecord(driver, 2, status);
    SPB_CONTROLLER_CONFIG_INIT(&spb);
    spb.ControllerDispatchType = WdfIoQueueDispatchSequential;
    spb.PowerManaged = WdfTrue;
    spb.EvtSpbTargetConnect = GeniConnect;
    spb.EvtSpbIoRead = GeniRead;
    spb.EvtSpbIoWrite = GeniWrite;
    spb.EvtSpbIoSequence = GeniSequence;
    /* Separate lock/unlock requests are unsupported. Atomic sequences only. */
    status = SpbDeviceInitialize(device, &spb);
    if (!NT_SUCCESS(status)) return AddRecord(driver, 3, status);
    {
        WDF_DEVICE_POWER_POLICY_IDLE_SETTINGS idle;
        WDF_DEVICE_POWER_POLICY_IDLE_SETTINGS_INIT(&idle,IdleCannotWakeFromS0);
        idle.Enabled = WdfFalse; /* no resume lifecycle yet */
        /* Idle is disabled anyway; a refusal must not block the SPB host. */
        status = WdfDeviceAssignS0IdleSettings(device,&idle);
        GeniRecord(device, L"TimelmIdleStatus", (ULONG)status);
    }
    return AddRecord(driver, 4, STATUS_SUCCESS);
}

NTSTATUS GeniPrepare(WDFDEVICE device, WDFCMRESLIST raw, WDFCMRESLIST translated)
{
    DEVICE_CONTEXT *context = GetDeviceContext(device);
    WDFKEY key;
    ULONG verified = 0, sourceHz = 0, native = 0, gpi = 0, iommu = 0, probe = 0, bitbang = 0, i, memoryCount = 0;
    NTSTATUS status;
    UNICODE_STRING handoffName = RTL_CONSTANT_STRING(L"FirmwareHandoffVerified");
    UNICODE_STRING clockName = RTL_CONSTANT_STRING(L"SourceClockHz");
    UNICODE_STRING nativeName = RTL_CONSTANT_STRING(L"NativeBoardInitEnabled");
    UNICODE_STRING gpiName = RTL_CONSTANT_STRING(L"NativeGpiEnabled");
    UNICODE_STRING iommuName = RTL_CONSTANT_STRING(L"WindowsIommuEnabled");
    UNICODE_STRING probeName = RTL_CONSTANT_STRING(L"ReadOnlyHardwareProbeEnabled");
    UNICODE_STRING bitbangName = RTL_CONSTANT_STRING(L"NativeGpioI2cEnabled");
    PCM_PARTIAL_RESOURCE_DESCRIPTOR memory = NULL;
    if(context->ResourcesReady || context->Bitbang.Retained || context->Bitbang.Acquired ||
       context->Gpi.Dma.Retained || context->Gpi.Io.Unsafe) return STATUS_DEVICE_BUSY;
    context->UseBitbang=FALSE;
    context->UseGpi=FALSE;
    context->Gpi.UseIommu=FALSE;
    GeniRecord(device, L"TimelmHostStage", 1);
    /* Native board init is a separate opt-in from inherited firmware state.
     * Both paths are disabled in the default INF and require real ACPI. */
    status = WdfDeviceOpenRegistryKey(device, PLUGPLAY_REGKEY_DEVICE,
        KEY_READ, WDF_NO_OBJECT_ATTRIBUTES, &key);
    if (!NT_SUCCESS(status)) return status;
    (void)WdfRegistryQueryULong(key, &nativeName, &native);
    (void)WdfRegistryQueryULong(key, &gpiName, &gpi);
    (void)WdfRegistryQueryULong(key, &iommuName, &iommu);
    (void)WdfRegistryQueryULong(key, &probeName, &probe);
    (void)WdfRegistryQueryULong(key, &bitbangName, &bitbang);
    status = WdfRegistryQueryULong(key, &handoffName, &verified);
    if (NT_SUCCESS(status)) status = WdfRegistryQueryULong(key, &clockName, &sourceHz);
    WdfRegistryClose(key);
    /* The gate values are written to a file that survives a bugcheck: the
     * registry itself is lost when the kernel goes down. */
    TimelmTraceValue("gate-bitbang", bitbang);
    TimelmTraceValue("gate-probe", probe);
    TimelmTraceValue("gate-native", native);
    TimelmTraceValue("gate-gpi", gpi);
    TimelmTraceValue("gate-iommu", iommu);
    TimelmTraceValue("gate-verified", verified);
    TimelmTraceValue("gate-sourcehz", sourceHz);
    /* One value naming the active backend of this boot: 0 disabled,
     * 1=GPIO bitbang, 2=probe, 3=native FIFO, 4=GPI. Registry snapshot only. */
    GeniRecord(device, L"TimelmHostBackend",
        bitbang ? 1u : probe ? 2u : gpi ? 4u : native ? 3u : 0u);
    if (bitbang) {
        if(bitbang!=1 || probe || native || gpi || iommu || verified || sourceHz)
            return STATUS_DEVICE_CONFIGURATION_ERROR;
        context->UseBitbang=TRUE;
        TimelmTrace("bb-prepare-enter");
        status=BbWindowsPrepare(&context->Bitbang,device,translated);
        context->ResourcesReady=NT_SUCCESS(status);
        GeniRecord(device,L"TimelmHostStatus",(ULONG)status);
        TimelmTraceStatus("bb-prepare-exit", status);
        return status;
    }
    if (probe) {
        if (probe!=1 || native || gpi || iommu || verified || sourceHz)
            return STATUS_DEVICE_CONFIGURATION_ERROR;
        return GeniReadOnlyProbe(device,raw,translated);
    }
    if (gpi > 1 || (gpi == 1 && native != 1)) return STATUS_DEVICE_CONFIGURATION_ERROR;
    if (iommu > 1 || (iommu == 1 && gpi != 1)) return STATUS_DEVICE_CONFIGURATION_ERROR;
    context->UseGpi = gpi == 1;
    context->Gpi.UseIommu = iommu == 1;
    if (native != 1 && (!NT_SUCCESS(status) || verified != 1 || sourceHz != 19200000u)) {
        GeniRecord(device, L"TimelmHostStatus", (ULONG)STATUS_DEVICE_NOT_READY);
        return STATUS_DEVICE_NOT_READY;
    }
    for (i = 0; i < WdfCmResourceListGetCount(translated); ++i) {
        PCM_PARTIAL_RESOURCE_DESCRIPTOR r = WdfCmResourceListGetDescriptor(translated, i);
        if (r && r->Type == CmResourceTypeMemory) {
            ++memoryCount;
            if (r->u.Memory.Start.QuadPart == 0xa94000) memory = r;
        }
    }
    if (memoryCount != (iommu == 1 ? 4u : gpi == 1 ? 5u : native == 1 ? 3u : 1u) || !memory ||
        memory->u.Memory.Length != 0x4000) return STATUS_DEVICE_CONFIGURATION_ERROR;
    if (native == 1) {
        context->Board.GpiMode = context->UseGpi;
        context->Board.IommuMode = iommu == 1;
        status = GeniBoardPrepare(&context->Board, device, translated);
        if (!NT_SUCCESS(status)) return status;
    }
    if (context->UseGpi) {
        status = GpiWindowsPrepare(&context->Gpi,device,raw,translated);
        if (!NT_SUCCESS(status)) { GeniBoardRelease(&context->Board); return status; }
        context->Board.PrePowerCheck = GpiWindowsCheckReady;
        context->Board.PrePowerContext = &context->Gpi;
    }
    context->Registers = MmMapIoSpaceEx(memory->u.Memory.Start, 0x4000,
        PAGE_READWRITE | PAGE_NOCACHE);
    if (!context->Registers) {
        if (context->UseGpi) (void)GpiWindowsRelease(&context->Gpi);
        if (context->Board.Native) GeniBoardRelease(&context->Board);
        return STATUS_INSUFFICIENT_RESOURCES;
    }
    context->ResourcesReady = TRUE;
    context->Io.Context = context;
    context->Io.Read = ReadRegister;
    context->Io.Write = WriteRegister;
    context->Io.NowUs = NowUs;
    context->Io.Cancelled = Cancelled;
    context->Io.Pause = Pause;
    context->Started = FALSE;
    GeniRecord(device, L"TimelmHostStage", 2);
    return STATUS_SUCCESS;
}

NTSTATUS GeniRelease(WDFDEVICE device, WDFCMRESLIST resources)
{
    DEVICE_CONTEXT *context = GetDeviceContext(device);
    UNREFERENCED_PARAMETER(resources);
    context->Io.Ready = 0;
    context->ResourcesReady = FALSE;
    if(context->UseBitbang) return BbWindowsRelease(&context->Bitbang)?STATUS_SUCCESS:STATUS_DEVICE_BUSY;
    {
        BOOLEAN safe = !context->UseGpi || GpiWindowsRelease(&context->Gpi);
        if (context->Board.Native) {
            if (safe) GeniBoardRelease(&context->Board);
            else GeniBoardAbandon(&context->Board);
        }
    }
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
    NTSTATUS status;
    ULONG select = 0;
    UNREFERENCED_PARAMETER(previous);
    if (!context->ResourcesReady || context->Started) return STATUS_DEVICE_NOT_READY;
    if(context->UseBitbang) {
        TimelmTrace("bb-start-enter");
        status=BbWindowsStart(&context->Bitbang);
        context->Started=NT_SUCCESS(status);
        GeniRecord(device,L"TimelmHostStage",NT_SUCCESS(status)?4u:3u);
        GeniRecord(device,L"TimelmHostStatus",(ULONG)status);
        TimelmTraceStatus("bb-start-exit", status);
        return status;
    }
    if (context->Board.Native) {
        status = GeniBoardStart(&context->Board, context->Registers, &select);
        if (!NT_SUCCESS(status)) return status;
    }
    context->Io.ClockSelect = select;
    GeniRecord(device, L"TimelmHostStage", 3);
    GeniRecord(device, L"TimelmGeniFirmware", ReadRegister(context, GI_FW_REV));
    GeniRecord(device, L"TimelmGeniFifoDisabled", ReadRegister(context, GI_IF_DISABLE));
    if (context->UseGpi) {
        status = GpiWindowsStart(&context->Gpi,select);
        if (NT_SUCCESS(status)) {
            /* Rings are owned/empty before enabling GENI's GPI event path. */
            status = ResultStatus(GiConfigureGpi(&context->Io));
            if (NT_SUCCESS(status)) status = GeniBoardConfirmClock(&context->Board);
        }
        if (!NT_SUCCESS(status)) {
            if (NT_SUCCESS(GpiWindowsStop(&context->Gpi))) (void)GeniBoardStop(&context->Board);
        } else context->Started = TRUE;
        GeniRecord(device,L"TimelmHostStage",NT_SUCCESS(status) ? 4u : 3u);
        GeniRecord(device,L"TimelmHostStatus",(ULONG)status);
        return status;
    }
    result = GiInitialize(&context->Io);
    if (result == GiOk && context->Board.Native &&
        !NT_SUCCESS(GeniBoardConfirmClock(&context->Board))) {
        WriteRegister(context, GI_IRQ_ENABLE, 0);
        context->Io.Ready = 0;
        result = GiNotReady;
    }
    if (result == GiOk) context->Started = TRUE;
    else if (context->Board.Native) (void)GeniBoardStop(&context->Board);
    status = ResultStatus(result);
    GeniRecord(device, L"TimelmHostStage", result == GiOk ? 4 : 3);
    GeniRecord(device, L"TimelmHostStatus", (ULONG)status);
    return status;
}
NTSTATUS GeniD0Exit(WDFDEVICE device, WDF_POWER_DEVICE_STATE next)
{
    DEVICE_CONTEXT *context = GetDeviceContext(device);
    UNREFERENCED_PARAMETER(next);
    if(context->UseBitbang) {context->Started=FALSE;return BbWindowsStop(&context->Bitbang);}
    if (context->UseGpi) {
        NTSTATUS status = GpiWindowsStop(&context->Gpi);
        if (!NT_SUCCESS(status)) return status;
        WriteRegister(context,GI_GSI_EVENT,0);
        WriteRegister(context,GI_DMA_MODE,0);
        context->Started = FALSE;
        return GeniBoardStop(&context->Board);
    }
    if (context->Io.Ready) {
        if (ReadRegister(context, GI_STATUS) & 1u) (void)GiAbort(&context->Io);
        WriteRegister(context, GI_IRQ_ENABLE, 0);
        WriteRegister(context, GI_IRQ_GATE, 0);
        context->Io.Ready = 0;
    }
    if (context->Board.Native) return GeniBoardStop(&context->Board);
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
    if(context->UseBitbang) {
        BB_MESSAGE messages[2];
        for(i=0;i<count;++i) {
            messages[i].Bytes=transfers[i].Bytes;
            messages[i].Length=(GI_U32)transfers[i].Descriptor.TransferLength;
            messages[i].Read=transfers[i].Descriptor.Direction==SpbTransferDirectionFromDevice;
        }
        status=BbWindowsTransfer(&context->Bitbang,(WDFREQUEST)request,messages,count);
        if(NT_SUCCESS(status)) {
            for(i=0;i<count;++i) {
                TRANSFER *t=&transfers[i];ULONG j,offset=0;
                if(messages[i].Read) for(j=0;j<t->SegmentCount;++j) {
                    ULONG n=t->Segments[j].Length;
                    RtlCopyMemory(t->Segments[j].Address,t->Bytes+offset,n);offset+=n;
                }
                information+=t->Descriptor.TransferLength;
            }
        }
        WdfRequestSetInformation((WDFREQUEST)request,information);
        SpbRequestComplete(request,status);return;
    }
    context->CurrentRequest = request;
    deadline = NowUs(context) + 50000u;
    for (i = 0; i < count; ++i) {
        TRANSFER *transfer = &transfers[i];
        BOOLEAN read = transfer->Descriptor.Direction == SpbTransferDirectionFromDevice;
        if (context->UseGpi) {
            status = GpiWindowsTransfer(&context->Gpi,request,transfer->Bytes,
                (ULONG)transfer->Descriptor.TransferLength,read,i+1u<count,deadline);
        } else {
            enum GI_RESULT result = GiTransfer(&context->Io, transfer->Bytes,
                (GI_U32)transfer->Descriptor.TransferLength, read, i + 1u < count, deadline);
            status = ResultStatus(result);
        }
        if (!NT_SUCCESS(status)) {
            if (!context->UseGpi && context->Io.Ready) (void)GiAbort(&context->Io);
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
    WdfRequestSetInformation((WDFREQUEST)request, information);
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
