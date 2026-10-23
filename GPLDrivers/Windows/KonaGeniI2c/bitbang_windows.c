/* SPDX-License-Identifier: GPL-2.0-only
 * V60 GPIO36=SDA / GPIO37=SCL, GPIO38 reset / 67 VCL / 68 VDD.
 * Owns only ResourceHub-reserved pins. No GENI/GCC/GPI/SMMU MMIO or DMA. */
#include <ntddk.h>
#include <wdf.h>
#include <initguid.h>
#include <gpio.h>
#define RESHUB_USE_HELPER_ROUTINES
#include <reshub.h>
#include "board_windows.h"
#include "bitbang_windows.h"
#include "trace_windows.h"
/* The provider's actual public interface GUID is shared with board_windows.c;
 * use a local constant rather than instantiate another DEFINE_GUID symbol. */
static const GUID ProviderGuid={0x3d4f477b,0x4937,0x407b,{0x93,0x29,0xf7,0xc8,0x8c,0x9a,0x01,0x88}};
/* Connection resource identities are recorded so a trial log shows exactly
 * which resources Windows published and in which order. */
static const PCWSTR PinIdLabels[BB_WINDOWS_MAX_PINS]={
    L"TimelmBitbangPinId0",L"TimelmBitbangPinId1",L"TimelmBitbangPinId2",
    L"TimelmBitbangPinId3",L"TimelmBitbangPinId4"};

static VOID DelayMs(ULONG ms)
{ LARGE_INTEGER t;t.QuadPart=-10000LL*ms;(void)KeDelayExecutionThread(KernelMode,FALSE,&t); }
static int Lines(void *context,int scl,int sda)
{
    BB_WINDOWS *b=context;
    NTSTATUS s=b->Bus.SetLines(b->Bus.Interface.Context,scl?TRUE:FALSE,sda?TRUE:FALSE);
    if (!NT_SUCCESS(s)) b->LastStatus=s;
    return NT_SUCCESS(s);
}
static int Sample(void *context,int *scl,int *sda)
{
    BB_WINDOWS *b=context;BOOLEAN c=FALSE,d=FALSE;
    NTSTATUS s=b->Bus.GetLines(b->Bus.Interface.Context,&c,&d);
    if (!NT_SUCCESS(s)) b->LastStatus=s;
    *scl=c?1:0;*sda=d?1:0;return NT_SUCCESS(s);
}
static GI_U64 Now(void *context)
{ UNREFERENCED_PARAMETER(context);return KeQueryInterruptTimePrecise(NULL)/10u; }
static void Pause(void *context,GI_U32 us)
{ UNREFERENCED_PARAMETER(context);KeStallExecutionProcessor(us); }
static int Cancelled(void *context)
{ BB_WINDOWS *b=context;return b->Request && WdfRequestIsCanceled(b->Request); }
static NTSTATUS Result(enum BB_RESULT r)
{
    switch(r) {
    case BbOk:return STATUS_SUCCESS;
    case BbInvalid:return STATUS_INVALID_PARAMETER;
    case BbNack:return STATUS_NO_SUCH_DEVICE;
    case BbTimeout:return STATUS_IO_TIMEOUT;
    case BbCancelled:return STATUS_CANCELLED;
    case BbBusy:case BbArbitration:return STATUS_DEVICE_BUSY;
    default:return STATUS_IO_DEVICE_ERROR;
    }
}
static NTSTATUS OpenPin(BB_WINDOWS *b,ULONG index)
{
    DECLARE_UNICODE_STRING_SIZE(path,RESOURCE_HUB_PATH_SIZE);
    WDF_IO_TARGET_OPEN_PARAMS open;NTSTATUS s;
    if(b->Pins[index]) return STATUS_SUCCESS;
    s=RESOURCE_HUB_CREATE_PATH_FROM_ID(&path,b->PinIds[index].LowPart,b->PinIds[index].HighPart);
    if (!NT_SUCCESS(s)) return s;
    s=WdfIoTargetCreate(b->Device,WDF_NO_OBJECT_ATTRIBUTES,&b->Pins[index]);
    if (!NT_SUCCESS(s)) return s;
    WDF_IO_TARGET_OPEN_PARAMS_INIT_OPEN_BY_NAME(&open,&path,
        index>=BB_WINDOWS_POWER_PINS?GENERIC_READ:GENERIC_WRITE);
    s=WdfIoTargetOpen(b->Pins[index],&open);
    if (!NT_SUCCESS(s)) {WdfObjectDelete(b->Pins[index]);b->Pins[index]=NULL;}
    return s;
}
static NTSTATUS Pin(BB_WINDOWS *b,ULONG index,UCHAR high)
{
    WDF_MEMORY_DESCRIPTOR mem;WDF_REQUEST_SEND_OPTIONS opt;ULONG_PTR n=0;NTSTATUS s;
    if (!b->Pins[index]) return STATUS_DEVICE_NOT_READY;
    WDF_MEMORY_DESCRIPTOR_INIT_BUFFER(&mem,&high,sizeof(high));
    WDF_REQUEST_SEND_OPTIONS_INIT(&opt,WDF_REQUEST_SEND_OPTION_TIMEOUT);
    WDF_REQUEST_SEND_OPTIONS_SET_TIMEOUT(&opt,WDF_REL_TIMEOUT_IN_MS(100));
    s=WdfIoTargetSendIoctlSynchronously(b->Pins[index],NULL,IOCTL_GPIO_WRITE_PINS,&mem,&mem,&opt,&n);
    if (NT_SUCCESS(s) && n!=sizeof(high)) s=STATUS_DEVICE_DATA_ERROR;
    return s;
}
NTSTATUS BbWindowsPrepare(BB_WINDOWS *b,WDFDEVICE device,WDFCMRESLIST resources)
{
    ULONG i,pins=0;PWSTR links=NULL;UNICODE_STRING path;
    WDF_IO_TARGET_OPEN_PARAMS open;NTSTATUS s;
    if(b->Retained || b->Acquired || b->Provider || b->Pins[0] || b->Pins[1] || b->Pins[2] ||
        b->Pins[3] || b->Pins[4])
        return STATUS_DEVICE_BUSY;
    b->Device=device;
    GeniRecord(device,L"TimelmBitbangStage",1);
    TimelmTrace("bb-contract-enter");
    s=GeniBoardCheckContractValue(device,0x54420501u);
    TimelmTraceStatus("bb-contract-exit", s);
    if (!NT_SUCCESS(s)) goto Fail;
    for(i=0;i<WdfCmResourceListGetCount(resources);++i) {
        PCM_PARTIAL_RESOURCE_DESCRIPTOR r=WdfCmResourceListGetDescriptor(resources,i);
        if (!r || r->Type==CmResourceTypeMemory || r->Type==CmResourceTypeMemoryLarge ||
            r->Type==CmResourceTypeInterrupt) {s=STATUS_DEVICE_CONFIGURATION_ERROR;goto Fail;}
        if (r->Type==CmResourceTypeConnection) {
            if (pins>=BB_WINDOWS_MAX_PINS || r->u.Connection.Class!=CM_RESOURCE_CONNECTION_CLASS_GPIO ||
                r->u.Connection.Type!=CM_RESOURCE_CONNECTION_TYPE_GPIO_IO) {s=STATUS_DEVICE_CONFIGURATION_ERROR;goto Fail;}
            b->PinIds[pins].LowPart=r->u.Connection.IdLowPart;
            b->PinIds[pins++].HighPart=r->u.Connection.IdHighPart;
        }
    }
    /* Four connections mean the bus pair arrived as one resource; five mean it
     * arrived per pin. Any other count is not this board's contract. */
    if (pins!=4 && pins!=5) {s=STATUS_DEVICE_CONFIGURATION_ERROR;goto Fail;}
    b->Connections=pins;
    GeniRecord(device,L"TimelmBitbangPinCount",pins);
    TimelmTraceValue("bb-pin-count",pins);
    for(i=0;i<pins;++i) {GeniRecord(device,PinIdLabels[i],(ULONG)b->PinIds[i].LowPart);
        TimelmTraceValue("bb-pin-id",(ULONG)b->PinIds[i].LowPart);}
    /* Reserve the bus pins for the full provider lifetime before muxing. */
    for(i=BB_WINDOWS_POWER_PINS;i<pins;++i) {s=OpenPin(b,i);TimelmTraceStatus("bb-openpin-in",s);if(!NT_SUCCESS(s)) goto Fail;}
    TimelmTrace("bb-provider-links-enter");
    s=IoGetDeviceInterfaces(&ProviderGuid,NULL,0,&links);
    TimelmTraceStatus("bb-provider-links",s);
    if (!NT_SUCCESS(s)) goto Fail;
    if (!links[0] || links[wcslen(links)+1]!=0) {s=STATUS_DEVICE_CONFIGURATION_ERROR;goto Fail;}
    RtlInitUnicodeString(&path,links);
    s=WdfIoTargetCreate(device,WDF_NO_OBJECT_ATTRIBUTES,&b->Provider);if(!NT_SUCCESS(s)) goto Fail;
    WDF_IO_TARGET_OPEN_PARAMS_INIT_OPEN_BY_NAME(&open,&path,GENERIC_READ);
    TimelmTrace("bb-provider-open-enter");
    s=WdfIoTargetOpen(b->Provider,&open);
    TimelmTraceStatus("bb-provider-open",s);
    if (!NT_SUCCESS(s)) {WdfObjectDelete(b->Provider);b->Provider=NULL;goto Fail;}
    TimelmTrace("bb-iface-query-enter");
    s=WdfIoTargetQueryForInterface(b->Provider,&GUID_TIMELM_TOUCH_BUS_V3,
        (PINTERFACE)&b->Bus,sizeof(b->Bus),3,NULL);
    TimelmTraceStatus("bb-iface-query",s);
    if (!NT_SUCCESS(s)) goto Fail;
    b->Acquired=TRUE;
    if(b->Bus.Interface.Version!=3 || b->Bus.Interface.Size!=sizeof(b->Bus) ||
       !b->Bus.SetGpioMode || !b->Bus.SetLines || !b->Bus.GetLines || !b->Bus.Interface.InterfaceDereference) {
        s=STATUS_NOT_SUPPORTED;goto Fail;
    }
    ExFreePool(links);
    b->Io.Context=b;b->Io.SetLines=Lines;b->Io.GetLines=Sample;b->Io.NowUs=Now;
    b->Io.DelayUs=Pause;b->Io.Cancelled=Cancelled;
    GeniRecord(device,L"TimelmBitbangStage",2);
    TimelmTrace("bb-prepare-done");
    return STATUS_SUCCESS;
Fail:
    if(links) ExFreePool(links);
    GeniRecord(device,L"TimelmBitbangStatus",(ULONG)s);
    TimelmTraceStatus("bb-prepare-fail",s);
    BbWindowsRelease(b);return s;
}
NTSTATUS BbWindowsStart(BB_WINDOWS *b)
{
    ULONG i;NTSTATUS s;UCHAR command[2]={0x26,0x44},id[8]={0};
    static const UCHAR expected[8]={'B','3','W','6','8','T','I','M'};
    BB_MESSAGE m[2];int scl=0,sda=0;
    if(!b->Acquired || b->Ready || b->Powered || b->Muxed || b->StartedOnce || b->Retained) return STATUS_DEVICE_NOT_READY;
    b->Powered=TRUE;
    TimelmTrace("bb-power-enter");
    for(i=0;i<3;++i) {s=OpenPin(b,i);TimelmTraceStatus("bb-openpin-out",s);if(!NT_SUCCESS(s)) goto Fail;
        s=Pin(b,i,0);TimelmTraceStatus("bb-write-out",s);if(!NT_SUCCESS(s))goto Fail;}
    b->Muxed=TRUE; /* include a partial failed GPIO-mode transition in rollback */
    TimelmTrace("bb-setgpiomode-enter");
    s=b->Bus.SetGpioMode(b->Bus.Interface.Context,TRUE);
    TimelmTraceStatus("bb-setgpiomode",s);
    if(!NT_SUCCESS(s))goto Fail;
    GeniRecord(b->Device,L"TimelmBitbangStage",3);
    DelayMs(1);s=Pin(b,1,1);TimelmTraceStatus("bb-write-vcl",s);if(!NT_SUCCESS(s))goto Fail;
    DelayMs(1);s=Pin(b,2,1);TimelmTraceStatus("bb-write-vdd",s);if(!NT_SUCCESS(s))goto Fail;
    DelayMs(10);s=Pin(b,0,1);TimelmTraceStatus("bb-write-reset",s);if(!NT_SUCCESS(s))goto Fail;
    DelayMs(90);
    TimelmTrace("bb-sample-enter");
    if(!Sample(b,&scl,&sda)) {s=b->LastStatus;TimelmTraceStatus("bb-sample",s);goto Fail;}
    TimelmTraceValue("bb-idle-lines",(scl?2u:0u)|(sda?1u:0u));
    GeniRecord(b->Device,L"TimelmBitbangIdleLines",(scl?2u:0u)|(sda?1u:0u));
    m[0].Bytes=command;m[0].Length=2;m[0].Read=0;
    m[1].Bytes=id;m[1].Length=8;m[1].Read=1;
    TimelmTrace("bb-identity-enter");
    s=Result(BbTransfer(&b->Io,m,2,Now(b)+100000u));
    TimelmTraceStatus("bb-identity",s);
    GeniRecord(b->Device,L"TimelmBitbangIdentityStatus",(ULONG)s);
    if(!NT_SUCCESS(s))goto Fail;
    GeniRecord(b->Device,L"TimelmBitbangIdentity0",(ULONG)id[0]|((ULONG)id[1]<<8)|((ULONG)id[2]<<16)|((ULONG)id[3]<<24));
    GeniRecord(b->Device,L"TimelmBitbangIdentity1",(ULONG)id[4]|((ULONG)id[5]<<8)|((ULONG)id[6]<<16)|((ULONG)id[7]<<24));
    if(RtlCompareMemory(id,expected,8)!=8) {s=STATUS_NO_SUCH_DEVICE;goto Fail;}
    b->Ready=TRUE;b->StartedOnce=TRUE;GeniRecord(b->Device,L"TimelmBitbangStage",4);
    GeniRecord(b->Device,L"TimelmBitbangStatus",(ULONG)STATUS_SUCCESS);return STATUS_SUCCESS;
Fail:
    GeniRecord(b->Device,L"TimelmBitbangStatus",(ULONG)s);(void)BbWindowsStop(b);return s;
}
NTSTATUS BbWindowsStop(BB_WINDOWS *b)
{
    ULONG i;NTSTATUS s=STATUS_SUCCESS,t;b->Ready=FALSE;
    TimelmTrace("bb-stop-enter");
    if(b->Powered) {
        static const ULONG order[3]={0,2,1};
        for(i=0;i<3;++i) if(b->Pins[order[i]]) {t=Pin(b,order[i],0);if(!NT_SUCCESS(t))s=t;DelayMs(1);}
        if(NT_SUCCESS(s)) b->Powered=FALSE;
    }
    if(b->Muxed) {t=b->Bus.SetGpioMode(b->Bus.Interface.Context,FALSE);if(!NT_SUCCESS(t))s=t;else b->Muxed=FALSE;}
    if(!NT_SUCCESS(s)) b->Retained=TRUE;
    GeniRecord(b->Device,L"TimelmBitbangRetained",b->Retained?1u:0u);
    GeniRecord(b->Device,L"TimelmBitbangStopStatus",(ULONG)s);
    TimelmTraceStatus("bb-stop-exit",s);
    return s;
}
BOOLEAN BbWindowsRelease(BB_WINDOWS *b)
{
    ULONG i;
    if(!NT_SUCCESS(BbWindowsStop(b)) || b->Retained) return FALSE;
    if(b->Acquired && b->Bus.Interface.InterfaceDereference) {
        b->Bus.Interface.InterfaceDereference(b->Bus.Interface.Context);b->Acquired=FALSE;
    }
    if(b->Provider) {WdfIoTargetClose(b->Provider);WdfObjectDelete(b->Provider);b->Provider=NULL;}
    for(i=0;i<BB_WINDOWS_MAX_PINS;++i) if(b->Pins[i]) {WdfIoTargetClose(b->Pins[i]);WdfObjectDelete(b->Pins[i]);b->Pins[i]=NULL;}
    return TRUE;
}
NTSTATUS BbWindowsTransfer(BB_WINDOWS *b,WDFREQUEST request,BB_MESSAGE *messages,ULONG count)
{
    NTSTATUS s;enum BB_RESULT r;
    if(!b->Ready) return STATUS_DEVICE_NOT_READY;
    b->Request=request;r=BbTransfer(&b->Io,messages,count,Now(b)+90000u);b->Request=NULL;
    s=Result(r);++b->Transfers;
    if(!NT_SUCCESS(s)) ++b->Failures;
    if(!NT_SUCCESS(s) || b->Transfers==1 || (b->Transfers&63u)==0) {
        GeniRecord(b->Device,L"TimelmBitbangTransfers",b->Transfers);
        GeniRecord(b->Device,L"TimelmBitbangFailures",b->Failures);
        GeniRecord(b->Device,L"TimelmBitbangLastStatus",(ULONG)s);
    }
    return s;
}
