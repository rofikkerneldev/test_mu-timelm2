/* SPDX-License-Identifier: GPL-2.0-only */
#ifndef TIMELM_PROBE_TEST_WDF_H
#define TIMELM_PROBE_TEST_WDF_H
#include "ntddk.h"
typedef void *WDFDEVICE;
typedef struct TEST_RESOURCE_LIST {
    CM_PARTIAL_RESOURCE_DESCRIPTOR Entries[16];
    ULONG Count;
    int NullIndex;
} TEST_RESOURCE_LIST, *WDFCMRESLIST;
ULONG WdfCmResourceListGetCount(WDFCMRESLIST resources);
PCM_PARTIAL_RESOURCE_DESCRIPTOR WdfCmResourceListGetDescriptor(WDFCMRESLIST resources, ULONG index);
#endif
