/* SPDX-License-Identifier: GPL-2.0-only */
#define RESOURCE_HUB_PATH_SIZE 64
#define DECLARE_UNICODE_STRING_SIZE(name,size) UNICODE_STRING name={NULL,0}
static NTSTATUS RESOURCE_HUB_CREATE_PATH_FROM_ID(UNICODE_STRING *path,ULONG low,ULONG high)
{ path->ResourceId=low;(void)high;return STATUS_SUCCESS; }
