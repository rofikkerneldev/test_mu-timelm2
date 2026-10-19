// SPDX-License-Identifier: BSD-2-Clause-Patent
// A transient Windows ACPI trial, separate from the shutdown-only diagnostic.
#include <Protocol/AcpiTable.h>
#include <Protocol/AcpiSystemDescriptionTable.h>
#include <UsbWindowsAcpi.h>

STATIC EFI_GUID mAcpiTableGuid=EFI_ACPI_TABLE_PROTOCOL_GUID;
STATIC EFI_GUID mAcpiSdtGuid=EFI_ACPI_SDT_PROTOCOL_GUID;

STATIC BOOLEAN BytesEqual(CONST UINT8 *A, CONST UINT8 *B, UINTN Length)
{
  UINTN I;
  for (I=0; I<Length; ++I) if (A[I]!=B[I]) return FALSE;
  return TRUE;
}
STATIC BOOLEAN AcpiChecksum(CONST UINT8 *Data, UINTN Length)
{
  UINT8 Sum=0; UINTN I;
  for (I=0; I<Length; ++I) Sum=(UINT8)(Sum+Data[I]);
  return Sum==0;
}
STATIC BOOLEAN KnownTimelmDsdt(CONST UINT8 *Data, UINTN Length)
{
  UINTN I;
  if (!Data || Length!=sizeof(mTimelmDsdt) || !AcpiChecksum(Data,Length)) return FALSE;
  for (I=0; I<Length; ++I)
    if (!mTimelmDsdtMask[I] && Data[I]!=mTimelmDsdt[I]) return FALSE;
  return TRUE;
}

// Restrict the trial to the known minimal namespace: one matching DSDT and no
// SSDTs, including disabled or unrelated extensions whose AML is not audited.
STATIC EFI_STATUS CheckWindowsNamespace(EFI_ACPI_SDT_PROTOCOL *Sdt)
{
  UINTN I, DsdtCount=0;
  for (I=0; I<64; ++I) {
    EFI_ACPI_SDT_HEADER *Table=NULL;
    EFI_ACPI_TABLE_VERSION Version=0;
    UINTN Key=0;
    EFI_STATUS Status=Sdt->GetAcpiTable(I,&Table,&Version,&Key);
    if (Status==EFI_NOT_FOUND) return DsdtCount==1 ? EFI_SUCCESS : EFI_NOT_FOUND;
    if (EFI_ERROR(Status)) return Status;
    if (!Table) return EFI_COMPROMISED_DATA;
    if (Table->Signature==SIGNATURE_32('S','S','D','T')) return EFI_ACCESS_DENIED;
    if (Table->Signature==SIGNATURE_32('D','S','D','T')) {
      ++DsdtCount;
      if (!KnownTimelmDsdt((CONST UINT8 *)Table,Table->Length)) return EFI_COMPROMISED_DATA;
    }
  }
  return EFI_BAD_BUFFER_SIZE;
}

STATIC EFI_STATUS VerifyWindowsSsdt(EFI_ACPI_SDT_PROTOCOL *Sdt)
{
  UINTN I, Found=0;
  for (I=0; I<64; ++I) {
    EFI_ACPI_SDT_HEADER *Table=NULL;
    EFI_ACPI_TABLE_VERSION Version=0;
    UINTN Key=0;
    EFI_STATUS Status=Sdt->GetAcpiTable(I,&Table,&Version,&Key);
    if (Status==EFI_NOT_FOUND) return Found==1 ? EFI_SUCCESS : EFI_NOT_FOUND;
    if (EFI_ERROR(Status)) return Status;
    if (!Table) return EFI_COMPROMISED_DATA;
    if (Table->Signature==SIGNATURE_32('S','S','D','T') &&
        Table->Length==sizeof(mUsbHostSsdt) &&
        BytesEqual((CONST UINT8 *)Table,mUsbHostSsdt,sizeof(mUsbHostSsdt))) ++Found;
  }
  return EFI_BAD_BUFFER_SIZE;
}

STATIC EFI_STATUS WindowsPrimaryHostReady(EFI_SYSTEM_TABLE *System, TIMELM_USB_CONFIG *Owner)
{
  EFI_BOOT_SERVICES *Bs=System->BootServices;
  EFI_HANDLE *Handles=NULL;
  TIMELM_USB_CONFIG *Config=NULL;
  EFI_USB2_HC_PROTOCOL *Hc=NULL;
  UINTN Count=0;
  UINT8 Speed=0, Ports=0, Address64=0;
  EFI_USB_HC_STATE State=EfiUsbHcStateHalt;
  EFI_STATUS Status;
  Status=Bs->LocateHandleBuffer(ByProtocol,&mUsbHostGuid,NULL,&Count,&Handles);
  if (EFI_ERROR(Status)) goto Done;
  if (!Handles || Count!=1) { Status=EFI_UNSUPPORTED; goto Done; }
  Status=Bs->HandleProtocol(Handles[0],&mUsbConfigGuid,(VOID **)&Config);
  if (EFI_ERROR(Status)) goto Done;
  // Match all callable methods to the already verified owner, not just revision.
  if (!Config || Config->Revision!=0x10005 || Config->CoreNum!=0 || Config->ModeType!=1 ||
      Config->GetCoreBaseAddr!=Owner->GetCoreBaseAddr || Config->GetUsbHostConfig!=Owner->GetUsbHostConfig ||
      Config->StartController!=Owner->StartController || Config->StopController!=Owner->StopController ||
      Config->GetCoreCount!=Owner->GetCoreCount || Config->GetSupportedMode!=Owner->GetSupportedMode) {
    Status=EFI_UNSUPPORTED; goto Done;
  }
  Status=Bs->HandleProtocol(Handles[0],&mUsbHostGuid,(VOID **)&Hc);
  if (EFI_ERROR(Status)) goto Done;
  if (!Hc || !Hc->GetState || !Hc->GetCapability) { Status=EFI_UNSUPPORTED; goto Done; }
  Status=Hc->GetState(Hc,&State);
  Text("Windows host state status="); Hex(Status); Text(" state="); Hex(State); Text("\r\n");
  if (EFI_ERROR(Status)) goto Done;
  if (State!=EfiUsbHcStateOperational) { Status=EFI_NOT_READY; goto Done; }
  Status=Hc->GetCapability(Hc,&Speed,&Ports,&Address64);
  Text("Windows host capabilities status="); Hex(Status); Text(" speed="); Hex(Speed);
  Text(" ports="); Hex(Ports); Text(" address64="); Hex(Address64); Text("\r\n");
  if (!EFI_ERROR(Status) && (Speed!=3 || Ports!=2 || Address64!=1)) Status=EFI_UNSUPPORTED;
Done:
  if (Handles) Bs->FreePool(Handles);
  return Status;
}

// The caller has restored both original EFI files. On a successful Windows
// handoff this function does not return. Returned paths remove only our SSDT,
// tear down attempted host state, and let the caller shut down without Windows.
STATIC EFI_STATUS ExecuteUsbWindowsTrial(EFI_HANDLE Image, EFI_SYSTEM_TABLE *System,
  TIMELM_USB_CONFIG *Config, BOOLEAN VerifiedOwner, EFI_ACPI_TABLE_PROTOCOL *Acpi,
  EFI_ACPI_SDT_PROTOCOL *Sdt, EFI_STATUS (*Checkpoint)(EFI_HANDLE))
{
  EFI_STATUS Status, Cleanup;
  BOOLEAN Attempted=FALSE, Installed=FALSE;
  UINTN Key=0;
  if (!Acpi || !Acpi->InstallAcpiTable || !Acpi->UninstallAcpiTable ||
      !Sdt || !Sdt->GetAcpiTable || !Checkpoint) return EFI_UNSUPPORTED;
  if (!AcpiChecksum(mUsbHostSsdt,sizeof(mUsbHostSsdt))) return EFI_COMPROMISED_DATA;
  Status=CheckWindowsNamespace(Sdt);
  Text("Known minimal timelm ACPI namespace status="); Hex(Status); Text("\r\n");
  if (EFI_ERROR(Status)) return Status;
  Status=StartPrimaryUsbHost(Image,System,Config,VerifiedOwner,Checkpoint,&Attempted);
  if (EFI_ERROR(Status)) goto Done;
  (VOID)System->BootServices->Stall(3000000);
  UsbConfigSnapshot(System,"windows-host-started");
  QueryUsb(System);
  Status=WindowsPrimaryHostReady(System,Config);
  if (EFI_ERROR(Status)) goto Done;
  Status=Acpi->InstallAcpiTable(Acpi,(VOID *)mUsbHostSsdt,sizeof(mUsbHostSsdt),&Key);
  Text("Install one-boot xHCI SSDT status="); Hex(Status); Text("\r\n");
  if (EFI_ERROR(Status)) goto Done;
  Installed=TRUE;
  Status=VerifyWindowsSsdt(Sdt);
  Text("Installed xHCI SSDT readback status="); Hex(Status); Text("\r\n");
  if (EFI_ERROR(Status)) goto Done;
  Text("Starting restored Windows with transient ACPI xHCI node.\r\n");
  Text("Native ExitBootServices cleanup still applies; OS USB handoff is experimental.\r\n");
  Status=Checkpoint(Image);
  if (EFI_ERROR(Status)) goto Done;
  Status=StartWindows(Image);
  Text("Windows returned to USB trial status="); Hex(Status); Text("\r\n");
  if (!EFI_ERROR(Status)) Status=EFI_ABORTED;
Done:
  if (Installed) {
    Cleanup=Acpi->UninstallAcpiTable(Acpi,Key);
    Text("Uninstall one-boot xHCI SSDT status="); Hex(Cleanup); Text("\r\n");
    if (EFI_ERROR(Cleanup)) Status=Cleanup;
  }
  if (Attempted) {
    Cleanup=CleanupPrimaryUsbHost(System,Config);
    if (EFI_ERROR(Cleanup)) Status=Cleanup;
  }
  return Status;
}

STATIC EFI_STATUS RunUsbWindowsTrial(EFI_HANDLE Image, EFI_SYSTEM_TABLE *System)
{
  EFI_ACPI_TABLE_PROTOCOL *Acpi=NULL;
  EFI_ACPI_SDT_PROTOCOL *Sdt=NULL;
  TIMELM_USB_CONFIG *Config=NULL;
  EFI_BOOT_SERVICES *Bs=System->BootServices;
  EFI_STATUS Status;
  Text("timelm one-boot Windows USB ACPI trial v1\r\n");
  if (!Bs->LocateProtocol || !Bs->LocateHandleBuffer || !Bs->HandleProtocol ||
      !Bs->FreePool || !Bs->Stall || !Bs->SetWatchdogTimer) return EFI_UNSUPPORTED;
  Status=Bs->SetWatchdogTimer(0,0,0,NULL);
  if (EFI_ERROR(Status)) return Status;
  Status=Bs->LocateProtocol(&mAcpiTableGuid,NULL,(VOID **)&Acpi);
  Text("Locate ACPI table protocol="); Hex(Status); Text("\r\n");
  if (EFI_ERROR(Status)) return Status;
  Status=Bs->LocateProtocol(&mAcpiSdtGuid,NULL,(VOID **)&Sdt);
  Text("Locate ACPI SDT protocol="); Hex(Status); Text("\r\n");
  if (EFI_ERROR(Status)) return Status;
  Status=Bs->LocateProtocol(&mUsbConfigGuid,NULL,(VOID **)&Config);
  if (EFI_ERROR(Status)) return Status;
  if (!Config || Config->Revision!=0x10005) return EFI_UNSUPPORTED;
  UsbOverrideSnapshot(System);
  return ExecuteUsbWindowsTrial(Image,System,Config,KnownUsbOwner(System,Config),Acpi,Sdt,SaveLog);
}
