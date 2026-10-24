/* SPDX-License-Identifier: GPL-2.0-only
 * Exercise the production Windows adapter and its failure unwinding. The wire
 * core has a separate electrical slave-model test; here it is a controlled
 * identity/transport stub so every WDF and board sequencing failure is tested.
 */
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <ntddk.h>
#include <wdf.h>
#define TIMELM_BOARD_WINDOWS_H
VOID GeniRecord(WDFDEVICE device,PCWSTR name,ULONG value);
NTSTATUS GeniBoardCheckContractValue(WDFDEVICE device,ULONG value);
#include "../bitbang_windows.c"

static BB_WINDOWS bus;
static TEST_RESOURCE_LIST resources;
static struct TEST_TARGET targets[16];
static unsigned created,opened,closed,deleted,queried,dereferenced,lists;
static unsigned failCreate,failOpen,failPin,createCalls,openCalls,pinCalls;
static int failQuery,badVersion,nullDereference,failDiscovery,badIdentity;
static int failModeEnable,failModeDisable,failSample,modeActive;
static int failSetLines,cancelRequest,modeEnables,modeDisables;
static NTSTATUS contractStatus;
static GI_U64 clockUs,identityAt;
static enum BB_RESULT transferResult;
static unsigned events[128],eventCount,pinLevels[3];
static ULONG recordedPinCount;static unsigned recordedCounts;
static ULONG recordedPinId[5];static unsigned recordedIds;
static ULONG providerGate;
static ULONGLONG providerEpoch;
static int failReady;
static struct {PCWSTR name;ULONG value;} records[128];
static unsigned recordCount;
static ULONG Recorded(PCWSTR name)
{
    unsigned i;for(i=0;i<recordCount;++i)if(!wcscmp(records[i].name,name))return records[i].value;
    assert(!"missing production registry record");return 0;
}

ULONG WdfCmResourceListGetCount(WDFCMRESLIST list) { return list->Count; }
PCM_PARTIAL_RESOURCE_DESCRIPTOR WdfCmResourceListGetDescriptor(WDFCMRESLIST list,ULONG index)
{ assert(index<list->Count);return (int)index==list->NullIndex?NULL:&list->Entries[index]; }
VOID GeniRecord(WDFDEVICE device,PCWSTR name,ULONG value)
{
    (void)device;
    {
        unsigned i;for(i=0;i<recordCount;++i)if(!wcscmp(records[i].name,name))break;
        assert(i<128);records[i].name=name;records[i].value=value;if(i==recordCount)++recordCount;
    }
    if (!wcscmp(name,L"TimelmBitbangPinCount")) {recordedPinCount=value;++recordedCounts;return;}
    if (!wcsncmp(name,L"TimelmBitbangPinId",18) && name[18]>='0' && name[18]<='4') {
        recordedPinId[name[18]-'0']=value;++recordedIds;return;
    }
}
NTSTATUS GeniBoardCheckContractValue(WDFDEVICE device,ULONG value)
{ (void)device;assert(value==0x54420501u);return contractStatus; }
size_t RtlCompareMemory(const void *left,const void *right,size_t count)
{ return memcmp(left,right,count)?0:count; }
VOID RtlInitUnicodeString(UNICODE_STRING *text,PCWSTR buffer)
{ text->Buffer=(PWSTR)buffer;text->ResourceId=9; }
NTSTATUS KeDelayExecutionThread(int mode,BOOLEAN alertable,LARGE_INTEGER *interval)
{ (void)mode;(void)alertable;assert(interval->QuadPart<=0);clockUs+=(GI_U64)(-interval->QuadPart)/10;return STATUS_SUCCESS; }
ULONGLONG KeQueryInterruptTimePrecise(ULONGLONG *counter)
{ (void)counter;return clockUs*10; }
ULONGLONG KeQueryInterruptTime(void) { return clockUs*10; }
VOID KeStallExecutionProcessor(ULONG microseconds) { clockUs+=microseconds; }
NTSTATUS IoGetDeviceInterfaces(const GUID *guid,PVOID object,ULONG flags,PWSTR *links)
{
    static const wchar_t text[]=L"provider\0";
    (void)object;(void)flags;
    assert(guid->Data1==0x3d4f477bu && guid->Data4[2]==0xf7);
    if(failDiscovery)return STATUS_NO_SUCH_DEVICE;
    *links=malloc(sizeof(text));assert(*links);memcpy(*links,text,sizeof(text));++lists;
    return STATUS_SUCCESS;
}
VOID ExFreePool(PVOID pointer) { assert(lists);--lists;free(pointer); }
NTSTATUS WdfIoTargetCreate(WDFDEVICE device,PVOID attributes,WDFIOTARGET *target)
{
    (void)device;(void)attributes;
    if(++createCalls==failCreate)return STATUS_INSUFFICIENT_RESOURCES;
    assert(created<16);*target=&targets[created++];return STATUS_SUCCESS;
}
NTSTATUS WdfIoTargetOpen(WDFIOTARGET target,WDF_IO_TARGET_OPEN_PARAMS *parameters)
{
    unsigned i,id=parameters->Path->ResourceId;
    if(++openCalls==failOpen)return STATUS_IO_DEVICE_ERROR;
    for(i=0;i<created;++i) assert(!targets[i].Open || targets[i].Id!=id);
    assert(id==9 || (id>=1 && id<=5));
    assert(parameters->Access==((id>=4 || id==9)?GENERIC_READ:GENERIC_WRITE));
    target->Id=id;target->Open=1;++opened;return STATUS_SUCCESS;
}
VOID WdfIoTargetClose(WDFIOTARGET target)
{ assert(target->Open && !target->Deleted);target->Open=0;++closed; }
VOID WdfObjectDelete(WDFIOTARGET target)
{ assert(!target->Open && !target->Deleted);target->Deleted=1;++deleted; }
/* The runner writes a per-boot attempt id to the device instance key and the
 * adapter reads it back in prepare. The mock keeps the plumbing testable. */
static ULONG attemptValue;
static int failAttempt;
NTSTATUS WdfDeviceOpenRegistryKey(WDFDEVICE device,int type,ULONG access,PVOID attributes,WDFKEY *key)
{
    (void)device;(void)type;(void)access;(void)attributes;
    if (failAttempt) return STATUS_ACCESS_DENIED;
    *key=(WDFKEY)(ULONG_PTR)0x1;
    return STATUS_SUCCESS;
}
NTSTATUS WdfRegistryQueryULong(WDFKEY key,PCUNICODE_STRING name,ULONG *value)
{ (void)key;(void)name;*value=attemptValue;return STATUS_SUCCESS; }
VOID WdfRegistryClose(WDFKEY key) { (void)key; }
static VOID Dereference(PVOID context)
{ (void)context;assert(!modeActive);++dereferenced; }
static NTSTATUS Mode(PVOID context,BOOLEAN enable)
{
    (void)context;assert(bus.Pins[3] && bus.Pins[3]->Open);
    events[eventCount++]=enable?1001:1000;
    if(enable) {++modeEnables;modeActive=1;return failModeEnable?STATUS_IO_DEVICE_ERROR:STATUS_SUCCESS;}
    ++modeDisables;if(failModeDisable)return STATUS_IO_DEVICE_ERROR;
    modeActive=0;return STATUS_SUCCESS;
}
static NTSTATUS Set(PVOID context,BOOLEAN scl,BOOLEAN sda)
{ (void)context;(void)scl;(void)sda;assert(modeActive);return failSetLines?STATUS_IO_DEVICE_ERROR:STATUS_SUCCESS; }
static NTSTATUS Get(PVOID context,PBOOLEAN scl,PBOOLEAN sda)
{ (void)context;assert(modeActive);*scl=*sda=TRUE;return failSample?STATUS_IO_DEVICE_ERROR:STATUS_SUCCESS; }
static NTSTATUS QueryState(PVOID context,ULONG *gate,ULONGLONG *epoch)
{ (void)context;*gate=providerGate;*epoch=providerEpoch;return failReady?STATUS_DEVICE_NOT_READY:STATUS_SUCCESS; }
NTSTATUS WdfIoTargetQueryForInterface(WDFIOTARGET target,const GUID *guid,PINTERFACE result,USHORT size,USHORT version,PVOID data)
{
    TIMELM_TOUCH_BUS_V4 *interface=(TIMELM_TOUCH_BUS_V4 *)result;
    (void)data;assert(target->Id==9 && target->Open);
    assert(guid->Data1==0x0cf0124eu && size==sizeof(*interface) && version==4);
    ++queried;if(failQuery)return STATUS_NOT_SUPPORTED;
    memset(interface,0,sizeof(*interface));interface->Interface.Size=size;
    interface->Interface.Version=badVersion?3:4;
    interface->Interface.InterfaceDereference=nullDereference?NULL:Dereference;
    interface->SetGpioMode=Mode;interface->SetLines=Set;interface->GetLines=Get;
    interface->QueryState=QueryState;
    return STATUS_SUCCESS;
}
NTSTATUS WdfIoTargetSendIoctlSynchronously(WDFIOTARGET target,WDFREQUEST request,ULONG ioctl,WDF_MEMORY_DESCRIPTOR *input,WDF_MEMORY_DESCRIPTOR *output,WDF_REQUEST_SEND_OPTIONS *options,ULONG_PTR *returned)
{
    UCHAR value=*(UCHAR *)input->Buffer;
    (void)request;(void)output;(void)options;
    assert(target->Open && target->Id>=1 && target->Id<=3);
    assert(ioctl==IOCTL_GPIO_WRITE_PINS && input->Size==1 && value<=1);
    ++pinCalls;if(pinCalls==failPin)return STATUS_IO_DEVICE_ERROR;
    events[eventCount++]=10+2*target->Id+value;pinLevels[target->Id-1]=value;
    *returned=1;return STATUS_SUCCESS;
}
BOOLEAN WdfRequestIsCanceled(WDFREQUEST request)
{ assert(request);return cancelRequest?TRUE:FALSE; }
enum BB_RESULT BbTransfer(BB_IO *io,BB_MESSAGE *messages,GI_U32 count,GI_U64 deadline)
{
    assert(io==&bus.Io && modeActive && deadline>clockUs);
    if(!bus.Ready) {
        assert(count==2 && messages[0].Length==2 && !messages[0].Read);
        assert(messages[0].Bytes[0]==0x26 && messages[0].Bytes[1]==0x44);
        assert(messages[1].Length==8 && messages[1].Read);
        memcpy(messages[1].Bytes,badIdentity?"WRONG-ID":"B3W68TIM",8);
        assert(pinLevels[0] && pinLevels[1] && pinLevels[2]);
        assert(clockUs>=102000);identityAt=clockUs;events[eventCount++]=2000;
    }
    return transferResult;
}
static void Init(void)
{
    unsigned i;
    memset(&bus,0,sizeof(bus));memset(&resources,0,sizeof(resources));
    memset(targets,0,sizeof(targets));memset(pinLevels,0,sizeof(pinLevels));
    resources.Count=4;resources.NullIndex=-1;
    for(i=0;i<4;++i) {
        resources.Entries[i].Type=CmResourceTypeConnection;
        resources.Entries[i].u.Connection.Class=CM_RESOURCE_CONNECTION_CLASS_GPIO;
        resources.Entries[i].u.Connection.Type=CM_RESOURCE_CONNECTION_TYPE_GPIO_IO;
        resources.Entries[i].u.Connection.IdLowPart=i+1;
    }
    created=opened=closed=deleted=queried=dereferenced=lists=0;
    failCreate=failOpen=failPin=createCalls=openCalls=pinCalls=0;
    failQuery=badVersion=nullDereference=failDiscovery=badIdentity=0;
    failModeEnable=failModeDisable=failSample=modeActive=0;
    failSetLines=cancelRequest=modeEnables=modeDisables=0;
    eventCount=0;clockUs=identityAt=0;contractStatus=STATUS_SUCCESS;transferResult=BbOk;
    attemptValue=7;failAttempt=0;providerGate=1;providerEpoch=0x123400000007ULL;failReady=0;
    recordCount=0;memset(records,0,sizeof(records));
    recordedPinCount=0;recordedCounts=0;recordedIds=0;memset(recordedPinId,0,sizeof(recordedPinId));
}
/* Windows may publish the {36,37} bus pair as one connection resource or as
 * one resource per pin. The second shape adds a fifth GPIO connection. */
static void AddSplitBusPin(void)
{
    assert(resources.Count==4);
    resources.Count=5;
    resources.Entries[4].Type=CmResourceTypeConnection;
    resources.Entries[4].u.Connection.Class=CM_RESOURCE_CONNECTION_CLASS_GPIO;
    resources.Entries[4].u.Connection.Type=CM_RESOURCE_CONNECTION_TYPE_GPIO_IO;
    resources.Entries[4].u.Connection.IdLowPart=5;
}
static void Clean(void)
{
    BbWindowsRelease(&bus);
    assert(!bus.Provider && !bus.Pins[0] && !bus.Pins[1] && !bus.Pins[2] && !bus.Pins[3] &&
        !bus.Pins[4]);
    assert(created==deleted && opened==closed && !lists && !modeActive);
}
static void Prepare(void) { assert(BbWindowsPrepare(&bus,NULL,&resources)==STATUS_SUCCESS); }
/* The bus pair published as one resource per pin must work exactly like the
 * single-resource shape: both pins reserved, power order unchanged. */
static void SplitBusPins(void)
{
    BB_MESSAGE message;UCHAR data=0;
    Init();AddSplitBusPin();attemptValue=7;Prepare();
    assert(bus.Attempt==7);
    assert(bus.Connections==5 && created==3);
    assert(bus.Pins[3] && bus.Pins[3]->Open && bus.Pins[4] && bus.Pins[4]->Open);
    assert(!bus.Pins[0] && !bus.Pins[1] && !bus.Pins[2]);
    assert(recordedCounts>=1 && recordedPinCount==5 && recordedIds>=5);
    assert(recordedPinId[0]==1 && recordedPinId[1]==2 && recordedPinId[2]==3 &&
        recordedPinId[3]==4 && recordedPinId[4]==5);
    assert(BbWindowsStart(&bus)==STATUS_SUCCESS && bus.Ready && identityAt>=102000);
    message.Bytes=&data;message.Length=1;message.Read=1;
    assert(BbWindowsTransfer(&bus,(WDFREQUEST)1,&message,1)==STATUS_SUCCESS);
    assert(!bus.Request && bus.Transfers==1 && !bus.Failures);
    assert(BbWindowsStop(&bus)==STATUS_SUCCESS && !bus.Ready);
    Clean();
}
static void Good(void)
{
    static const unsigned expected[]={12,14,16,1001,15,17,13,2000,12,16,14,1000};
    BB_MESSAGE message;UCHAR data=0;unsigned allocations;
    Init();Prepare();assert(bus.Acquired && !bus.Ready && created==2);
    assert(bus.Attempt==7 && bus.FailOp==BbFailNone);
    allocations=created;
    assert(!NT_SUCCESS(BbWindowsPrepare(&bus,NULL,&resources)) && created==allocations);
    assert(BbWindowsStart(&bus)==STATUS_SUCCESS && bus.Ready && identityAt>=102000);
    message.Bytes=&data;message.Length=1;message.Read=1;
    assert(BbWindowsTransfer(&bus,(WDFREQUEST)1,&message,1)==STATUS_SUCCESS);
    assert(!bus.Request && bus.Transfers==1 && !bus.Failures);
    assert(BbWindowsStop(&bus)==STATUS_SUCCESS && !bus.Ready);
    assert(eventCount==sizeof(expected)/sizeof(expected[0]));
    assert(!memcmp(events,expected,sizeof(expected)));
    allocations=created;
    assert(BbWindowsStart(&bus)==STATUS_DEVICE_NOT_READY && created==allocations);
    Clean();assert(dereferenced==1);
}
static void PrepareFailures(void)
{
    unsigned i;
    Init();contractStatus=STATUS_NOT_SUPPORTED;
    assert(BbWindowsPrepare(&bus,NULL,&resources)==STATUS_NOT_SUPPORTED);Clean();
    for(i=1;i<=2;++i) {
        Init();failCreate=i;assert(!NT_SUCCESS(BbWindowsPrepare(&bus,NULL,&resources)));Clean();
        Init();failOpen=i;assert(!NT_SUCCESS(BbWindowsPrepare(&bus,NULL,&resources)));Clean();
    }
    Init();failDiscovery=1;assert(!NT_SUCCESS(BbWindowsPrepare(&bus,NULL,&resources)));Clean();
    Init();failQuery=1;assert(!NT_SUCCESS(BbWindowsPrepare(&bus,NULL,&resources)));Clean();
    Init();badVersion=1;assert(!NT_SUCCESS(BbWindowsPrepare(&bus,NULL,&resources)));Clean();
    Init();nullDereference=1;assert(!NT_SUCCESS(BbWindowsPrepare(&bus,NULL,&resources)));Clean();
    Init();resources.NullIndex=2;assert(!NT_SUCCESS(BbWindowsPrepare(&bus,NULL,&resources)));Clean();
    Init();resources.Entries[0].Type=CmResourceTypeMemory;
    assert(!NT_SUCCESS(BbWindowsPrepare(&bus,NULL,&resources)));Clean();
    /* Only the four-resource and five-resource shapes are this board. */
    Init();resources.Count=3;assert(!NT_SUCCESS(BbWindowsPrepare(&bus,NULL,&resources)));Clean();
    Init();AddSplitBusPin();resources.Count=6;resources.Entries[5]=resources.Entries[4];
    assert(!NT_SUCCESS(BbWindowsPrepare(&bus,NULL,&resources)));Clean();
    Init();resources.Entries[3].u.Connection.Class=2;
    assert(!NT_SUCCESS(BbWindowsPrepare(&bus,NULL,&resources)));Clean();
    Init();resources.Entries[3].u.Connection.Type=1;
    assert(!NT_SUCCESS(BbWindowsPrepare(&bus,NULL,&resources)));Clean();
}
static void StartFailures(void)
{
    unsigned i;
    for(i=3;i<=5;++i) {
        Init();Prepare();failCreate=i;assert(!NT_SUCCESS(BbWindowsStart(&bus)));Clean();
        Init();Prepare();failOpen=i;assert(!NT_SUCCESS(BbWindowsStart(&bus)));Clean();
    }
    for(i=1;i<=6;++i) {
        Init();Prepare();failPin=i;assert(!NT_SUCCESS(BbWindowsStart(&bus)));
        /* Pins 0..2 write LOW first, then the power-up writes in VCL, VDD,
         * reset order: the FailOp names the exact milestone per call. */
        if (i<=3) assert(bus.FailOp==BbFailWriteLow);
        else if (i==4) assert(bus.FailOp==BbFailVcl);
        else if (i==5) assert(bus.FailOp==BbFailVdd);
        else assert(bus.FailOp==BbFailReset);
        assert(Recorded(L"TimelmBitbangFirstFailureValid")==1);
        assert(Recorded(L"TimelmBitbangFirstFailureStatus")==((ULONG)STATUS_IO_DEVICE_ERROR));
        assert(Recorded(L"TimelmBitbangFirstFailurePin")==((i<=3)?i-1:(i==4?1:i==5?2:0)));
        assert(Recorded(L"TimelmBitbangFirstFailureValue")==((i<=3)?0u:1u));
        assert(Recorded(L"TimelmBitbangFirstFailureOp")==bus.FailOp);
        assert(bus.WriteStatus[bus.FailurePin]==(ULONG)STATUS_IO_DEVICE_ERROR);
        assert(Recorded(L"TimelmBitbangSnapshotValid")==1);
        Clean();
        assert(Recorded(L"TimelmBitbangFirstFailureStatus")==((ULONG)STATUS_IO_DEVICE_ERROR));
    }
    Init();Prepare();failModeEnable=1;
    assert(!NT_SUCCESS(BbWindowsStart(&bus)) && modeEnables==1 && modeDisables==1 && !modeActive);
    assert(bus.FailOp==BbFailMux);Clean();
    Init();Prepare();failSample=1;assert(!NT_SUCCESS(BbWindowsStart(&bus)));Clean();
    Init();Prepare();badIdentity=1;assert(BbWindowsStart(&bus)==STATUS_NO_SUCH_DEVICE);Clean();
    Init();Prepare();transferResult=BbNack;assert(BbWindowsStart(&bus)==STATUS_NO_SUCH_DEVICE);Clean();
}
static void ReadyAndEpoch(void)
{
    Init();attemptValue=0;assert(BbWindowsPrepare(&bus,NULL,&resources)==STATUS_INVALID_PARAMETER);assert(!pinCalls);Clean();
    Init();failAttempt=1;assert(!NT_SUCCESS(BbWindowsPrepare(&bus,NULL,&resources)));assert(!pinCalls);Clean();
    Init();providerGate=0;assert(!NT_SUCCESS(BbWindowsPrepare(&bus,NULL,&resources)));assert(!pinCalls);Clean();
    Init();providerGate=2;assert(!NT_SUCCESS(BbWindowsPrepare(&bus,NULL,&resources)));assert(!pinCalls);Clean();
    Init();providerEpoch=0;assert(!NT_SUCCESS(BbWindowsPrepare(&bus,NULL,&resources)));assert(!pinCalls);Clean();
    Init();Prepare();++providerEpoch;assert(!NT_SUCCESS(BbWindowsStart(&bus)));assert(!pinCalls && bus.FailOp==BbFailReady);Clean();
    Init();Prepare();providerGate=0;assert(!NT_SUCCESS(BbWindowsStart(&bus)));assert(!pinCalls && bus.FailOp==BbFailReady);Clean();
    Init();Prepare();failReady=1;assert(!NT_SUCCESS(BbWindowsStart(&bus)));assert(!pinCalls);Clean();
    Init();resources.Entries[0].u.Connection.IdHighPart=0x12345678;Prepare();
    assert(bus.PinIds[0].HighPart==0x12345678);Clean();
}
static void Retained(void)
{
    unsigned allocations,closings;
    Init();Prepare();assert(BbWindowsStart(&bus)==STATUS_SUCCESS);
    allocations=created;closings=closed;failModeDisable=1;
    BbWindowsRelease(&bus);
    assert(modeActive && bus.Provider && bus.Pins[3] && closed==closings && dereferenced==0);
    assert(BbWindowsStart(&bus)==STATUS_DEVICE_NOT_READY && created==allocations);
    assert(!NT_SUCCESS(BbWindowsPrepare(&bus,NULL,&resources)) && created==allocations);
    /* A later successful hardware stop does not clear the permanent
     * until-reboot latch or relinquish the reservation. */
    failModeDisable=0;assert(!BbWindowsRelease(&bus));
    assert(!modeActive && bus.Retained && bus.Pins[3] && !dereferenced);
    /* Init below models reboot; static mock targets own no heap allocations. */
    Init();Prepare();failModeEnable=failModeDisable=1;
    assert(!NT_SUCCESS(BbWindowsStart(&bus)) && modeActive);
    BbWindowsRelease(&bus);assert(bus.Pins[3] && !closed && !dereferenced);
    failModeDisable=0;assert(!BbWindowsRelease(&bus));
    assert(!modeActive && bus.Retained && bus.Pins[3] && !dereferenced);
    /* A power-pin failure also latches ownership, even if mux restore works. */
    Init();Prepare();assert(BbWindowsStart(&bus)==STATUS_SUCCESS);
    failPin=pinCalls+1;
    assert(!NT_SUCCESS(BbWindowsStop(&bus)) && bus.Retained);
    assert(!BbWindowsRelease(&bus) && bus.Pins[3] && !dereferenced);
    Init();Prepare();assert(BbWindowsStart(&bus)==STATUS_SUCCESS);
    transferResult=BbTimeout;
    {
        UCHAR byte=0;BB_MESSAGE message={&byte,1,1};
        assert(BbWindowsTransfer(&bus,(WDFREQUEST)1,&message,1)==STATUS_IO_TIMEOUT);
        assert(!bus.Request && bus.Transfers==1 && bus.Failures==1);
        cancelRequest=1;bus.Request=(WDFREQUEST)1;
        assert(bus.Io.Cancelled(bus.Io.Context));bus.Request=NULL;
        failSetLines=1;assert(!bus.Io.SetLines(bus.Io.Context,1,1));
        assert(bus.LastStatus==STATUS_IO_DEVICE_ERROR);
    }
    Clean();
}
int main(void)
{
    Good();SplitBusPins();PrepareFailures();StartFailures();Retained();ReadyAndEpoch();
    puts("Production bitbang Windows adapter: exact identity/power order, prepare/start failures, partial enable cleanup, no resume and retained reservations passed");
    return 0;
}
