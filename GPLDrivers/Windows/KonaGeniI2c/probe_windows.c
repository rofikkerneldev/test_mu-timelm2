/* SPDX-License-Identifier: GPL-2.0-only
 * Explicit one-shot prerequisite snapshot. No MMIO writes, GPIO opens, clock
 * votes, DMA allocation, IOMMU calls, interrupt registration or SPB transfer. */
#include <ntddk.h>
#include <wdf.h>
#include "board_windows.h"
#include "probe_policy.h"

static BOOLEAN ProbeMemoryResources(WDFCMRESLIST resources)
{
    static const ULONGLONG bases[4]={0xa94000,0x118000,0x152000,0xa00000};
    static const ULONG sizes[4]={0x4000,0x1000,0x1000,0x70000};
    ULONG counts[4]={0},i,k;
    for (i=0;i<WdfCmResourceListGetCount(resources);++i) {
        PCM_PARTIAL_RESOURCE_DESCRIPTOR r=WdfCmResourceListGetDescriptor(resources,i);
        if (!r || r->Type==CmResourceTypeMemoryLarge) return FALSE;
        if (r->Type!=CmResourceTypeMemory) continue;
        for (k=0;k<4;++k)
            if ((ULONGLONG)r->u.Memory.Start.QuadPart==bases[k] && r->u.Memory.Length==sizes[k]) break;
        if (k==4 || ++counts[k]!=1) return FALSE;
    }
    for (k=0;k<4;++k) if (counts[k]!=1) return FALSE;
    return TRUE;
}

NTSTATUS GeniReadOnlyProbe(WDFDEVICE device, WDFCMRESLIST raw,
                          WDFCMRESLIST translated)
{
    ULONG i, interrupts=0, voteValue;
    ULONG master, slave, branch, command;
    PUCHAR core=NULL, votes=NULL, engine=NULL;
    PHYSICAL_ADDRESS physical;
    NTSTATUS status=STATUS_DEVICE_CONFIGURATION_ERROR;
    GeniRecord(device,L"TimelmProbeComplete",0);
    GeniRecord(device,L"TimelmProbeStage",1);
    GeniRecord(device,L"TimelmProbeEngineRead",0);
    status=GeniBoardCheckContract(device,TRUE,TRUE);
    if (!NT_SUCCESS(status)) goto Done;
    status=STATUS_DEVICE_CONFIGURATION_ERROR;
    if (!ProbeMemoryResources(raw) || !ProbeMemoryResources(translated)) goto Done;
    /* Validate both assigned resources and the raw board IRQ. No arbitrary
     * caller-selected physical address or offset is accepted. */
    for (i=0; i<WdfCmResourceListGetCount(raw); ++i) {
        PCM_PARTIAL_RESOURCE_DESCRIPTOR r=WdfCmResourceListGetDescriptor(raw,i);
        if (!r) goto Done;
        if (r->Type==CmResourceTypeInterrupt) {
            if (r->u.Interrupt.Vector!=311 || (r->Flags&CM_RESOURCE_INTERRUPT_MESSAGE))
                goto Done;
            ++interrupts;
        }
    }
    if (interrupts!=1) goto Done;
    GeniRecord(device,L"TimelmProbeStage",2);
    physical.QuadPart=0x118000;
    core=MmMapIoSpaceEx(physical,0x1000,PAGE_READONLY|PAGE_NOCACHE);
    physical.QuadPart=0x152000;
    votes=MmMapIoSpaceEx(physical,0x1000,PAGE_READONLY|PAGE_NOCACHE);
    if (!core || !votes) {status=STATUS_INSUFFICIENT_RESOURCES;goto Done;}
    master=READ_REGISTER_ULONG((PULONG)(core+4));
    slave=READ_REGISTER_ULONG((PULONG)(core+8));
    branch=READ_REGISTER_ULONG((PULONG)(core+0x5fc));
    command=READ_REGISTER_ULONG((PULONG)(core+0x600));
    voteValue=READ_REGISTER_ULONG((PULONG)(votes+8));
    GeniRecord(device,L"TimelmProbeVotes",voteValue);
    GeniRecord(device,L"TimelmProbeMasterAhb",master);
    GeniRecord(device,L"TimelmProbeSlaveAhb",slave);
    GeniRecord(device,L"TimelmProbeBranch",branch);
    GeniRecord(device,L"TimelmProbeCommand",command);
    GeniRecord(device,L"TimelmProbeConfig",READ_REGISTER_ULONG((PULONG)(core+0x604)));
    GeniRecord(device,L"TimelmProbeDfs",READ_REGISTER_ULONG((PULONG)(core+0x614)));
    GeniRecord(device,L"TimelmProbeStage",3);
    if (TimelmProbeEngineReadable(master,slave,branch,command,voteValue)) {
        physical.QuadPart=0xa94000;
        engine=MmMapIoSpaceEx(physical,0x1000,PAGE_READONLY|PAGE_NOCACHE);
        if (!engine) {status=STATUS_INSUFFICIENT_RESOURCES;goto Done;}
        GeniRecord(device,L"TimelmProbeFirmware",READ_REGISTER_ULONG((PULONG)(engine+GI_FW_REV)));
        GeniRecord(device,L"TimelmProbeFifoDisabled",READ_REGISTER_ULONG((PULONG)(engine+GI_IF_DISABLE)));
        GeniRecord(device,L"TimelmProbeEngineState",READ_REGISTER_ULONG((PULONG)(engine+GI_STATUS)));
        GeniRecord(device,L"TimelmProbeEngineRead",1);
        GeniRecord(device,L"TimelmProbeStage",4);
    }
    GeniRecord(device,L"TimelmProbeComplete",1);
    /* A completed probe intentionally does not start the SPB controller. */
    status=STATUS_DEVICE_NOT_READY;
Done:
    if (engine) MmUnmapIoSpace(engine,0x1000);
    if (votes) MmUnmapIoSpace(votes,0x1000);
    if (core) MmUnmapIoSpace(core,0x1000);
    GeniRecord(device,L"TimelmProbeStatus",(ULONG)status);
    GeniRecord(device,L"TimelmHostStatus",(ULONG)status);
    return status;
}
