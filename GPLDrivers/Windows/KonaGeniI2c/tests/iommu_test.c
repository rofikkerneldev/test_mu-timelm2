/* SPDX-License-Identifier: GPL-2.0-only
 * Executes iommu_windows.c with injected failures, including unsafe teardown.
 * This checks ownership and memory lifetime, not actual SMMU hardware. */
#include <ntddk.h>
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include "../iommu_windows.h"
enum OP { Interface = 1, Query, Device, Domain, Attach, Allocate, Map, Flush,
          Detach, Unmap, DeleteDomain, DeleteDevice, Free };
static struct {
    enum OP Fail, Trace[64];
    unsigned Used, Frees, Detaches;
    int Attached, Mapped, Domain, Device, BadMapping, MissingCallback, BadSize, BadVersion, BadLogical;
    void *Allocation;
} m;
static const NTSTATUS Failure = -100;
static NTSTATUS Step(enum OP op)
{
    assert(m.Used < 64);
    m.Trace[m.Used++] = op;
    return m.Fail == op ? Failure : STATUS_SUCCESS;
}
static NTSTATUS QueryMappings(PDEVICE_OBJECT pdo, INPUT_MAPPING_ELEMENT *b, ULONG size, ULONG *n)
{
    NTSTATUS s = Step(Query);
    assert(pdo && size == sizeof(*b));
    if (!NT_SUCCESS(s)) return s;
    b->InputMappingId = m.BadMapping == 1 ? 86 : 0;
    *n = m.BadMapping == 2 ? 0 : (ULONG)sizeof(*b);
    return s;
}
static NTSTATUS CreateDevice(PDEVICE_OBJECT pdo, IOMMU_DEVICE_CREATION_CONFIGURATION *c, PIOMMU_DMA_DEVICE *out)
{
    NTSTATUS s = Step(Device);
    assert(pdo && !m.Device && c->ConfigType == IommuDeviceCreationConfigTypeAcpi);
    assert(c->NextConfiguration.Flink == &c->NextConfiguration && c->NextConfiguration.Blink == &c->NextConfiguration);
    assert(c->Acpi.InputMappingBase == 0 && c->Acpi.MappingsCount == 1);
    if (!NT_SUCCESS(s)) return s;
    m.Device = 1; *out = &m.Device;
    return s;
}
static NTSTATUS CreateDomain(IOMMU_DMA_DOMAIN_TYPE type, IOMMU_DMA_DOMAIN_CREATION_FLAGS f,
    void *allocator, void *reserved, PIOMMU_DMA_DOMAIN *out)
{
    NTSTATUS s = Step(Domain);
    assert(type == DomainTypeTranslate && f.AsUlonglong == 0 && !allocator && !reserved && !m.Domain);
    if (!NT_SUCCESS(s)) return s;
    m.Domain = 1; *out = &m.Domain;
    return s;
}
static NTSTATUS AttachDevice(PIOMMU_DMA_DOMAIN domain, PIOMMU_DMA_DEVICE device)
{
    NTSTATUS s = Step(Attach);
    assert(domain == &m.Domain && device == &m.Device && !m.Attached);
    if (NT_SUCCESS(s)) m.Attached = 1;
    return s;
}
static NTSTATUS MapRange(PIOMMU_DMA_DOMAIN domain, ULONG permissions, IOMMU_MAP_PHYSICAL_ADDRESS *physical,
    IOMMU_DMA_LOGICAL_ADDRESS *explicitAddress, IOMMU_DMA_LOGICAL_ADDRESS *min,
    IOMMU_DMA_LOGICAL_ADDRESS *max, IOMMU_DMA_LOGICAL_ADDRESS *out)
{
    NTSTATUS s = Step(Map);
    assert(domain == &m.Domain && m.Attached && !m.Mapped && permissions == 3);
    assert(physical->MapType == MapPhysicalAddressTypeContiguousRange);
    assert(physical->ContiguousRange.Base.QuadPart == 0x180000000LL);
    assert(physical->ContiguousRange.Size == 8192 && explicitAddress && *explicitAddress == 0x10000000);
    assert(!min && !max);
    if (NT_SUCCESS(s)) { m.Mapped = 1; *out = *explicitAddress + (m.BadLogical ? 4096 : 0); }
    return s;
}
static NTSTATUS FlushDomain(PIOMMU_DMA_DOMAIN domain)
{
    assert(domain == &m.Domain && m.Domain);
    return Step(Flush);
}
static NTSTATUS DetachDevice(PIOMMU_DMA_DEVICE device)
{
    NTSTATUS s = Step(Detach);
    assert(device == &m.Device && m.Attached);
    ++m.Detaches;
    if (NT_SUCCESS(s)) m.Attached = 0;
    return s;
}
static NTSTATUS UnmapRange(PIOMMU_DMA_DOMAIN domain, ULONGLONG logical, ULONGLONG pages)
{
    NTSTATUS s = Step(Unmap);
    assert(domain == &m.Domain && !m.Attached && m.Mapped);
    assert(logical == 0x10000000u + (m.BadLogical ? 4096u : 0u) && pages == 2);
    if (NT_SUCCESS(s)) m.Mapped = 0;
    return s;
}
static NTSTATUS DeleteTheDomain(PIOMMU_DMA_DOMAIN domain)
{
    NTSTATUS s = Step(DeleteDomain);
    assert(domain == &m.Domain && !m.Attached && !m.Mapped && m.Domain);
    if (NT_SUCCESS(s)) m.Domain = 0;
    return s;
}
static NTSTATUS DeleteTheDevice(PIOMMU_DMA_DEVICE device)
{
    NTSTATUS s = Step(DeleteDevice);
    assert(device == &m.Device && !m.Attached && !m.Domain && m.Device);
    if (NT_SUCCESS(s)) m.Device = 0;
    return s;
}
NTSTATUS IoGetIommuInterfaceEx(ULONG version, ULONGLONG flags, DMA_IOMMU_INTERFACE_EX *out)
{
    NTSTATUS s = Step(Interface);
    assert(version == 2 && flags == 0);
    if (!NT_SUCCESS(s)) return s;
    out->Size = m.BadSize ? 0 : sizeof(*out); out->Version = m.BadVersion ? 1 : 2;
    out->V2.CreateDomainEx = CreateDomain;
    out->V2.DeleteDomain = DeleteTheDomain;
    out->V2.AttachDeviceEx = AttachDevice;
    out->V2.DetachDeviceEx = DetachDevice;
    out->V2.FlushDomain = FlushDomain;
    out->V2.QueryInputMappings = QueryMappings;
    out->V2.MapLogicalRangeEx = m.MissingCallback ? NULL : MapRange;
    out->V2.UnmapLogicalRange = UnmapRange;
    out->V2.CreateDevice = CreateDevice;
    out->V2.DeleteDevice = DeleteTheDevice;
    return s;
}
PVOID MmAllocateContiguousMemorySpecifyCache(size_t n, PHYSICAL_ADDRESS low, PHYSICAL_ADDRESS high,
    PHYSICAL_ADDRESS boundary, int cache)
{
    assert(n == 8192 && !low.QuadPart && high.QuadPart == INT64_MAX && !boundary.QuadPart && cache == MmNonCached);
    assert(!m.Allocation);
    if (!NT_SUCCESS(Step(Allocate))) return NULL;
    m.Allocation = aligned_alloc(4096, n);
    assert(m.Allocation);
    return m.Allocation;
}
PHYSICAL_ADDRESS MmGetPhysicalAddress(PVOID buffer)
{
    PHYSICAL_ADDRESS p = {0x180000000LL};
    assert(buffer == m.Allocation);
    return p;
}
void MmFreeContiguousMemorySpecifyCache(PVOID buffer, size_t size, int cache)
{
    (void)Step(Free);
    assert(buffer == m.Allocation && !m.Attached && !m.Mapped && !m.Domain && !m.Device);
    assert(size == 8192 && cache == MmNonCached);
    free(m.Allocation); m.Allocation = NULL; ++m.Frees;
}
static void Reset(void)
{
    /* Simulated power cycle: retained allocations are freed by the test only. */
    free(m.Allocation);
    memset(&m, 0, sizeof(m));
}
int main(void)
{
    TIMELM_IOMMU d;
    unsigned before, i;
    const enum OP failures[] = {Interface, Query, Device, Domain, Attach, Allocate, Map, Flush};
    const enum OP cleanupFailures[] = {Detach, Unmap, Flush, DeleteDomain, DeleteDevice};
    Reset(); memset(&d, 0, sizeof(d));
    assert(NT_SUCCESS(TimelmIommuAcquire(&d, &d)));
    assert(d.Ready && d.Attached && d.Mapped && d.Logical == 0x10000000);
    assert(d.Logical != (ULONGLONG)MmGetPhysicalAddress(d.Buffer).QuadPart);
    before = m.Used;
    assert(NT_SUCCESS(TimelmIommuAcquire(&d, &d)) && m.Used == before);
    assert(NT_SUCCESS(TimelmIommuRelease(&d, TRUE)) && !d.Buffer && m.Frees == 1);
    assert(m.Trace[before] == Detach && m.Trace[before+1] == Unmap && m.Trace[before+2] == Flush);
    assert(NT_SUCCESS(TimelmIommuRelease(&d, TRUE)) && m.Frees == 1);
    for (i = 0; i < sizeof(failures)/sizeof(failures[0]); ++i) {
        Reset(); memset(&d, 0, sizeof(d)); m.Fail = failures[i];
        assert(!NT_SUCCESS(TimelmIommuAcquire(&d, &d)) && !d.Ready);
        if (m.Fail == Attach) assert(m.Detaches == 0); /* do not detach another owner */
        if (m.Fail != Flush) assert(!d.Buffer && !m.Device && !m.Domain && !m.Mapped && !m.Attached);
        else assert(d.Retained && d.Buffer && m.Frees == 0);
    }
    for (i = 0; i < sizeof(cleanupFailures)/sizeof(cleanupFailures[0]); ++i) {
        Reset(); memset(&d, 0, sizeof(d));
        assert(NT_SUCCESS(TimelmIommuAcquire(&d, &d)));
        m.Fail = cleanupFailures[i];
        assert(!NT_SUCCESS(TimelmIommuRelease(&d, TRUE)));
        assert(d.Retained && d.Buffer && m.Frees == 0);
        before = m.Used;
        assert(!NT_SUCCESS(TimelmIommuAcquire(&d, &d)) && m.Used == before);
        assert(!NT_SUCCESS(TimelmIommuRelease(&d, TRUE)) && m.Used == before);
    }
    Reset(); memset(&d, 0, sizeof(d));
    assert(NT_SUCCESS(TimelmIommuAcquire(&d, &d)));
    before = m.Used;
    assert(!NT_SUCCESS(TimelmIommuRelease(&d, FALSE)) && m.Used == before);
    assert(d.Retained && d.Attached && d.Mapped && d.Buffer && !m.Frees);
    for (i = 0; i < 6; ++i) {
        Reset(); memset(&d, 0, sizeof(d));
        m.BadMapping = i < 2 ? (int)i + 1 : 0;
        m.MissingCallback = i == 2; m.BadSize = i == 3;
        m.BadVersion = i == 4; m.BadLogical = i == 5;
        assert(!NT_SUCCESS(TimelmIommuAcquire(&d, &d)));
        assert(!d.Ready && !m.Attached && !m.Mapped && !m.Device && !m.Domain && !d.Buffer);
    }
    Reset();
    puts("IOMMU ownership, IOVA mapping and failure teardown tests passed");
    return 0;
}
