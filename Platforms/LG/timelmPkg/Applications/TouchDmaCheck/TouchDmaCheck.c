// SPDX-License-Identifier: BSD-2-Clause-Patent
// Restore-first, read-only DMA prerequisite check. No USB/GENI/GPI requests.
#include <Uefi.h>
#include <Protocol/LoadedImage.h>
#include <Protocol/SimpleFileSystem.h>
#include "Snapshot.h"

STATIC EFI_SYSTEM_TABLE *mSystem;
STATIC EFI_GUID mLoadedImageGuid = EFI_LOADED_IMAGE_PROTOCOL_GUID;
STATIC EFI_GUID mFileSystemGuid = EFI_SIMPLE_FILE_SYSTEM_PROTOCOL_GUID;
STATIC CHAR8 mLog[32768];
STATIC UINTN mLogLength;
STATIC TD_SNAPSHOT mSnapshot;

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
  Status = Root->Open(Root,&File,L"\\timelm-touch-dma-check.txt",
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
STATIC TD_U32 ReadSmmu(void *Context, TD_U32 Offset)
{
  volatile UINT32 *Address = (volatile UINT32 *)(UINTN)(0x15000000u+Offset);
  TD_U32 Value;
  (VOID)Context;
  __asm__ __volatile__("dsb sy" ::: "memory");
  Value = *Address;
  __asm__ __volatile__("dsb sy" ::: "memory");
  return Value;
}
EFI_STATUS EFIAPI TouchDmaCheckEntry(EFI_HANDLE Image, EFI_SYSTEM_TABLE *System)
{
  EFI_STATUS Status;
  TD_U32 I;
  if (!System || !System->ConOut || !System->BootServices) return EFI_UNSUPPORTED;
  mSystem = System;
  Text("timelm touch DMA prerequisite check v1\r\nRestore original Windows entries FIRST.\r\n");
  Status = RestoreWindows(Image);
  Text("Restore status="); Hex(Status); Text("\r\n");
  if (EFI_ERROR(Status)) { (VOID)SaveLog(Image); return Status; }
  Text("CHECKPOINT: no USB, clock, touch, GPI or SMMU write. Only global SMMU page reads.\r\n");
  Status = SaveLog(Image);
  if (!EFI_ERROR(Status)) {
    int Known = TouchDmaSnapshot(NULL,ReadSmmu,&mSnapshot);
    Text("SMMU ID0="); Hex(mSnapshot.Id0); Text(" ID1="); Hex(mSnapshot.Id1);
    Text(" control="); Hex(mSnapshot.Control); Text(" known_layout="); Hex(Known);
    Text("\r\n");
    for (I=0; I<mSnapshot.Valid; ++I) {
      Text("SMR index="); Hex(mSnapshot.Entries[I].Index);
      Text(" value="); Hex(mSnapshot.Entries[I].Smr);
      Text(" S2CR="); Hex(mSnapshot.Entries[I].S2cr); Text("\r\n");
    }
    Text("SID 0x56 matches="); Hex(mSnapshot.Matches);
    Text(" conflicting_type="); Hex(mSnapshot.Conflict);
    Text(" unmatched_default_fault="); Hex(mSnapshot.DefaultFault);
    Text(" verified_bypass="); Hex(mSnapshot.Bypass); Text("\r\n");
    Text("This is a pre-Windows snapshot. The Windows adapter must recheck before DMA.\r\n");
    (VOID)SaveLog(Image);
  }
  Text("Start restored Windows; no touch driver or ACPI change by this app.\r\n");
  (VOID)SaveLog(Image);
  return StartWindows(Image);
}
