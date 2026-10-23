/* SPDX-License-Identifier: GPL-2.0-only */
#ifndef TIMELM_BB_TEST_NTDDK_H
#define TIMELM_BB_TEST_NTDDK_H
#include "../probe_shim/ntddk.h"
#include <string.h>
typedef BOOLEAN *PBOOLEAN;
typedef UCHAR *PUCHAR;
typedef ULONG *PULONG;
typedef uint16_t USHORT;
typedef wchar_t *PWSTR;
typedef PHYSICAL_ADDRESS LARGE_INTEGER;
typedef uintptr_t ULONG_PTR;
typedef struct { unsigned int Data1; unsigned short Data2,Data3; unsigned char Data4[8]; } GUID;
typedef struct { PWSTR Buffer; ULONG ResourceId; } UNICODE_STRING;
typedef struct { USHORT Size,Version; PVOID Context; VOID (*InterfaceReference)(PVOID); VOID (*InterfaceDereference)(PVOID); } INTERFACE,*PINTERFACE;
#define UNREFERENCED_PARAMETER(p) ((void)(p))
#define DEFINE_GUID(name,a,b,c,d,e,f,g,h,i,j,k) static const GUID name __attribute__((unused))={a,b,c,{d,e,f,g,h,i,j,k}}
#define KernelMode 0
#define GENERIC_READ 1u
#define GENERIC_WRITE 2u
#define STATUS_INVALID_PARAMETER ((NTSTATUS)0xc000000du)
#define STATUS_NO_SUCH_DEVICE ((NTSTATUS)0xc000000eu)
#define STATUS_IO_TIMEOUT ((NTSTATUS)0xc00000b5u)
#define STATUS_CANCELLED ((NTSTATUS)0xc0000120u)
#define STATUS_DEVICE_BUSY ((NTSTATUS)0x80000011u)
#define STATUS_ACCESS_DENIED ((NTSTATUS)0xc0000022u)
#define STATUS_IO_DEVICE_ERROR ((NTSTATUS)0xc0000185u)
#define STATUS_DEVICE_DATA_ERROR ((NTSTATUS)0xc000009cu)
#define STATUS_INVALID_DEVICE_STATE ((NTSTATUS)0xc0000184u)
#define RtlZeroMemory(p,n) memset(p,0,n)
#define RtlCopyMemory(p,s,n) memcpy(p,s,n)
size_t RtlCompareMemory(const void *left,const void *right,size_t count);
VOID RtlInitUnicodeString(UNICODE_STRING *value,PCWSTR text);
NTSTATUS KeDelayExecutionThread(int mode,BOOLEAN alertable,LARGE_INTEGER *interval);
ULONGLONG KeQueryInterruptTimePrecise(ULONGLONG *counter);
ULONGLONG KeQueryInterruptTime(void);
VOID KeStallExecutionProcessor(ULONG microseconds);
NTSTATUS IoGetDeviceInterfaces(const GUID *guid,PVOID object,ULONG flags,PWSTR *links);
VOID ExFreePool(PVOID buffer);
#endif
