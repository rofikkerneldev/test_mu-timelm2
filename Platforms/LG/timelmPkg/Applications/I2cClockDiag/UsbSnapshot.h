// SPDX-License-Identifier: BSD-2-Clause-Patent
// Query existing UEFI host/bus protocols. Never connect/reset a controller,
// switch roles, clear port changes, set port power, or submit USB transfers.
#include <Protocol/Usb2HostController.h>

STATIC EFI_GUID mUsbHostGuid = EFI_USB2_HC_PROTOCOL_GUID;
STATIC EFI_GUID mUsbIoGuid = EFI_USB_IO_PROTOCOL_GUID;

STATIC VOID QueryUsb (EFI_SYSTEM_TABLE *System)
{
  EFI_BOOT_SERVICES *Bs = System->BootServices;
  EFI_HANDLE *Handles = NULL;
  UINTN Count = 0, Index;
  EFI_STATUS Status;
  Text ("USB protocol snapshot v1; no role/power/reset/transfer requests.\r\n");
  if (!Bs->LocateHandleBuffer || !Bs->HandleProtocol || !Bs->FreePool) {
    Text ("USB handle enumeration unavailable.\r\n");
    return;
  }
  Status = Bs->LocateHandleBuffer (ByProtocol, &mUsbHostGuid, NULL, &Count, &Handles);
  Text ("USB2_HC locate status="); Hex (Status); Text (" count="); Hex (Count); Text ("\r\n");
  if (!EFI_ERROR (Status) && Handles != NULL) {
    for (Index = 0; Index < Count && Index < 4; ++Index) {
      EFI_USB2_HC_PROTOCOL *Hc = NULL;
      UINT8 Speed = 0, Ports = 0, Address64 = 0, Port;
      EFI_USB_HC_STATE State = EfiUsbHcStateHalt;
      Text ("HC index="); Hex (Index); Text ("\r\n");
      Status = Bs->HandleProtocol (Handles[Index], &mUsbHostGuid, (VOID **)&Hc);
      Text ("  HandleProtocol="); Hex (Status); Text ("\r\n");
      if (EFI_ERROR (Status) || Hc == NULL) continue;
      Status = Hc->GetState ? Hc->GetState (Hc, &State) : EFI_UNSUPPORTED;
      Text ("  state(status,value)="); Hex (Status); Text (","); Hex (State); Text ("\r\n");
      Status = Hc->GetCapability ? Hc->GetCapability (Hc, &Speed, &Ports, &Address64) : EFI_UNSUPPORTED;
      Text ("  capability status="); Hex (Status); Text (" speed="); Hex (Speed);
      Text (" ports="); Hex (Ports); Text (" address64="); Hex (Address64); Text ("\r\n");
      if (EFI_ERROR (Status) || !Hc->GetRootHubPortStatus) continue;
      for (Port = 0; Port < Ports && Port < 16; ++Port) {
        EFI_USB_PORT_STATUS Value = {0, 0};
        Status = Hc->GetRootHubPortStatus (Hc, Port, &Value);
        Text ("  port="); Hex (Port); Text (" status="); Hex (Status);
        Text (" bits="); Hex (Value.PortStatus); Text (" change="); Hex (Value.PortChangeStatus); Text ("\r\n");
      }
      if (Ports > 16) Text ("  Port query limited to first 16 ports.\r\n");
    }
    if (Count > 4) Text ("HC query limited to first 4 controllers.\r\n");
  }
  if (Handles != NULL) Bs->FreePool (Handles);
  Handles = NULL; Count = 0;
  Status = Bs->LocateHandleBuffer (ByProtocol, &mUsbIoGuid, NULL, &Count, &Handles);
  Text ("USB_IO locate status="); Hex (Status); Text (" interface count="); Hex (Count); Text ("\r\n");
  if (!EFI_ERROR (Status) && Handles != NULL) {
    for (Index = 0; Index < Count && Index < 16; ++Index) {
      EFI_USB_IO_PROTOCOL *Io = NULL;
      EFI_USB_DEVICE_DESCRIPTOR Device = {0};
      EFI_USB_INTERFACE_DESCRIPTOR Interface = {0};
      Text ("USB interface index="); Hex (Index); Text ("\r\n");
      Status = Bs->HandleProtocol (Handles[Index], &mUsbIoGuid, (VOID **)&Io);
      Text ("  HandleProtocol="); Hex (Status); Text ("\r\n");
      if (EFI_ERROR (Status) || Io == NULL) continue;
      // UEFI specifies these getters return descriptors cached by UsbBusDxe.
      Status = Io->UsbGetDeviceDescriptor ? Io->UsbGetDeviceDescriptor (Io, &Device) : EFI_UNSUPPORTED;
      Text ("  device status="); Hex (Status); Text (" VID="); Hex (Device.IdVendor);
      Text (" PID="); Hex (Device.IdProduct); Text ("\r\n");
      Status = Io->UsbGetInterfaceDescriptor ? Io->UsbGetInterfaceDescriptor (Io, &Interface) : EFI_UNSUPPORTED;
      Text ("  interface status="); Hex (Status); Text (" class="); Hex (Interface.InterfaceClass);
      Text (" subclass="); Hex (Interface.InterfaceSubClass); Text (" protocol="); Hex (Interface.InterfaceProtocol); Text ("\r\n");
    }
    if (Count > 16) Text ("USB interface query limited to first 16 interfaces.\r\n");
  }
  if (Handles != NULL) Bs->FreePool (Handles);
  Text ("HC state: 0=halt, 1=operational, 2=suspend. Port bits: 1=connected, 2=enabled, 0x100=power.\r\n");
  Text ("Port power bit is controller state, not proof of measured connector VBUS.\r\n");
  Text ("An absent host protocol does not distinguish role, PHY, power or driver-binding failure.\r\n");
}
