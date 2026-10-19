// SPDX-License-Identifier: BSD-2-Clause-Patent
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#undef NULL
#include "../I2cClockDiag.c"

STATIC EFI_BOOT_SERVICES mBs;
STATIC EFI_SIMPLE_TEXT_OUTPUT_PROTOCOL mConsole;
STATIC EFI_SYSTEM_TABLE mTable;
STATIC EFI_USB2_HC_PROTOCOL mHc;
STATIC EFI_USB_IO_PROTOCOL mIo;
STATIC int mScenario, mAllocations, mFrees, mPorts, mDevices;
STATIC EFI_STATUS EFIAPI Print (EFI_SIMPLE_TEXT_OUTPUT_PROTOCOL *This, CHAR16 *String)
{ (VOID)This; (VOID)String; return EFI_SUCCESS; }
STATIC EFI_STATUS EFIAPI LocateHandles (EFI_LOCATE_SEARCH_TYPE Type, EFI_GUID *Guid,
                                       VOID *Key, UINTN *Count, EFI_HANDLE **Handles)
{
  UINTN I;
  BOOLEAN Host = memcmp(Guid, &mUsbHostGuid, sizeof(*Guid)) == 0;
  assert(Type == ByProtocol && Key == NULL);
  if (mScenario == 0) { *Count = 0; *Handles = NULL; return EFI_NOT_FOUND; }
  *Count = mScenario == 4 ? (Host ? 8 : 20) : 1;
  *Handles = malloc(*Count * sizeof(**Handles)); assert(*Handles != NULL); ++mAllocations;
  for (I = 0; I < *Count; ++I) (*Handles)[I] = (EFI_HANDLE)(UINTN)(Host ? 1 : 2);
  return EFI_SUCCESS;
}
STATIC EFI_STATUS EFIAPI Handle (EFI_HANDLE Handle, EFI_GUID *Guid, VOID **Protocol)
{
  (VOID)Guid;
  *Protocol = mScenario == 3 ? NULL : Handle == (EFI_HANDLE)1 ? (VOID *)&mHc : (VOID *)&mIo;
  return EFI_SUCCESS;
}
STATIC EFI_STATUS EFIAPI Free (VOID *Buffer) { free(Buffer); ++mFrees; return EFI_SUCCESS; }
STATIC EFI_STATUS EFIAPI State (EFI_USB2_HC_PROTOCOL *This, EFI_USB_HC_STATE *Value)
{ assert(This == &mHc); *Value = EfiUsbHcStateOperational; return EFI_SUCCESS; }
STATIC EFI_STATUS EFIAPI Capability (EFI_USB2_HC_PROTOCOL *This, UINT8 *Speed, UINT8 *Ports, UINT8 *Address64)
{
  assert(This == &mHc);
  *Speed = EFI_USB_SPEED_SUPER; *Ports = mScenario == 4 ? 255 : 2; *Address64 = 1;
  return mScenario == 2 ? EFI_DEVICE_ERROR : EFI_SUCCESS;
}
STATIC EFI_STATUS EFIAPI PortStatus (EFI_USB2_HC_PROTOCOL *This, UINT8 Port, EFI_USB_PORT_STATUS *Value)
{
  assert(This == &mHc && Port < 16); ++mPorts;
  Value->PortStatus = USB_PORT_STAT_CONNECTION | USB_PORT_STAT_ENABLE | USB_PORT_STAT_POWER;
  Value->PortChangeStatus = USB_PORT_STAT_C_CONNECTION;
  return Port == 1 ? EFI_DEVICE_ERROR : EFI_SUCCESS;
}
STATIC EFI_STATUS EFIAPI Device (EFI_USB_IO_PROTOCOL *This, EFI_USB_DEVICE_DESCRIPTOR *Value)
{
  assert(This == &mIo); ++mDevices;
  Value->IdVendor = 0x03f0; Value->IdProduct = 0x564a;
  return mScenario == 5 ? EFI_DEVICE_ERROR : EFI_SUCCESS;
}
STATIC EFI_STATUS EFIAPI Interface (EFI_USB_IO_PROTOCOL *This, EFI_USB_INTERFACE_DESCRIPTOR *Value)
{ assert(This == &mIo); Value->InterfaceClass = 3; Value->InterfaceProtocol = 2; return EFI_SUCCESS; }
int main (void)
{
  mBs.LocateHandleBuffer = LocateHandles; mBs.HandleProtocol = Handle; mBs.FreePool = Free;
  mConsole.OutputString = Print; mTable.ConOut = &mConsole; mTable.BootServices = &mBs; mSystem = &mTable;
  // All setters, reset, control and bulk transfer callbacks remain NULL.
  mHc.GetState = State; mHc.GetCapability = Capability; mHc.GetRootHubPortStatus = PortStatus;
  mIo.UsbGetDeviceDescriptor = Device; mIo.UsbGetInterfaceDescriptor = Interface;
  for (mScenario = 0; mScenario < 6; ++mScenario) {
    mAllocations = mFrees = mPorts = mDevices = 0; mLogLength = 0;
    QueryUsb(&mTable);
    assert(mAllocations == mFrees);
    assert(mPorts == (mScenario == 0 || mScenario == 2 || mScenario == 3 ? 0 : mScenario == 4 ? 64 : 2));
    assert(mDevices == (mScenario == 0 || mScenario == 3 ? 0 : mScenario == 4 ? 16 : 1));
    assert(mLogLength < sizeof(mLog)); mLog[mLogLength] = 0;
    if (mScenario == 1) assert(strstr(mLog, "VID=0x00000000000003f0 PID=0x000000000000564a"));
    if (mScenario == 2) assert(strstr(mLog, "capability status=0x8000000000000007"));
  }
  mHc.GetState = NULL; mHc.GetCapability = NULL;
  mIo.UsbGetDeviceDescriptor = NULL; mIo.UsbGetInterfaceDescriptor = NULL;
  mScenario = 1; mLogLength = 0; QueryUsb(&mTable);
  puts("USB snapshot: absent/null protocols, errors, bounded enumeration and getter-only callbacks passed");
  return 0;
}
