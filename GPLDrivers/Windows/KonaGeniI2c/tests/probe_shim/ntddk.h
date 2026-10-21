/* SPDX-License-Identifier: GPL-2.0-only */
#ifndef TIMELM_PROBE_TEST_NTDDK_H
#define TIMELM_PROBE_TEST_NTDDK_H
#include <stdint.h>
#include <stddef.h>
#include <wchar.h>
typedef int32_t NTSTATUS;
typedef uint32_t ULONG, *PULONG;
typedef uint64_t ULONGLONG;
typedef unsigned char UCHAR, *PUCHAR;
typedef unsigned char BOOLEAN;
typedef void VOID;
typedef void *PVOID;
typedef const wchar_t *PCWSTR;
typedef union { struct { uint32_t LowPart; int32_t HighPart; }; int64_t QuadPart; } PHYSICAL_ADDRESS;
typedef struct CM_PARTIAL_RESOURCE_DESCRIPTOR {
    UCHAR Type, ShareDisposition;
    uint16_t Flags;
    union {
        struct { PHYSICAL_ADDRESS Start; ULONG Length; } Memory;
        struct { ULONG Level, Vector; uintptr_t Affinity; } Interrupt;
        struct { UCHAR Class, Type; uint16_t Reserved; ULONG IdLowPart, IdHighPart; } Connection;
    } u;
} CM_PARTIAL_RESOURCE_DESCRIPTOR, *PCM_PARTIAL_RESOURCE_DESCRIPTOR;
#define TRUE 1
#define FALSE 0
#define NT_SUCCESS(status) ((status)>=0)
#define STATUS_SUCCESS ((NTSTATUS)0)
#define STATUS_DEVICE_CONFIGURATION_ERROR ((NTSTATUS)0xc0000182u)
#define STATUS_INSUFFICIENT_RESOURCES ((NTSTATUS)0xc000009au)
#define STATUS_DEVICE_NOT_READY ((NTSTATUS)0xc00000a3u)
#define STATUS_NOT_SUPPORTED ((NTSTATUS)0xc00000bbu)
#define PAGE_READONLY 0x02u
#define PAGE_NOCACHE 0x200u
#define CmResourceTypeNull 0u
#define CmResourceTypePort 1u
#define CmResourceTypeInterrupt 2u
#define CmResourceTypeMemory 3u
#define CmResourceTypeMemoryLarge 7u
#define CmResourceTypeConnection 132u
#define CmResourceShareDeviceExclusive 1u
#define CM_RESOURCE_INTERRUPT_LEVEL_SENSITIVE 0x00u
#define CM_RESOURCE_INTERRUPT_LATCHED 0x01u
#define CM_RESOURCE_INTERRUPT_MESSAGE 0x02u
#define CM_RESOURCE_MEMORY_READ_WRITE 0x00u
#define CM_RESOURCE_CONNECTION_CLASS_GPIO 1u
#define CM_RESOURCE_CONNECTION_TYPE_GPIO_IO 2u
PVOID MmMapIoSpaceEx(PHYSICAL_ADDRESS address, size_t size, ULONG protection);
VOID MmUnmapIoSpace(PVOID address, size_t size);
ULONG ReadProbeRegister(PULONG address);
#define READ_REGISTER_ULONG(address) ReadProbeRegister(address)
#endif
