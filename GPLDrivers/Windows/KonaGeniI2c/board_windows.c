/* SPDX-License-Identifier: GPL-2.0-only */
#include <ntddk.h>
#include <wdf.h>
#include <initguid.h>
#include <gpio.h>
#include <acpiioct.h>
#define RESHUB_USE_HELPER_ROUTINES
#include <reshub.h>
#include "board_windows.h"
DEFINE_GUID(GUID_TIMELM_GPIO_PROVIDER,
    0x3d4f477b, 0x4937, 0x407b, 0x93, 0x29, 0xf7, 0xc8, 0x8c, 0x9a, 0x01, 0x88);

VOID GeniRecord(WDFDEVICE device, PCWSTR label, ULONG value)
{
    WDFKEY key;
    UNICODE_STRING name;
    if (NT_SUCCESS(WdfDeviceOpenRegistryKey(device, PLUGPLAY_REGKEY_DEVICE,
        KEY_SET_VALUE, WDF_NO_OBJECT_ATTRIBUTES, &key))) {
        RtlInitUnicodeString(&name, label);
        (void)WdfRegistryAssignULong(key, &name, value);
        WdfRegistryClose(key);
    }
}
static GI_U32 ClockRead(void *context, GI_U32 offset)
{
    GENI_BOARD *b = context;
    return READ_REGISTER_ULONG((PULONG)(offset == TC_VOTE ?
        b->GccVote + 8 : b->GccCore + offset - 0x18000u));
}
static void ClockWrite(void *context, GI_U32 offset, GI_U32 value)
{
    GENI_BOARD *b = context;
    WRITE_REGISTER_ULONG((PULONG)(offset == TC_VOTE ?
        b->GccVote + 8 : b->GccCore + offset - 0x18000u), value);
}
static void DelayUs(void *context, GI_U32 count)
{
    UNREFERENCED_PARAMETER(context);
    KeStallExecutionProcessor(count);
}
static void DelayMs(void *context, unsigned count)
{
    LARGE_INTEGER interval;
    UNREFERENCED_PARAMETER(context);
    interval.QuadPart = -10000LL * count;
    (void)KeDelayExecutionThread(KernelMode, FALSE, &interval);
}
static int Pin(void *context, enum TB_PIN pin, int high)
{
    GENI_BOARD *b = context;
    UCHAR value = high ? 1 : 0;
    WDF_MEMORY_DESCRIPTOR memory;
    WDF_REQUEST_SEND_OPTIONS options;
    NTSTATUS status;
    ULONG_PTR transferred = 0;
    if ((unsigned)pin > TbVdd || !b->Pins[pin]) return 0;
    WDF_MEMORY_DESCRIPTOR_INIT_BUFFER(&memory, &value, sizeof(value));
    WDF_REQUEST_SEND_OPTIONS_INIT(&options, WDF_REQUEST_SEND_OPTION_TIMEOUT);
    WDF_REQUEST_SEND_OPTIONS_SET_TIMEOUT(&options, WDF_REL_TIMEOUT_IN_MS(100));
    status = WdfIoTargetSendIoctlSynchronously(b->Pins[pin], NULL,
        IOCTL_GPIO_WRITE_PINS, &memory, &memory, &options, &transferred);
    if (NT_SUCCESS(status) && transferred != sizeof(value)) status = STATUS_DEVICE_DATA_ERROR;
    if (!NT_SUCCESS(status) && NT_SUCCESS(b->LastStatus)) b->LastStatus = status;
    return NT_SUCCESS(status);
}
static int Mux(void *context, int enable)
{
    GENI_BOARD *b = context;
    NTSTATUS status = b->Bus.SetBus(b->Bus.Interface.Context, enable ? TRUE : FALSE);
    if (!NT_SUCCESS(status) && NT_SUCCESS(b->LastStatus)) b->LastStatus = status;
    if (enable && status == STATUS_IO_DEVICE_ERROR)
        (void)b->Bus.SetBus(b->Bus.Interface.Context, FALSE);
    return NT_SUCCESS(status);
}
static int EngineReady(void *context)
{
    GENI_BOARD *b = context;
    ULONG firmware = READ_REGISTER_ULONG((PULONG)(b->Engine + GI_FW_REV));
    ULONG fifo = READ_REGISTER_ULONG((PULONG)(b->Engine + GI_IF_DISABLE));
    ULONG state = READ_REGISTER_ULONG((PULONG)(b->Engine + GI_STATUS));
    GeniRecord(b->Device, L"TimelmGeniFirmware", firmware);
    GeniRecord(b->Device, L"TimelmGeniFifoDisabled", fifo);
    GeniRecord(b->Device, L"TimelmGeniState", state);
    /* Do not power/reset the peripheral or load unverified SE firmware when
     * ownership/protocol/FIFO prerequisites are absent. GPI-only is distinct. */
    return ((firmware >> 8) & 255u) == 3u && !(fifo & 1u) && !(state & 0x1001u);
}
static NTSTATUS Contract(WDFDEVICE device)
{
    ACPI_EVAL_INPUT_BUFFER input;
    UCHAR bytes[sizeof(ACPI_EVAL_OUTPUT_BUFFER) + sizeof(ULONG)] = {0};
    PACPI_EVAL_OUTPUT_BUFFER output = (PACPI_EVAL_OUTPUT_BUFFER)bytes;
    WDF_MEMORY_DESCRIPTOR in, out;
    WDF_REQUEST_SEND_OPTIONS options;
    ULONG_PTR returned = 0;
    NTSTATUS status;
    RtlZeroMemory(&input, sizeof(input));
    input.Signature = ACPI_EVAL_INPUT_BUFFER_SIGNATURE;
    input.MethodNameAsUlong = (ULONG)'FCBT'; /* TBCF */
    WDF_MEMORY_DESCRIPTOR_INIT_BUFFER(&in, &input, sizeof(input));
    WDF_MEMORY_DESCRIPTOR_INIT_BUFFER(&out, output, sizeof(bytes));
    WDF_REQUEST_SEND_OPTIONS_INIT(&options, WDF_REQUEST_SEND_OPTION_TIMEOUT);
    WDF_REQUEST_SEND_OPTIONS_SET_TIMEOUT(&options, WDF_REL_TIMEOUT_IN_MS(100));
    status = WdfIoTargetSendIoctlSynchronously(WdfDeviceGetIoTarget(device), NULL,
        IOCTL_ACPI_EVAL_METHOD, &in, &out, &options, &returned);
    if (!NT_SUCCESS(status)) return status;
    if (returned < sizeof(ACPI_EVAL_OUTPUT_BUFFER) || returned > sizeof(bytes) ||
        output->Signature != ACPI_EVAL_OUTPUT_BUFFER_SIGNATURE || output->Count != 1 ||
        output->Length > returned || output->Argument[0].Type != ACPI_METHOD_ARGUMENT_INTEGER ||
        output->Argument[0].Argument != 0x54420101u) return STATUS_DEVICE_CONFIGURATION_ERROR;
    return STATUS_SUCCESS;
}
static NTSTATUS OpenPin(GENI_BOARD *b, LARGE_INTEGER id, ULONG index)
{
    DECLARE_UNICODE_STRING_SIZE(path, RESOURCE_HUB_PATH_SIZE);
    WDF_OBJECT_ATTRIBUTES attributes;
    WDF_IO_TARGET_OPEN_PARAMS open;
    NTSTATUS status;
    status = RESOURCE_HUB_CREATE_PATH_FROM_ID(&path, id.LowPart, id.HighPart);
    if (!NT_SUCCESS(status)) return status;
    WDF_OBJECT_ATTRIBUTES_INIT(&attributes);
    status = WdfIoTargetCreate(b->Device, &attributes, &b->Pins[index]);
    if (!NT_SUCCESS(status)) return status;
    WDF_IO_TARGET_OPEN_PARAMS_INIT_OPEN_BY_NAME(&open, &path,
        index == 3 ? GENERIC_READ : GENERIC_WRITE);
    status = WdfIoTargetOpen(b->Pins[index], &open);
    if (!NT_SUCCESS(status)) { WdfObjectDelete(b->Pins[index]); b->Pins[index] = NULL; }
    return status;
}
NTSTATUS GeniBoardPrepare(GENI_BOARD *b, WDFDEVICE device, WDFCMRESLIST resources)
{
    ULONG i, pins = 0, memories = 0;
    LARGE_INTEGER ids[4], core = {0}, vote = {0};
    WDF_IO_TARGET_OPEN_PARAMS open;
    UNICODE_STRING path;
    PWSTR links = NULL;
    NTSTATUS status;
    b->Device = device;
    b->Native = TRUE;
    GeniRecord(device, L"TimelmBoardStage", 10);
    status = Contract(device);
    if (!NT_SUCCESS(status)) goto Fail;
    for (i = 0; i < WdfCmResourceListGetCount(resources); ++i) {
        PCM_PARTIAL_RESOURCE_DESCRIPTOR r = WdfCmResourceListGetDescriptor(resources, i);
        if (!r) { status = STATUS_DEVICE_CONFIGURATION_ERROR; goto Fail; }
        if (r->Type == CmResourceTypeMemory) {
            ++memories;
            if (r->u.Memory.Start.QuadPart == 0x118000 && r->u.Memory.Length == 0x1000)
                core = r->u.Memory.Start;
            else if (r->u.Memory.Start.QuadPart == 0x152000 && r->u.Memory.Length == 0x1000)
                vote = r->u.Memory.Start;
            else if (r->u.Memory.Start.QuadPart != 0xa94000 || r->u.Memory.Length != 0x4000) {
                status = STATUS_DEVICE_CONFIGURATION_ERROR; goto Fail;
            }
        } else if (r->Type == CmResourceTypeConnection) {
            if (r->u.Connection.Class != CM_RESOURCE_CONNECTION_CLASS_GPIO ||
                r->u.Connection.Type != CM_RESOURCE_CONNECTION_TYPE_GPIO_IO || pins >= 4) {
                status = STATUS_DEVICE_CONFIGURATION_ERROR; goto Fail;
            }
            ids[pins].LowPart = r->u.Connection.IdLowPart;
            ids[pins++].HighPart = r->u.Connection.IdHighPart;
        }
    }
    if (memories != 3 || !core.QuadPart || !vote.QuadPart || pins != 4) {
        status = STATUS_DEVICE_CONFIGURATION_ERROR; goto Fail;
    }
    b->GccCore = MmMapIoSpaceEx(core, 0x1000, PAGE_READWRITE | PAGE_NOCACHE);
    b->GccVote = MmMapIoSpaceEx(vote, 0x1000, PAGE_READWRITE | PAGE_NOCACHE);
    if (!b->GccCore || !b->GccVote) { status = STATUS_INSUFFICIENT_RESOURCES; goto Fail; }
    for (i = 0; i < 4; ++i) {
        status = OpenPin(b, ids[i], i);
        if (!NT_SUCCESS(status)) goto Fail;
    }
    GeniRecord(device, L"TimelmBoardStage", 11);
    status = IoGetDeviceInterfaces(&GUID_TIMELM_GPIO_PROVIDER, NULL, 0, &links);
    if (!NT_SUCCESS(status)) goto Fail;
    if (!links[0] || links[wcslen(links) + 1] != 0) {
        status = STATUS_DEVICE_CONFIGURATION_ERROR; goto Fail;
    }
    RtlInitUnicodeString(&path, links);
    status = WdfIoTargetCreate(device, WDF_NO_OBJECT_ATTRIBUTES, &b->Provider);
    if (!NT_SUCCESS(status)) goto Fail;
    WDF_IO_TARGET_OPEN_PARAMS_INIT_OPEN_BY_NAME(&open, &path, GENERIC_READ);
    status = WdfIoTargetOpen(b->Provider, &open);
    if (!NT_SUCCESS(status)) { WdfObjectDelete(b->Provider); b->Provider = NULL; goto Fail; }
    status = WdfIoTargetQueryForInterface(b->Provider, &GUID_TIMELM_TOUCH_BUS,
        (PINTERFACE)&b->Bus, sizeof(b->Bus), 2, NULL);
    if (!NT_SUCCESS(status)) goto Fail;
    if (b->Bus.Interface.Version != 2 || b->Bus.Interface.Size != sizeof(b->Bus) ||
        !b->Bus.SetBus || !b->Bus.Interface.InterfaceDereference) {
        status = STATUS_NOT_SUPPORTED; goto Fail;
    }
    ExFreePool(links);
    b->State.Context = b;
    b->State.Pin = Pin;
    b->State.Mux = Mux;
    b->State.EngineReady = EngineReady;
    b->State.DelayMs = DelayMs;
    b->State.Clock.Context = b;
    b->State.Clock.Read = ClockRead;
    b->State.Clock.Write = ClockWrite;
    b->State.Clock.DelayUs = DelayUs;
    return STATUS_SUCCESS;
Fail:
    if (links) ExFreePool(links);
    GeniRecord(device, L"TimelmBoardStatus", (ULONG)status);
    GeniBoardRelease(b);
    return status;
}
NTSTATUS GeniBoardStart(GENI_BOARD *b, PUCHAR engine, ULONG *select)
{
    NTSTATUS status = STATUS_SUCCESS;
    b->Engine = engine;
    GeniRecord(b->Device, L"TimelmClockVotesBefore", ClockRead(b, TC_VOTE));
    GeniRecord(b->Device, L"TimelmClockDfs", ClockRead(b, TC_DFS));
    GeniRecord(b->Device, L"TimelmClockCfg", ClockRead(b, TC_CFG));
    b->LastStatus = STATUS_SUCCESS;
    if (!TouchBoardStart(&b->State)) status = NT_SUCCESS(b->LastStatus) ?
        STATUS_DEVICE_NOT_READY : b->LastStatus;
    *select = b->State.Clock.Select;
    GeniRecord(b->Device, L"TimelmBoardStage", b->State.Stage);
    GeniRecord(b->Device, L"TimelmBoardStatus", (ULONG)status);
    GeniRecord(b->Device, L"TimelmClockResult", b->State.ClockResult);
    GeniRecord(b->Device, L"TimelmClockSelect", *select);
    return status;
}
NTSTATUS GeniBoardConfirmClock(GENI_BOARD *b)
{
    ULONG i, dfs;
    if (!(ClockRead(b, TC_DFS) & 1u)) return STATUS_SUCCESS;
    for (i = 0; i < 200; ++i) {
        dfs = ClockRead(b, TC_DFS);
        if (((dfs >> 1) & 15u) == b->State.Clock.Select) return STATUS_SUCCESS;
        KeStallExecutionProcessor(1);
    }
    GeniRecord(b->Device, L"TimelmClockDfsObserved", ClockRead(b, TC_DFS));
    return STATUS_DEVICE_NOT_READY;
}
NTSTATUS GeniBoardStop(GENI_BOARD *b)
{
    NTSTATUS status = TouchBoardStop(&b->State) ? STATUS_SUCCESS : STATUS_IO_DEVICE_ERROR;
    GeniRecord(b->Device, L"TimelmBoardStopStatus", (ULONG)status);
    return status;
}
VOID GeniBoardRelease(GENI_BOARD *b)
{
    ULONG i;
    if (b->State.Clock.Read) (void)GeniBoardStop(b);
    if (b->Bus.Interface.InterfaceDereference) {
        b->Bus.Interface.InterfaceDereference(b->Bus.Interface.Context);
        RtlZeroMemory(&b->Bus, sizeof(b->Bus));
    }
    if (b->Provider) { WdfIoTargetClose(b->Provider); WdfObjectDelete(b->Provider); b->Provider = NULL; }
    for (i = 0; i < 4; ++i) if (b->Pins[i]) {
        WdfIoTargetClose(b->Pins[i]); WdfObjectDelete(b->Pins[i]); b->Pins[i] = NULL;
    }
    if (b->GccCore) { MmUnmapIoSpace(b->GccCore, 0x1000); b->GccCore = NULL; }
    if (b->GccVote) { MmUnmapIoSpace(b->GccVote, 0x1000); b->GccVote = NULL; }
    RtlZeroMemory(&b->State, sizeof(b->State));
    b->Native = FALSE;
}
