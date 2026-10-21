// SPDX-License-Identifier: BSD-2-Clause-Patent
// Restore-first one-boot ACPI enumeration. No IORT or hardware access.
#include <Uefi.h>
#include <Protocol/LoadedImage.h>
#include <Protocol/SimpleFileSystem.h>
#define TIMELM_CHAINLOAD_TRACE
STATIC EFI_STATUS SaveLog(EFI_HANDLE Image);

STATIC EFI_SYSTEM_TABLE *mSystem;
STATIC EFI_GUID mLoadedImageGuid = EFI_LOADED_IMAGE_PROTOCOL_GUID;
STATIC EFI_GUID mFileSystemGuid = EFI_SIMPLE_FILE_SYSTEM_PROTOCOL_GUID;
STATIC CHAR8 mLog[32768];
STATIC UINTN mLogLength;

STATIC VOID Text(CONST CHAR8 *Ascii)
{
  CHAR16 Buffer[96];
  UINTN I;
  while (*Ascii) {
    for (I = 0; I < 95 && *Ascii; ++I) {
      if (mLogLength < sizeof(mLog)) mLog[mLogLength++] = *Ascii;
      Buffer[I] = (CHAR16)*Ascii++;
    }
    Buffer[I] = 0;
    (VOID)mSystem->ConOut->OutputString(mSystem->ConOut,Buffer);
  }
}
STATIC VOID Hex(UINT64 Value)
{
  CHAR8 Buffer[19];
  UINTN I;
  CONST CHAR8 *Digits = "0123456789abcdef";
  Buffer[0]='0'; Buffer[1]='x'; Buffer[18]=0;
  for (I=0; I<16; ++I) { Buffer[17-I]=Digits[Value&15]; Value>>=4; }
  Text(Buffer);
}
#include "../I2cClockDiag/OneShot.h"

STATIC EFI_STATUS SaveLog(EFI_HANDLE Image)
{
  EFI_FILE_PROTOCOL *Root = NULL, *File = NULL;
  EFI_HANDLE Device;
  EFI_STATUS Status;
  UINTN Size = mLogLength;
  Status = OpenRoot(Image,&Root,&Device);
  if (EFI_ERROR(Status)) return Status;
  Status = Root->Open(Root,&File,L"\\timelm-touch-enumeration.txt",
    EFI_FILE_MODE_READ|EFI_FILE_MODE_WRITE|EFI_FILE_MODE_CREATE,0);
  Root->Close(Root);
  if (EFI_ERROR(Status)) return Status;
  Status = File->SetPosition(File,(UINT64)-1);
  if (!EFI_ERROR(Status)) Status = File->Write(File,&Size,mLog);
  if (!EFI_ERROR(Status) && Size != mLogLength) Status = EFI_VOLUME_FULL;
  if (!EFI_ERROR(Status)) Status = File->Flush(File);
  File->Close(File);
  if (!EFI_ERROR(Status)) mLogLength = 0; // Each checkpoint is appended once.
  return Status;
}
#include "Trial.h"
EFI_STATUS EFIAPI TouchEnumerationEntry(EFI_HANDLE Image, EFI_SYSTEM_TABLE *System)
{
  EFI_STATUS Status;
  EFI_ACPI_TABLE_PROTOCOL *Acpi=NULL;
  EFI_ACPI_SDT_PROTOCOL *Sdt=NULL;
  EFI_GUID AcpiGuid=EFI_ACPI_TABLE_PROTOCOL_GUID;
  EFI_GUID SdtGuid=EFI_ACPI_SDT_PROTOCOL_GUID;
  if (!System || !System->ConOut || !System->BootServices || !System->RuntimeServices)
    return EFI_UNSUPPORTED;
  mSystem=System;
  Text("timelm touch enumeration trial v1\r\nRestore original Windows FIRST.\r\n");
  Status=RestoreWindows(Image);
  Text("Restore status="); Hex(Status); Text("\r\n");
  if (EFI_ERROR(Status)) { (VOID)SaveLog(Image); return Status; }
  Status=System->BootServices->SetWatchdogTimer(0,0,0,NULL);
  if (EFI_ERROR(Status)) goto Done;
  Text("Enumeration only. No IORT, SMMU, GPI, clock, GPIO or touch request.\r\n");
  Status=SaveLog(Image);
  if (EFI_ERROR(Status)) goto Done;
  Status=System->BootServices->LocateProtocol(&AcpiGuid,NULL,(VOID **)&Acpi);
  if (EFI_ERROR(Status)) goto Done;
  Status=System->BootServices->LocateProtocol(&SdtGuid,NULL,(VOID **)&Sdt);
  if (EFI_ERROR(Status)) goto Done;
  Status=ExecuteTouchEnumeration(Image,Acpi,Sdt,SaveLog,StartWindows);
Done:
  Text("Trial returned; shutdown. Original Windows restored for next boot. Status=");
  Hex(Status); Text("\r\n");
  (VOID)SaveLog(Image);
  System->RuntimeServices->ResetSystem(EfiResetShutdown,Status,0,NULL);
  return Status;
}
