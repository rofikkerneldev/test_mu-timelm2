// SPDX-License-Identifier: BSD-2-Clause-Patent
// Minimal ABI prefix, not a copy of the vendor implementation. See USB-HOST.md.
#include <Protocol/PciIo.h>
#include <Protocol/DevicePath.h>

typedef struct TIMELM_USB_CONFIG TIMELM_USB_CONFIG;
typedef EFI_STATUS (EFIAPI *USB_CORE_BASE)(TIMELM_USB_CONFIG *, UINT32, UINTN *);
typedef EFI_STATUS (EFIAPI *USB_HOST_CONFIG)(TIMELM_USB_CONFIG *, UINT32, UINT32, UINT32 *);
typedef EFI_STATUS (EFIAPI *USB_CONTROLLER)(TIMELM_USB_CONFIG *, UINT32, UINT32);
typedef EFI_STATUS (EFIAPI *USB_CORE_COUNT)(TIMELM_USB_CONFIG *, UINT8 *);
typedef EFI_STATUS (EFIAPI *USB_SUPPORTED)(TIMELM_USB_CONFIG *, UINT32, UINT32 *);
struct TIMELM_USB_CONFIG {
  UINT32 Revision;
  USB_CORE_BASE GetCoreBaseAddr;
  VOID *Unused10, *Unused18, *Unused20, *Unused28, *Unused30;
  USB_HOST_CONFIG GetUsbHostConfig;
  VOID *Unused40, *Unused48;
  USB_CONTROLLER StartController, StopController;
  VOID *Unused60, *Unused68, *Unused70;
  USB_CORE_COUNT GetCoreCount;
  USB_SUPPORTED GetSupportedMode;
  UINT32 CoreNum, ModeType;
};
_Static_assert(sizeof(VOID *) == 8, "64-bit ABI only");
_Static_assert(OFFSET_OF(TIMELM_USB_CONFIG, StartController) == 0x50, "USB start ABI");
_Static_assert(OFFSET_OF(TIMELM_USB_CONFIG, StopController) == 0x58, "USB stop ABI");
_Static_assert(OFFSET_OF(TIMELM_USB_CONFIG, GetCoreCount) == 0x78, "USB count ABI");
_Static_assert(OFFSET_OF(TIMELM_USB_CONFIG, GetSupportedMode) == 0x80, "USB mode ABI");
_Static_assert(OFFSET_OF(TIMELM_USB_CONFIG, CoreNum) == 0x88, "USB core ABI");

STATIC EFI_GUID mUsbConfigGuid = {0xe722b03f,0xb250,0x42ce,{0x8e,0xbd,0x5b,0xd5,0x18,0x12,0xd0,0x37}};
STATIC EFI_GUID mUsbVariableGuid = {0x882f8c2b,0x9646,0x435f,{0x8d,0xe5,0xf2,0x08,0xff,0x80,0xc1,0xbd}};
STATIC CONST UINTN mUsbMethodRvas[] = {0x141c,0x14d0,0x14ec,0x1534,0x15dc,0x1650};
STATIC CONST UINT8 mUsbMethodCode[6][16] = {
  {0xe0,0x03,0x01,0x2a,0xe1,0x03,0x02,0xaa,0x2d,0x06,0x00,0x14,0xe0,0x03,0x01,0x2a},
  {0xe0,0x03,0x01,0x2a,0xe1,0x03,0x02,0x2a,0xe2,0x03,0x03,0xaa,0xda,0x08,0x00,0x14},
  {0xf3,0x0f,0x1e,0xf8,0xfd,0x7b,0x01,0xa9,0xfd,0x43,0x00,0x91,0xe0,0x03,0x01,0x2a},
  {0xf3,0x0f,0x1e,0xf8,0xfd,0x7b,0x01,0xa9,0xfd,0x43,0x00,0x91,0xe0,0x03,0x01,0x2a},
  {0xf3,0x0f,0x1e,0xf8,0xfd,0x7b,0x01,0xa9,0xfd,0x43,0x00,0x91,0xc0,0x01,0x00,0xb4},
  {0xf3,0x0f,0x1e,0xf8,0xfd,0x7b,0x01,0xa9,0xfd,0x43,0x00,0x91,0xe0,0x01,0x00,0xb4}
};

// Check only bytes inside a matching LoadedImage allocation, never MMIO.
STATIC BOOLEAN UsbOwnerMatches (TIMELM_USB_CONFIG *Config, VOID *Base, UINT64 Size)
{
  UINTN Methods[6], I, J, Address = (UINTN)Base;
  if (!Config || !Base || Size != 0x17000 || Address > (UINTN)-1 - 0x17000) return FALSE;
  Methods[0]=(UINTN)Config->GetCoreBaseAddr; Methods[1]=(UINTN)Config->GetUsbHostConfig;
  Methods[2]=(UINTN)Config->StartController; Methods[3]=(UINTN)Config->StopController;
  Methods[4]=(UINTN)Config->GetCoreCount; Methods[5]=(UINTN)Config->GetSupportedMode;
  for (I=0; I<6; ++I) {
    if (Methods[I] != Address + mUsbMethodRvas[I]) return FALSE;
    for (J=0; J<16; ++J)
      if (((UINT8 *)Base)[mUsbMethodRvas[I]+J] != mUsbMethodCode[I][J]) return FALSE;
  }
  return TRUE;
}

STATIC BOOLEAN KnownUsbOwner (EFI_SYSTEM_TABLE *System, TIMELM_USB_CONFIG *Config)
{
  EFI_HANDLE *Handles=NULL;
  UINTN Count=0, I;
  BOOLEAN Match=FALSE;
  EFI_BOOT_SERVICES *Bs=System->BootServices;
  EFI_STATUS Status=Bs->LocateHandleBuffer(ByProtocol,&mLoadedImageGuid,NULL,&Count,&Handles);
  if (!EFI_ERROR(Status) && Handles) {
    for (I=0; I<Count && I<512; ++I) {
      EFI_LOADED_IMAGE_PROTOCOL *Loaded=NULL;
      Status=Bs->HandleProtocol(Handles[I],&mLoadedImageGuid,(VOID **)&Loaded);
      if (!EFI_ERROR(Status) && Loaded && UsbOwnerMatches(Config,Loaded->ImageBase,Loaded->ImageSize)) {
        Match=TRUE; break;
      }
    }
  }
  if (Handles) Bs->FreePool(Handles);
  return Match;
}

STATIC EFI_STATUS UsbHostCount (EFI_SYSTEM_TABLE *System, UINTN *Count)
{
  EFI_HANDLE *Handles=NULL;
  EFI_STATUS Status;
  *Count=0;
  Status=System->BootServices->LocateHandleBuffer(ByProtocol,&mUsbHostGuid,NULL,Count,&Handles);
  if (Handles) System->BootServices->FreePool(Handles);
  if (Status==EFI_NOT_FOUND) { *Count=0; return EFI_SUCCESS; }
  return Status;
}

// Read protocol metadata only: no driver connection, protocol opens or PCI reads.
STATIC VOID UsbConfigSnapshot (EFI_SYSTEM_TABLE *System, CONST CHAR8 *Phase)
{
  EFI_BOOT_SERVICES *Bs=System->BootServices;
  EFI_HANDLE *Handles=NULL;
  UINTN Count=0, I;
  EFI_STATUS Status;
  STATIC EFI_GUID PciGuid=EFI_PCI_IO_PROTOCOL_GUID;
  Text("USB config snapshot phase="); Text(Phase); Text("\r\n");
  if (!Bs->LocateHandleBuffer || !Bs->HandleProtocol || !Bs->FreePool) return;
  Status=Bs->LocateHandleBuffer(ByProtocol,&mUsbConfigGuid,NULL,&Count,&Handles);
  Text("QCOM config locate status="); Hex(Status); Text(" count="); Hex(Count); Text("\r\n");
  if (!EFI_ERROR(Status) && Handles) {
    for (I=0; I<Count && I<8; ++I) {
      TIMELM_USB_CONFIG *Config=NULL;
      EFI_OPEN_PROTOCOL_INFORMATION_ENTRY *Entries=NULL;
      UINTN EntryCount=0, J, Drivers=0, Children=0;
      VOID *Pci=NULL;
      Status=Bs->HandleProtocol(Handles[I],&mUsbConfigGuid,(VOID **)&Config);
      Text("  instance="); Hex(I); Text(" status="); Hex(Status);
      if (!EFI_ERROR(Status) && Config) {
        Text(" revision="); Hex(Config->Revision);
        if (Config->Revision==0x10005) {
          Text(" core="); Hex(Config->CoreNum); Text(" mode="); Hex(Config->ModeType);
        }
      }
      Text("\r\n");
      Status=Bs->HandleProtocol(Handles[I],&PciGuid,&Pci);
      Text("    same-handle PCI_IO status="); Hex(Status); Text("\r\n");
      if (!Bs->OpenProtocolInformation) continue;
      Status=Bs->OpenProtocolInformation(Handles[I],&mUsbConfigGuid,&Entries,&EntryCount);
      if (!EFI_ERROR(Status) && Entries) {
        for (J=0; J<EntryCount && J<32; ++J) {
          if (Entries[J].Attributes & EFI_OPEN_PROTOCOL_BY_DRIVER) ++Drivers;
          if (Entries[J].Attributes & EFI_OPEN_PROTOCOL_BY_CHILD_CONTROLLER) ++Children;
        }
      }
      Text("    QCOM opens status="); Hex(Status); Text(" entries="); Hex(EntryCount);
      Text(" drivers="); Hex(Drivers); Text(" children="); Hex(Children); Text("\r\n");
      if (EntryCount>32) Text("    Open entries limited to first 32.\r\n");
      if (Entries) Bs->FreePool(Entries);
    }
    if (Count>8) Text("QCOM instances limited to first 8.\r\n");
  }
  if (Handles) Bs->FreePool(Handles);
  Handles=NULL; Count=0;
  Status=Bs->LocateHandleBuffer(ByProtocol,&PciGuid,NULL,&Count,&Handles);
  Text("Global PCI_IO locate status="); Hex(Status); Text(" count="); Hex(Count); Text("\r\n");
  if (Handles) Bs->FreePool(Handles);
}

STATIC VOID UsbOverrideSnapshot (EFI_SYSTEM_TABLE *System)
{
  STATIC CONST CHAR16 *Names[]={L"UsbConfigPrimaryPort",L"UsbConfigSecondaryPort",L"EnableSLTLoopback",L"UsbFastbootSecPort"};
  STATIC CONST CHAR8 *Labels[]={"UsbConfigPrimaryPort","UsbConfigSecondaryPort","EnableSLTLoopback","UsbFastbootSecPort"};
  UINTN I;
  if (!System->RuntimeServices || !System->RuntimeServices->GetVariable) return;
  for (I=0; I<4; ++I) {
    UINT8 Value=0; UINTN Size=1; UINT32 Attributes=0;
    EFI_STATUS Status=System->RuntimeServices->GetVariable((CHAR16 *)Names[I],&mUsbVariableGuid,&Attributes,&Size,&Value);
    Text(Labels[I]); Text(" GetVariable status="); Hex(Status);
    Text(" size="); Hex(Size); Text(" byte="); Hex(Value); Text(" attributes="); Hex(Attributes); Text("\r\n");
  }
}

// Retry only the new primary host's standard bus binding, never ConnectAll.
// All private request/owner gates in ExercisePrimaryHost must have passed.
STATIC VOID ConnectPrimaryUsbBus (EFI_SYSTEM_TABLE *System)
{
  EFI_BOOT_SERVICES *Bs=System->BootServices;
  EFI_HANDLE *Handles=NULL;
  EFI_OPEN_PROTOCOL_INFORMATION_ENTRY *Entries=NULL;
  TIMELM_USB_CONFIG *Config=NULL;
  VOID *Pci=NULL, *Path=NULL;
  UINTN Count=0, EntryCount=0, I, Drivers=0;
  EFI_STATUS Status;
  STATIC EFI_GUID PathGuid=EFI_DEVICE_PATH_PROTOCOL_GUID;
  if (!Bs->ConnectController || !Bs->OpenProtocolInformation) {
    Text("USB bus connect skipped: standard callbacks unavailable.\r\n"); return;
  }
  Status=Bs->LocateHandleBuffer(ByProtocol,&mUsbHostGuid,NULL,&Count,&Handles);
  Text("USB bus target locate status="); Hex(Status); Text(" count="); Hex(Count); Text("\r\n");
  if (EFI_ERROR(Status) || !Handles || Count!=1) goto Done;
  Status=Bs->HandleProtocol(Handles[0],&mUsbConfigGuid,(VOID **)&Config);
  if (EFI_ERROR(Status) || !Config || Config->Revision!=0x10005 ||
      Config->CoreNum!=0 || Config->ModeType!=1 || !KnownUsbOwner(System,Config)) {
    Text("USB bus connect skipped: host is not the known primary QCOM handle.\r\n"); goto Done;
  }
  {
    STATIC EFI_GUID PciGuid=EFI_PCI_IO_PROTOCOL_GUID;
    Status=Bs->HandleProtocol(Handles[0],&PciGuid,&Pci);
  }
  Text("USB bus target PCI_IO status="); Hex(Status); Text("\r\n");
  if (EFI_ERROR(Status) || !Pci) goto Done;
  Status=Bs->HandleProtocol(Handles[0],&PathGuid,&Path);
  Text("USB bus target device path status="); Hex(Status); Text("\r\n");
  if (EFI_ERROR(Status) || !Path) goto Done;
  Status=Bs->OpenProtocolInformation(Handles[0],&mUsbHostGuid,&Entries,&EntryCount);
  if (!EFI_ERROR(Status) && Entries && EntryCount<=32)
    for (I=0; I<EntryCount; ++I)
      if (Entries[I].Attributes & EFI_OPEN_PROTOCOL_BY_DRIVER) ++Drivers;
  Text("USB2_HC opens status="); Hex(Status); Text(" entries="); Hex(EntryCount);
  Text(" drivers="); Hex(Drivers); Text("\r\n");
  if (EFI_ERROR(Status) || EntryCount>32 || (EntryCount && !Entries)) goto Done;
  if (Drivers) { Text("USB bus connect skipped: USB2_HC already has a driver.\r\n"); goto Done; }
  Text("Connecting only verified primary USB2_HC handle, recursively.\r\n");
  Status=Bs->ConnectController(Handles[0],NULL,NULL,TRUE);
  Text("Targeted USB bus ConnectController status="); Hex(Status); Text("\r\n");
Done:
  if (Entries) Bs->FreePool(Entries);
  if (Handles) Bs->FreePool(Handles);
}

// Return an error only when cleanup cannot be established. The caller ends
// every host-probe run in firmware, including skips and cleaned-up failures.
STATIC EFI_STATUS ExercisePrimaryHost (EFI_HANDLE Image, EFI_SYSTEM_TABLE *System,
  TIMELM_USB_CONFIG *Config, BOOLEAN VerifiedOwner, EFI_STATUS (*Checkpoint)(EFI_HANDLE))
{
  UINT8 Cores=0;
  UINT32 Supported=0, Type=0;
  UINTN Base=0, Hosts=0;
  BOOLEAN Dispatcher;
  EFI_STATUS Status, StopStatus, RestoreStatus, CountStatus;
  if (!VerifiedOwner || !Config || Config->Revision!=0x10005 ||
      !Config->GetCoreCount || !Config->GetSupportedMode || !Config->GetUsbHostConfig ||
      !Config->GetCoreBaseAddr || !Config->StartController || !Config->StopController ||
      !System->BootServices->Stall || !Checkpoint) {
    Text("Host probe skipped: firmware ABI/owner/callback gate.\r\n"); return EFI_SUCCESS;
  }
  Text("USB config template core="); Hex(Config->CoreNum); Text(" mode="); Hex(Config->ModeType); Text("\r\n");
  // UsbConfigInit publishes a dispatcher with core=MAX_NUM (2), mode=INVALID.
  // Start/Stop take the target core explicitly; this is not a request for core 2.
  Dispatcher=(Config->CoreNum==2 && Config->ModeType==0x10000);
  if (!Dispatcher && (Config->CoreNum!=0 || Config->ModeType!=4)) {
    Text("Host probe skipped: neither known dispatcher nor primary peripheral descriptor.\r\n"); return EFI_SUCCESS;
  }
  Text(Dispatcher ? "Known global dispatcher; all requests still target core 0.\r\n" : "Primary peripheral descriptor.\r\n");
  Status=Config->GetCoreCount(Config,&Cores);
  Text("GetCoreCount status="); Hex(Status); Text(" count="); Hex(Cores); Text("\r\n");
  if (EFI_ERROR(Status) || Cores<1 || Cores>2 || (Dispatcher && Cores!=2)) return EFI_SUCCESS;
  Status=Config->GetSupportedMode(Config,0,&Supported);
  Text("Primary supported mode status="); Hex(Status); Text(" mask="); Hex(Supported); Text("\r\n");
  if (EFI_ERROR(Status) || (!(Supported & 8) && Supported!=1 && Supported!=0x20)) return EFI_SUCCESS;
  Status=Config->GetUsbHostConfig(Config,1,0,&Type);
  Text("Primary host config status="); Hex(Status); Text(" core type="); Hex(Type); Text("\r\n");
  if (EFI_ERROR(Status) || Type!=5) return EFI_SUCCESS;
  Status=Config->GetCoreBaseAddr(Config,Type,&Base);
  Text("Core base query status="); Hex(Status); Text(" base="); Hex(Base); Text("\r\n");
  if (EFI_ERROR(Status) || Base!=0x0a600000) return EFI_SUCCESS;
  Status=UsbHostCount(System,&Hosts);
  Text("Before request host count status="); Hex(Status); Text(" count="); Hex(Hosts); Text("\r\n");
  if (EFI_ERROR(Status) || Hosts!=0) return EFI_SUCCESS;
  UsbConfigSnapshot(System,"before-start");
  Text("NEXT: native StartController(core=0,mode=1); temporary test, then cleanup.\r\n");
  Status=Checkpoint(Image);
  if (EFI_ERROR(Status)) { Text("Checkpoint failed; no host request made.\r\n"); return EFI_SUCCESS; }
  Status=Config->StartController(Config,0,1);
  Text("Start xHCI host result="); Hex(Status); Text("\r\n");
  UsbConfigSnapshot(System,"after-start");
  if (!EFI_ERROR(Status)) {
    (VOID)System->BootServices->Stall(3000000);
    Text("USB snapshot before targeted bus binding.\r\n");
    QueryUsb(System);
    ConnectPrimaryUsbBus(System);
    (VOID)System->BootServices->Stall(3000000);
    Text("USB snapshot after targeted bus binding.\r\n");
    QueryUsb(System);
  }
  // Even a failed start may have changed partial firmware state.
  StopStatus=Config->StopController(Config,0,1);
  Text("Stop transient host result="); Hex(StopStatus); Text("\r\n");
  RestoreStatus=Config->StartController(Config,0,4);
  Text("Restore primary peripheral result="); Hex(RestoreStatus); Text("\r\n");
  UsbConfigSnapshot(System,"after-cleanup");
  CountStatus=UsbHostCount(System,&Hosts);
  Text("After cleanup host count status="); Hex(CountStatus); Text(" count="); Hex(Hosts); Text("\r\n");
  if ((EFI_ERROR(StopStatus) && StopStatus!=EFI_NOT_STARTED) || EFI_ERROR(RestoreStatus) ||
      EFI_ERROR(CountStatus) || Hosts!=0) return EFI_DEVICE_ERROR;
  Text("Temporary host teardown verified; firmware test ends before Windows.\r\n");
  return EFI_SUCCESS;
}

STATIC EFI_STATUS ProbePrimaryUsbHost (EFI_HANDLE Image, EFI_SYSTEM_TABLE *System)
{
  TIMELM_USB_CONFIG *Config=NULL;
  EFI_STATUS Status;
  BOOLEAN Owner;
  Text("timelm transient primary USB host probe v4\r\n");
  UsbOverrideSnapshot(System);
  if (!System->BootServices->LocateHandleBuffer || !System->BootServices->FreePool) return EFI_SUCCESS;
  Status=System->BootServices->LocateProtocol(&mUsbConfigGuid,NULL,(VOID **)&Config);
  Text("Locate QCOM USB config="); Hex(Status); Text("\r\n");
  if (EFI_ERROR(Status) || !Config) return EFI_SUCCESS;
  Text("USB config revision="); Hex(Config->Revision); Text("\r\n");
  if (Config->Revision!=0x10005) return EFI_SUCCESS;
  Owner=KnownUsbOwner(System,Config);
  Text("Known LG driver owner/code match="); Hex(Owner); Text("\r\n");
  return ExercisePrimaryHost(Image,System,Config,Owner,SaveLog);
}
