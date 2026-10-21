/* SPDX-License-Identifier: GPL-2.0-only
 * Windows-owned translated domain. Never writes SMMU registers, attaches to
 * a borrowed domain, or uses Linux/firmware page tables. Serialized by the
 * SPBCx device's passive-level PnP/power callbacks. */
#include <ntddk.h>
#include "iommu_windows.h"

NTSTATUS TimelmIommuRelease(TIMELM_IOMMU *d, BOOLEAN quiesced)
{
    NTSTATUS status;
    DMA_IOMMU_INTERFACE_V2 *api = &d->Interface.V2;
    d->Ready = FALSE;
    if (d->Retained || !quiesced) {
        d->Retained = TRUE;
        return STATUS_DEVICE_BUSY;
    }
    /* Detach only OUR attachment. An AttachDeviceEx failure must never cause
     * us to detach an existing firmware/OS owner. On any cleanup failure do
     * not free backing memory that could still be reachable by the device. */
    if (d->Attached) {
        d->Stage = 81;
        status = api->DetachDeviceEx(d->Device);
        if (!NT_SUCCESS(status)) goto Retain;
        d->Attached = FALSE;
    }
    if (d->Mapped) {
        d->Stage = 82;
        status = api->UnmapLogicalRange(d->Domain, d->Logical, TIMELM_DMA_BYTES / PAGE_SIZE);
        if (!NT_SUCCESS(status)) goto Retain;
        d->Mapped = FALSE;
    }
    if (d->Domain) {
        d->Stage = 83;
        status = api->FlushDomain(d->Domain);
        if (!NT_SUCCESS(status)) goto Retain;
        d->Stage = 84;
        status = api->DeleteDomain(d->Domain);
        if (!NT_SUCCESS(status)) goto Retain;
        d->Domain = NULL;
    }
    if (d->Device) {
        d->Stage = 85;
        status = api->DeleteDevice(d->Device);
        if (!NT_SUCCESS(status)) goto Retain;
        d->Device = NULL;
    }
    if (d->Buffer) {
        MmFreeContiguousMemorySpecifyCache(d->Buffer, TIMELM_DMA_BYTES, MmNonCached);
        d->Buffer = NULL;
    }
    d->Logical = 0;
    d->Stage = 90;
    return STATUS_SUCCESS;
Retain:
    d->Retained = TRUE;
    d->LastStatus = status;
    return status;
}

NTSTATUS TimelmIommuAcquire(TIMELM_IOMMU *d, PDEVICE_OBJECT pdo)
{
    DMA_IOMMU_INTERFACE_V2 *api;
    IOMMU_DEVICE_CREATION_CONFIGURATION config;
    IOMMU_DMA_DOMAIN_CREATION_FLAGS flags;
    IOMMU_MAP_PHYSICAL_ADDRESS physical;
    IOMMU_DMA_LOGICAL_ADDRESS requested = TIMELM_DMA_IOVA;
    INPUT_MAPPING_ELEMENT mapping;
    PHYSICAL_ADDRESS low = {0}, high, boundary = {0};
    ULONG returned = 0, failedStage;
    NTSTATUS status;
    C_ASSERT(PAGE_SIZE == 4096);
    if (d->Retained) return STATUS_DEVICE_BUSY;
    if (d->Ready) return STATUS_SUCCESS;
    if (d->Device || d->Domain || d->Buffer) return STATUS_INVALID_DEVICE_STATE;
    d->Stage = 10;
    RtlZeroMemory(&d->Interface, sizeof(d->Interface));
    status = IoGetIommuInterfaceEx(DMA_IOMMU_INTERFACE_EX_VERSION_2, 0, &d->Interface);
    if (!NT_SUCCESS(status)) goto Fail;
    api = &d->Interface.V2;
    if (d->Interface.Version != DMA_IOMMU_INTERFACE_EX_VERSION_2 ||
        d->Interface.Size < DMA_IOMMU_INTERFACE_EX_V2_SIZE ||
        !api->QueryInputMappings || !api->CreateDevice || !api->DeleteDevice ||
        !api->CreateDomainEx || !api->DeleteDomain || !api->AttachDeviceEx ||
        !api->DetachDeviceEx || !api->MapLogicalRangeEx ||
        !api->UnmapLogicalRange || !api->FlushDomain) {
        status = STATUS_NOT_SUPPORTED; goto Fail;
    }
    d->Stage = 20;
    RtlZeroMemory(&mapping, sizeof(mapping));
    status = api->QueryInputMappings(pdo, &mapping, sizeof(mapping), &returned);
    if (!NT_SUCCESS(status)) goto Fail;
    /* Reject missing, alioth-wide or ambiguous mappings, not just the first
     * matching ID. Output SID is supplied by the paired V60 IORT, not this API. */
    if (returned != sizeof(mapping) || mapping.InputMappingId != TIMELM_DMA_INPUT_ID) {
        status = STATUS_DEVICE_CONFIGURATION_ERROR; goto Fail;
    }
    RtlZeroMemory(&config, sizeof(config));
    InitializeListHead(&config.NextConfiguration);
    config.ConfigType = IommuDeviceCreationConfigTypeAcpi;
    config.Acpi.InputMappingBase = TIMELM_DMA_INPUT_ID;
    config.Acpi.MappingsCount = 1;
    d->Stage = 30;
    status = api->CreateDevice(pdo, &config, &d->Device);
    if (!NT_SUCCESS(status)) goto Fail;
    RtlZeroMemory(&flags, sizeof(flags));
    d->Stage = 40;
    status = api->CreateDomainEx(DomainTypeTranslate, flags, NULL, NULL, &d->Domain);
    if (!NT_SUCCESS(status)) goto Fail;
    d->Stage = 50;
    status = api->AttachDeviceEx(d->Domain, d->Device);
    if (!NT_SUCCESS(status)) goto Fail;
    d->Attached = TRUE;
    /* Noncached CPU mapping for a noncoherent device (_CCA=0). This allocation
     * is not WDF-parented, so failed quiescence cannot auto-free active rings. */
    high.QuadPart = MAXLONGLONG;
    d->Stage = 60;
    d->Buffer = MmAllocateContiguousMemorySpecifyCache(TIMELM_DMA_BYTES,
        low, high, boundary, MmNonCached);
    if (!d->Buffer) { status = STATUS_INSUFFICIENT_RESOURCES; goto Fail; }
    RtlZeroMemory(d->Buffer, TIMELM_DMA_BYTES);
    RtlZeroMemory(&physical, sizeof(physical));
    physical.MapType = MapPhysicalAddressContiguousRange;
    physical.ContiguousRange.Base = MmGetPhysicalAddress(d->Buffer);
    physical.ContiguousRange.Size = TIMELM_DMA_BYTES;
    if (physical.ContiguousRange.Base.QuadPart & (PAGE_SIZE - 1)) {
        status = STATUS_DEVICE_CONFIGURATION_ERROR; goto Fail;
    }
    d->Stage = 70;
    /* The address is reserved only inside our newly created empty domain.
     * It is not assumed to equal physical RAM. No passthrough fallback. */
    status = api->MapLogicalRangeEx(d->Domain, 3, &physical, &requested,
        NULL, NULL, &d->Logical);
    if (!NT_SUCCESS(status)) goto Fail;
    d->Mapped = TRUE;
    if (d->Logical != requested) { status = STATUS_DEVICE_CONFIGURATION_ERROR; goto Fail; }
    d->Stage = 71;
    status = api->FlushDomain(d->Domain);
    if (!NT_SUCCESS(status)) goto Fail;
    KeMemoryBarrier();
    d->Ready = TRUE;
    d->LastStatus = STATUS_SUCCESS;
    d->Stage = 75;
    return STATUS_SUCCESS;
Fail:
    failedStage = d->Stage;
    /* GPI has not been programmed by this function. */
    (void)TimelmIommuRelease(d, TRUE);
    d->Stage = failedStage;
    d->LastStatus = status;
    return status;
}
