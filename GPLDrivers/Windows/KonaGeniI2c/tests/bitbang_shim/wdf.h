/* SPDX-License-Identifier: GPL-2.0-only */
#ifndef TIMELM_BB_TEST_WDF_H
#define TIMELM_BB_TEST_WDF_H
#include <ntddk.h>
typedef void *WDFDEVICE,*WDFREQUEST;
typedef struct TEST_TARGET { unsigned Id,Open,Deleted; } *WDFIOTARGET;
typedef struct TEST_RESOURCE_LIST { CM_PARTIAL_RESOURCE_DESCRIPTOR Entries[12]; ULONG Count; int NullIndex; } TEST_RESOURCE_LIST,*WDFCMRESLIST;
typedef struct { UNICODE_STRING *Path; ULONG Access; } WDF_IO_TARGET_OPEN_PARAMS;
typedef struct { PVOID Buffer; size_t Size; } WDF_MEMORY_DESCRIPTOR;
typedef struct { int Unused; } WDF_REQUEST_SEND_OPTIONS;
/* Registry surface the adapter uses for the per-boot attempt id. */
typedef void *WDFKEY;
typedef const UNICODE_STRING *PCUNICODE_STRING;
#define PLUGPLAY_REGKEY_DEVICE 1
#define KEY_READ 0x20019u
#define RTL_CONSTANT_STRING(text) { (wchar_t *)(text), 0 }
NTSTATUS WdfDeviceOpenRegistryKey(WDFDEVICE device,int type,ULONG access,PVOID attributes,WDFKEY *key);
NTSTATUS WdfRegistryQueryULong(WDFKEY key,PCUNICODE_STRING name,ULONG *value);
VOID WdfRegistryClose(WDFKEY key);
#define WDF_NO_OBJECT_ATTRIBUTES NULL
#define WDF_IO_TARGET_OPEN_PARAMS_INIT_OPEN_BY_NAME(p,path,access) ((p)->Path=(path),(p)->Access=(access))
#define WDF_MEMORY_DESCRIPTOR_INIT_BUFFER(p,buffer,size) ((p)->Buffer=(buffer),(p)->Size=(size))
#define WDF_REQUEST_SEND_OPTION_TIMEOUT 1
#define WDF_REQUEST_SEND_OPTIONS_INIT(p,flags) ((void)(p),(void)(flags))
#define WDF_REQUEST_SEND_OPTIONS_SET_TIMEOUT(p,timeout) ((void)(p),(void)(timeout))
#define WDF_REL_TIMEOUT_IN_MS(ms) (ms)
ULONG WdfCmResourceListGetCount(WDFCMRESLIST resources);
PCM_PARTIAL_RESOURCE_DESCRIPTOR WdfCmResourceListGetDescriptor(WDFCMRESLIST resources,ULONG index);
NTSTATUS WdfIoTargetCreate(WDFDEVICE device,PVOID attributes,WDFIOTARGET *target);
NTSTATUS WdfIoTargetOpen(WDFIOTARGET target,WDF_IO_TARGET_OPEN_PARAMS *parameters);
VOID WdfIoTargetClose(WDFIOTARGET target);
VOID WdfObjectDelete(WDFIOTARGET target);
NTSTATUS WdfIoTargetQueryForInterface(WDFIOTARGET target,const GUID *guid,PINTERFACE bus,USHORT size,USHORT version,PVOID data);
NTSTATUS WdfIoTargetSendIoctlSynchronously(WDFIOTARGET target,WDFREQUEST request,ULONG ioctl,WDF_MEMORY_DESCRIPTOR *in,WDF_MEMORY_DESCRIPTOR *out,WDF_REQUEST_SEND_OPTIONS *options,ULONG_PTR *returned);
BOOLEAN WdfRequestIsCanceled(WDFREQUEST request);
#endif
