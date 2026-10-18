// SPDX-License-Identifier: BSD-2-Clause-Patent
// Read-only UFS/SMMU snapshots v2 for timelm Windows 0x7B investigation.
// No storage controller, SMMU, ACPI, or Windows registry settings are changed.
#include <Uefi.h>
#include <Library/BaseLib.h>
#include <Library/BaseMemoryLib.h>
#include <Library/DebugLib.h>
#include <Library/IoLib.h>
#include <Library/MemoryAllocationLib.h>
#include <Library/MemoryMapHelperLib.h>
#include <Library/PrintLib.h>
#include <Library/UefiBootServicesTableLib.h>
#include <Guid/EventGroup.h>
#include <Guid/FileInfo.h>
#include <Protocol/SimpleFileSystem.h>

STATIC EFI_EVENT mReadyEvent;
STATIC EFI_EVENT mExitEvent;
STATIC EFI_MEMORY_REGION_DESCRIPTOR mUfs;
STATIC EFI_MEMORY_REGION_DESCRIPTOR mSmmu;
STATIC CHAR8 mLog[8192];
STATIC UINTN mUsed;

#define TIMELM_UFS_HCI_BASE  0x01D84000ULL

STATIC VOID
LogLine (IN CONST CHAR8 *Format, ...)
{
  VA_LIST Args;
  CHAR8 Line[256];
  UINTN Length;
  VA_START (Args, Format);
  AsciiVSPrint (Line, sizeof (Line), Format, Args);
  VA_END (Args);
  Length = AsciiStrLen (Line);
  if (Length < sizeof (mLog) - mUsed) {
    CopyMem (&mLog[mUsed], Line, Length);
    mUsed += Length;
    mLog[mUsed] = 0;
  }
  DEBUG ((DEBUG_WARN, "%a", Line));
}

STATIC VOID
Snapshot (IN CONST CHAR8 *Stage)
{
  UINT32 Id0;
  UINT32 Id1;
  UINT32 Count;
  UINT32 Banks;
  UINTN PageSize;
  UINTN ContextBase;
  UINT32 Found = 0;

  LogLine ("[timelm-ufsdiag] v2 %a: HCI=%08lx, MMIO reads only\r\n", Stage, mUfs.Address);
  LogLine ("[timelm-ufsdiag] UFS CAP=%08x VER=%08x HCS=%08x HCE=%08x\r\n",
    MmioRead32 ((UINTN)mUfs.Address),
    MmioRead32 ((UINTN)mUfs.Address + 0x08),
    MmioRead32 ((UINTN)mUfs.Address + 0x30),
    MmioRead32 ((UINTN)mUfs.Address + 0x34));
  LogLine ("[timelm-ufsdiag] UTRLDBR=%08x UTMRLDBR=%08x IS=%08x IE=%08x\r\n",
    MmioRead32 ((UINTN)mUfs.Address + 0x58),
    MmioRead32 ((UINTN)mUfs.Address + 0x78),
    MmioRead32 ((UINTN)mUfs.Address + 0x20),
    MmioRead32 ((UINTN)mUfs.Address + 0x24));

  Id0 = MmioRead32 ((UINTN)mSmmu.Address + 0x20);
  Id1 = MmioRead32 ((UINTN)mSmmu.Address + 0x24);
  Count = Id0 & 0xFF;
  if (Count > 128) {
    Count = 128;
  }
  Banks = Id1 & 0xFF;
  PageSize = (Id1 & BIT31) ? 0x10000 : 0x1000;
  ContextBase = (UINTN)(1U << (((Id1 >> 28) & 7) + 1)) * PageSize;
  LogLine ("[timelm-ufsdiag] SMMU ID0=%08x ID1=%08x sCR0=%08x\r\n",
    Id0, Id1, MmioRead32 ((UINTN)mSmmu.Address));

  for (UINT32 Index = 0; Index < Count; Index++) {
    UINT32 Smr = MmioRead32 ((UINTN)mSmmu.Address + 0x800 + Index * 4);
    UINT32 Mask;
    UINT32 Id;
    UINT32 S2cr;
    UINT32 Bank;
    UINTN BankOffset;
    if ((Smr & BIT31) == 0) {
      continue;
    }
    Mask = (Smr >> 16) & 0x7FFF;
    Id = Smr & 0x7FFF;
    if (((0xE0 & ~Mask) != (Id & ~Mask)) &&
        ((0x4E0 & ~Mask) != (Id & ~Mask))) {
      continue;
    }
    Found++;
    S2cr = MmioRead32 ((UINTN)mSmmu.Address + 0xC00 + Index * 4);
    Bank = S2cr & 0xFF;
    LogLine ("[timelm-ufsdiag] SMR[%u]=%08x S2CR=%08x type=%u cb=%u\r\n",
      Index, Smr, S2cr, (S2cr >> 16) & 3, Bank);
    BankOffset = ContextBase + Bank * PageSize;
    if ((((S2cr >> 16) & 3) == 0) && (Bank < Banks) &&
        (BankOffset + 0x30 <= mSmmu.Length) &&
        (PageSize + Bank * 4 + 4 <= mSmmu.Length)) {
      LogLine ("[timelm-ufsdiag] CB%u SCTLR=%08x CBAR=%08x TTBR0=%016lx\r\n",
        Bank,
        MmioRead32 ((UINTN)mSmmu.Address + BankOffset),
        MmioRead32 ((UINTN)mSmmu.Address + PageSize + Bank * 4),
        MmioRead64 ((UINTN)mSmmu.Address + BankOffset + 0x20));
    }
  }
  LogLine ("[timelm-ufsdiag] matching UFS stream groups=%u\r\n", Found);
}

// Called only before OS handoff, never from ExitBootServices.
STATIC VOID
SaveReadyLog (VOID)
{
  EFI_HANDLE *Handles = NULL;
  UINTN Count = 0;
  EFI_STATUS Status;
  Status = gBS->LocateHandleBuffer (ByProtocol, &gEfiSimpleFileSystemProtocolGuid,
                                   NULL, &Count, &Handles);
  if (EFI_ERROR (Status)) {
    return;
  }
  for (UINTN Index = 0; Index < Count; Index++) {
    EFI_SIMPLE_FILE_SYSTEM_PROTOCOL *Fs;
    EFI_FILE_PROTOCOL *Root = NULL;
    EFI_FILE_PROTOCOL *Bcd = NULL;
    EFI_FILE_PROTOCOL *File = NULL;
    EFI_FILE_INFO *Info;
    UINTN InfoSize = 512;
    UINTN WriteSize = mUsed;
    Status = gBS->HandleProtocol (Handles[Index], &gEfiSimpleFileSystemProtocolGuid, (VOID **)&Fs);
    if (EFI_ERROR (Status)) {
      continue;
    }
    Status = Fs->OpenVolume (Fs, &Root);
    if (EFI_ERROR (Status)) {
      continue;
    }
    Status = Root->Open (Root, &Bcd, L"\\EFI\\Microsoft\\Boot\\BCD", EFI_FILE_MODE_READ, 0);
    if (EFI_ERROR (Status)) {
      Root->Close (Root);
      continue;
    }
    Bcd->Close (Bcd);
    Status = Root->Open (Root, &File, L"\\timelm-ufsdiag-v2.txt",
                        EFI_FILE_MODE_READ | EFI_FILE_MODE_WRITE | EFI_FILE_MODE_CREATE, 0);
    if (!EFI_ERROR (Status)) {
      Info = AllocateZeroPool (InfoSize);
      if (Info != NULL) {
        Status = File->GetInfo (File, &gEfiFileInfoGuid, &InfoSize, Info);
        if (!EFI_ERROR (Status)) {
          Info->FileSize = 0;
          Status = File->SetInfo (File, &gEfiFileInfoGuid, InfoSize, Info);
        }
        FreePool (Info);
      }
      File->SetPosition (File, 0);
      Status = File->Write (File, &WriteSize, mLog);
      File->Flush (File);
      File->Close (File);
      DEBUG ((DEBUG_WARN, "[timelm-ufsdiag] ESP log write: %r (%u bytes)\n", Status, WriteSize));
    }
    Root->Close (Root);
    break;
  }
  FreePool (Handles);
}

STATIC VOID EFIAPI
OnReadyToBoot (IN EFI_EVENT Event, IN VOID *Context)
{
  mUsed = 0;
  Snapshot ("ReadyToBoot");
  SaveReadyLog ();
}

STATIC VOID EFIAPI
OnExitBootServices (IN EFI_EVENT Event, IN VOID *Context)
{
  // No allocation, file access, or boot-services calls in this callback.
  Snapshot ("ExitBootServices");
}

EFI_STATUS EFIAPI
UfsDiagEntry (IN EFI_HANDLE ImageHandle, IN EFI_SYSTEM_TABLE *SystemTable)
{
  EFI_STATUS Status;
  UINT64 HciOffset;
  Status = LocateMemoryRegionByName ("UFS UFS REGS", &mUfs);
  if (EFI_ERROR (Status) || mUfs.Address > TIMELM_UFS_HCI_BASE) {
    return EFI_NOT_FOUND;
  }
  // The mapping begins at 0x01D80000; the DTB/ACPI HCI begins 0x4000 inside it.
  // Keep this adjustment local to the diagnostic descriptor, not the platform map.
  HciOffset = TIMELM_UFS_HCI_BASE - mUfs.Address;
  if (HciOffset >= mUfs.Length || mUfs.Length - HciOffset < 0x100) {
    return EFI_NOT_FOUND;
  }
  mUfs.Address = TIMELM_UFS_HCI_BASE;
  mUfs.Length -= HciOffset;
  Status = LocateMemoryRegionByName ("SMMU", &mSmmu);
  if (EFI_ERROR (Status) || mSmmu.Length < 0x1000) {
    return EFI_NOT_FOUND;
  }
  Status = gBS->CreateEventEx (EVT_NOTIFY_SIGNAL, TPL_CALLBACK, OnReadyToBoot, NULL,
                             &gEfiEventReadyToBootGuid, &mReadyEvent);
  if (EFI_ERROR (Status)) {
    return Status;
  }
  Status = gBS->CreateEventEx (EVT_NOTIFY_SIGNAL, TPL_NOTIFY, OnExitBootServices, NULL,
                             &gEfiEventExitBootServicesGuid, &mExitEvent);
  if (EFI_ERROR (Status)) {
    gBS->CloseEvent (mReadyEvent);
  }
  return Status;
}
