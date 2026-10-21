/* SPDX-License-Identifier: GPL-2.0-only
 * Compile the actual Windows probe with a DDI shim. Any unmapped register,
 * unexpected physical map, writable map or missing release fails the test.
 * This verifies resource rejection and cleanup, not hardware availability.
 */
#include <assert.h>
#include <stdio.h>
#include <string.h>
#include <ntddk.h>
#include <wdf.h>
#define TIMELM_BOARD_WINDOWS_H
VOID GeniRecord(WDFDEVICE device, PCWSTR name, ULONG value);
NTSTATUS GeniBoardCheckContract(WDFDEVICE device, BOOLEAN gpi, BOOLEAN iommu);
#include "../probe_windows.c"

static TEST_RESOURCE_LIST rawResources, translatedResources;
static ULONG pages[3][0x1000/sizeof(ULONG)];
static unsigned mapped[3], mapCalls, unmapCalls, reads[3], failMap;
static NTSTATUS contractStatus;
static unsigned contractCalls;
static ULONG complete, engineRead, finalStatus, stage;
static const ULONG requiredVotes=(1u<<20)|(1u<<21)|(1u<<27);

ULONG WdfCmResourceListGetCount(WDFCMRESLIST resources)
{ return resources->Count; }
PCM_PARTIAL_RESOURCE_DESCRIPTOR WdfCmResourceListGetDescriptor(WDFCMRESLIST resources, ULONG index)
{
    assert(index<resources->Count);
    return (int)index==resources->NullIndex ? NULL : &resources->Entries[index];
}
NTSTATUS GeniBoardCheckContract(WDFDEVICE device, BOOLEAN gpi, BOOLEAN iommu)
{
    (void)device;
    assert(gpi==TRUE && iommu==TRUE);
    assert(mapCalls==0);
    ++contractCalls;
    return contractStatus;
}
VOID GeniRecord(WDFDEVICE device, PCWSTR name, ULONG value)
{
    (void)device;
    if (!wcscmp(name,L"TimelmProbeComplete")) complete=value;
    if (!wcscmp(name,L"TimelmProbeEngineRead")) engineRead=value;
    if (!wcscmp(name,L"TimelmProbeStatus")) finalStatus=value;
    if (!wcscmp(name,L"TimelmProbeStage")) stage=value;
}
PVOID MmMapIoSpaceEx(PHYSICAL_ADDRESS address, size_t size, ULONG protection)
{
    unsigned index;
    assert(contractCalls==1);
    assert(protection==(PAGE_READONLY|PAGE_NOCACHE));
    assert(size==0x1000);
    if (address.QuadPart==0x118000) index=0;
    else if (address.QuadPart==0x152000) index=1;
    else { assert(address.QuadPart==0xa94000); index=2; }
    ++mapCalls;
    if (mapCalls==failMap) return NULL;
    assert(!mapped[index]);
    mapped[index]=1;
    return pages[index];
}
VOID MmUnmapIoSpace(PVOID address, size_t size)
{
    unsigned index;
    assert(size==0x1000);
    for (index=0;index<3;++index) if (address==pages[index]) break;
    assert(index<3 && mapped[index]);
    mapped[index]=0;
    ++unmapCalls;
}
ULONG ReadProbeRegister(PULONG address)
{
    unsigned index;
    uintptr_t pointer=(uintptr_t)address;
    for (index=0;index<3;++index) {
        uintptr_t base=(uintptr_t)pages[index];
        if (pointer>=base && pointer<base+sizeof(pages[index])) break;
    }
    assert(index<3 && mapped[index]);
    ++reads[index];
    return *address;
}
static void Init(void)
{
    static const uint64_t bases[4]={0xa94000,0x118000,0x152000,0xa00000};
    static const ULONG sizes[4]={0x4000,0x1000,0x1000,0x70000};
    unsigned i;
    memset(&rawResources,0,sizeof(rawResources));
    rawResources.Count=9;
    rawResources.NullIndex=-1;
    for (i=0;i<4;++i) {
        rawResources.Entries[i].Type=CmResourceTypeMemory;
        rawResources.Entries[i].u.Memory.Start.QuadPart=(int64_t)bases[i];
        rawResources.Entries[i].u.Memory.Length=sizes[i];
    }
    rawResources.Entries[4].Type=CmResourceTypeInterrupt;
    rawResources.Entries[4].ShareDisposition=CmResourceShareDeviceExclusive;
    rawResources.Entries[4].u.Interrupt.Vector=311;
    rawResources.Entries[4].u.Interrupt.Level=311;
    for (i=5;i<9;++i) {
        rawResources.Entries[i].Type=CmResourceTypeConnection;
        rawResources.Entries[i].u.Connection.Class=CM_RESOURCE_CONNECTION_CLASS_GPIO;
        rawResources.Entries[i].u.Connection.Type=CM_RESOURCE_CONNECTION_TYPE_GPIO_IO;
        rawResources.Entries[i].u.Connection.IdLowPart=i;
    }
    translatedResources=rawResources;
    translatedResources.Entries[4].u.Interrupt.Vector=0x91;
    memset(pages,0,sizeof(pages));
    memset(mapped,0,sizeof(mapped));
    memset(reads,0,sizeof(reads));
    pages[1][8/sizeof(ULONG)]=requiredVotes;
    pages[2][GI_FW_REV/sizeof(ULONG)]=0x300;
    mapCalls=unmapCalls=failMap=contractCalls=0;
    contractStatus=STATUS_SUCCESS;
    complete=engineRead=finalStatus=stage=0;
}
static NTSTATUS Run(void)
{
    NTSTATUS status=GeniReadOnlyProbe(NULL,&rawResources,&translatedResources);
    assert(finalStatus==(ULONG)status);
    assert(!mapped[0] && !mapped[1] && !mapped[2]);
    return status;
}
static void RejectResources(void)
{
    assert(Run()==STATUS_DEVICE_CONFIGURATION_ERROR);
    assert(mapCalls==0 && reads[0]==0 && reads[1]==0 && reads[2]==0);
    assert(complete==0 && engineRead==0);
}
int main(void)
{
    unsigned i;
    Init();
    assert(Run()==STATUS_DEVICE_NOT_READY);
    assert(complete==1 && engineRead==1 && stage==4);
    assert(mapCalls==3 && unmapCalls==3 && reads[2]==3);
    Init();contractStatus=STATUS_NOT_SUPPORTED;
    assert(Run()==STATUS_NOT_SUPPORTED);
    assert(contractCalls==1 && mapCalls==0 && complete==0);
    for (i=1;i<=3;++i) {
        Init();failMap=i;
        assert(Run()==STATUS_INSUFFICIENT_RESOURCES);
        assert(unmapCalls==mapCalls-1 && complete==0 && engineRead==0);
    }
    for (i=0;i<3;++i) {
        const unsigned offsets[3]={4,8,0x5fc};
        Init();pages[0][offsets[i]/4]=0x80000000u;
        assert(Run()==STATUS_DEVICE_NOT_READY);
        assert(complete==1 && engineRead==0 && reads[2]==0 && mapCalls==2);
    }
    for (i=0;i<32;++i) {
        ULONG bit=1u<<i;
        if (bit&0x800000f1u) {
            Init();pages[0][0x600/4]=bit;
            assert(Run()==STATUS_DEVICE_NOT_READY && engineRead==0 && reads[2]==0);
        }
        if (bit&requiredVotes) {
            Init();pages[1][8/4]&=~bit;
            assert(Run()==STATUS_DEVICE_NOT_READY && engineRead==0 && reads[2]==0);
        }
    }
    for (i=0;i<4;++i) {
        Init();translatedResources.Entries[i].u.Memory.Start.QuadPart+=0x1000;RejectResources();
        Init();translatedResources.Entries[i].u.Memory.Length+=4;RejectResources();
        Init();translatedResources.Entries[i]=translatedResources.Entries[(i+1)%4];RejectResources();
        Init();rawResources.Entries[i].u.Memory.Start.QuadPart+=0x1000;RejectResources();
    }
    Init();translatedResources.Entries[0].Type=CmResourceTypeMemoryLarge;RejectResources();
    Init();translatedResources.NullIndex=1;RejectResources();
    Init();rawResources.NullIndex=1;RejectResources();
    Init();rawResources.Entries[4].u.Interrupt.Vector=310;RejectResources();
    Init();rawResources.Entries[4].Flags=CM_RESOURCE_INTERRUPT_MESSAGE;RejectResources();
    Init();rawResources.Entries[9]=rawResources.Entries[4];++rawResources.Count;RejectResources();
    Init();rawResources.Entries[4].Type=CmResourceTypeNull;RejectResources();
    puts("Production probe: resources/contract/map failures refuse or unwind; stopped clocks prevent GENI reads; all mappings read-only and released");
    return 0;
}
