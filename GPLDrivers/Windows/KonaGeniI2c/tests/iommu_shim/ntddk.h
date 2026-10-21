/* SPDX-License-Identifier: GPL-2.0-only
 * Host-only ABI-shaped test doubles. The real ARM64 build uses WDK ntddk.h. */
#ifndef TIMELM_TEST_NTDDK_H
#define TIMELM_TEST_NTDDK_H
#include <stdint.h>
#include <stddef.h>
#include <string.h>
#include <limits.h>
typedef int32_t NTSTATUS;
typedef uint32_t ULONG;
typedef uint64_t ULONGLONG;
typedef int BOOLEAN;
typedef void *PVOID, *PDEVICE_OBJECT;
typedef struct { int64_t QuadPart; } PHYSICAL_ADDRESS;
typedef struct LIST_ENTRY { struct LIST_ENTRY *Flink, *Blink; } LIST_ENTRY;
#define InitializeListHead(p) ((p)->Flink = (p)->Blink = (p))
#define TRUE 1
#define FALSE 0
#define PAGE_SIZE 4096
#define MAXLONGLONG INT64_MAX
#define C_ASSERT(e) _Static_assert(e, #e)
#define NT_SUCCESS(s) ((s) >= 0)
#define RtlZeroMemory(p,n) memset(p,0,n)
#define KeMemoryBarrier() ((void)0)
#define MmNonCached 0
#define STATUS_SUCCESS 0
#define STATUS_DEVICE_BUSY (-1)
#define STATUS_NOT_SUPPORTED (-2)
#define STATUS_DEVICE_CONFIGURATION_ERROR (-3)
#define STATUS_INSUFFICIENT_RESOURCES (-4)
#define STATUS_INVALID_DEVICE_STATE (-5)
typedef void *PIOMMU_DMA_DEVICE, *PIOMMU_DMA_DOMAIN;
typedef uint64_t IOMMU_DMA_LOGICAL_ADDRESS;
typedef union { ULONGLONG AsUlonglong; } IOMMU_DMA_DOMAIN_CREATION_FLAGS;
typedef enum { DomainTypeTranslate, DomainTypePassThrough } IOMMU_DMA_DOMAIN_TYPE;
enum { IommuDeviceCreationConfigTypeAcpi = 1, MapPhysicalAddressContiguousRange = 1 };
typedef struct {
    LIST_ENTRY NextConfiguration;
    int ConfigType;
    struct { ULONG InputMappingBase, MappingsCount; } Acpi;
} IOMMU_DEVICE_CREATION_CONFIGURATION;
typedef struct {
    int MapType;
    struct { PHYSICAL_ADDRESS Base; size_t Size; } ContiguousRange;
} IOMMU_MAP_PHYSICAL_ADDRESS;
typedef struct { ULONG InputMappingId; } INPUT_MAPPING_ELEMENT;
typedef struct {
    NTSTATUS (*CreateDomainEx)(IOMMU_DMA_DOMAIN_TYPE,IOMMU_DMA_DOMAIN_CREATION_FLAGS,void*,void*,PIOMMU_DMA_DOMAIN*);
    NTSTATUS (*DeleteDomain)(PIOMMU_DMA_DOMAIN);
    NTSTATUS (*AttachDeviceEx)(PIOMMU_DMA_DOMAIN,PIOMMU_DMA_DEVICE);
    NTSTATUS (*DetachDeviceEx)(PIOMMU_DMA_DEVICE);
    NTSTATUS (*FlushDomain)(PIOMMU_DMA_DOMAIN);
    NTSTATUS (*QueryInputMappings)(PDEVICE_OBJECT,INPUT_MAPPING_ELEMENT*,ULONG,ULONG*);
    NTSTATUS (*MapLogicalRangeEx)(PIOMMU_DMA_DOMAIN,ULONG,IOMMU_MAP_PHYSICAL_ADDRESS*,
        IOMMU_DMA_LOGICAL_ADDRESS*,IOMMU_DMA_LOGICAL_ADDRESS*,IOMMU_DMA_LOGICAL_ADDRESS*,IOMMU_DMA_LOGICAL_ADDRESS*);
    NTSTATUS (*UnmapLogicalRange)(PIOMMU_DMA_DOMAIN,ULONGLONG,ULONGLONG);
    NTSTATUS (*CreateDevice)(PDEVICE_OBJECT,IOMMU_DEVICE_CREATION_CONFIGURATION*,PIOMMU_DMA_DEVICE*);
    NTSTATUS (*DeleteDevice)(PIOMMU_DMA_DEVICE);
} DMA_IOMMU_INTERFACE_V2;
typedef struct {
    size_t Size;
    ULONG Version;
    DMA_IOMMU_INTERFACE_V2 V2;
} DMA_IOMMU_INTERFACE_EX;
#define DMA_IOMMU_INTERFACE_EX_VERSION_2 2
#define DMA_IOMMU_INTERFACE_EX_V2_SIZE sizeof(DMA_IOMMU_INTERFACE_EX)
NTSTATUS IoGetIommuInterfaceEx(ULONG,ULONGLONG,DMA_IOMMU_INTERFACE_EX*);
PVOID MmAllocateContiguousMemorySpecifyCache(size_t,PHYSICAL_ADDRESS,PHYSICAL_ADDRESS,PHYSICAL_ADDRESS,int);
void MmFreeContiguousMemorySpecifyCache(PVOID,size_t,int);
PHYSICAL_ADDRESS MmGetPhysicalAddress(PVOID);
#endif
