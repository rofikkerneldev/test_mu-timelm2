// SPDX-License-Identifier: BSD-2-Clause-Patent
#include <Protocol/AcpiTable.h>
#include <Protocol/AcpiSystemDescriptionTable.h>
#include <TouchEnumerationAcpi.h>

STATIC BOOLEAN TrialBytesEqual(CONST UINT8 *A, CONST UINT8 *B, UINTN N)
{ UINTN I; for (I=0; I<N; ++I) if (A[I]!=B[I]) return FALSE; return TRUE; }
STATIC BOOLEAN TrialChecksum(CONST UINT8 *Data, UINTN N)
{ UINT8 Sum=0; UINTN I; for (I=0; I<N; ++I) Sum=(UINT8)(Sum+Data[I]); return Sum==0; }

STATIC BOOLEAN TrialKnownDsdt(CONST UINT8 *Data, UINTN N)
{
  UINTN I;
  if (!Data || N!=sizeof(mTimelmDsdt) || !TrialChecksum(Data,N)) return FALSE;
  for (I=0; I<N; ++I)
    if (!mTimelmDsdtMask[I] && Data[I]!=mTimelmDsdt[I]) return FALSE;
  return TRUE;
}
// Reject pre-existing SSDTs and IORTs, including an IORT whose devices are off.
STATIC EFI_STATUS TrialTables(EFI_ACPI_SDT_PROTOCOL *Sdt, BOOLEAN Installed)
{
  UINTN I, Dsdts=0, Ssdts=0;
  for (I=0; I<64; ++I) {
    EFI_ACPI_SDT_HEADER *T=NULL;
    EFI_ACPI_TABLE_VERSION V=0;
    UINTN Key=0;
    EFI_STATUS S=Sdt->GetAcpiTable(I,&T,&V,&Key);
    if (S==EFI_NOT_FOUND) return Dsdts==1 && Ssdts==(Installed ? 1u : 0u) ? EFI_SUCCESS : EFI_NOT_FOUND;
    if (EFI_ERROR(S)) return S;
    if (!T || T->Length<sizeof(*T) || T->Length>65536) return EFI_COMPROMISED_DATA;
    if (T->Signature==SIGNATURE_32('I','O','R','T')) return EFI_ACCESS_DENIED;
    if (T->Signature==SIGNATURE_32('D','S','D','T')) {
      ++Dsdts;
      if (!TrialKnownDsdt((CONST UINT8 *)T,T->Length)) return EFI_COMPROMISED_DATA;
    }
    if (T->Signature==SIGNATURE_32('S','S','D','T')) {
      ++Ssdts;
      if (!Installed || T->Length!=sizeof(mTouchSsdt) ||
          !TrialBytesEqual((CONST UINT8 *)T,mTouchSsdt,sizeof(mTouchSsdt))) return EFI_ACCESS_DENIED;
    }
  }
  return EFI_BAD_BUFFER_SIZE;
}

// Caller restores Windows first. No hardware protocol, MMIO or IORT operation.
// A non-returning OS handoff keeps this memory-only SSDT for this boot alone.
STATIC EFI_STATUS ExecuteTouchEnumeration(EFI_HANDLE Image,
  EFI_ACPI_TABLE_PROTOCOL *Acpi, EFI_ACPI_SDT_PROTOCOL *Sdt,
  EFI_STATUS (*Checkpoint)(EFI_HANDLE), EFI_STATUS (*Chainload)(EFI_HANDLE))
{
  EFI_STATUS Status, Cleanup;
  UINTN Key=0;
  if (!Acpi || !Acpi->InstallAcpiTable || !Acpi->UninstallAcpiTable ||
      !Sdt || !Sdt->GetAcpiTable || !Checkpoint || !Chainload) return EFI_UNSUPPORTED;
  if (!TrialChecksum(mTouchSsdt,sizeof(mTouchSsdt))) return EFI_COMPROMISED_DATA;
  Status=TrialTables(Sdt,FALSE);
  Text("Enumeration namespace gate="); Hex(Status); Text("\r\n");
  if (EFI_ERROR(Status)) return Status;
  Status=Checkpoint(Image);
  if (EFI_ERROR(Status)) return Status;
  Status=Acpi->InstallAcpiTable(Acpi,(VOID *)mTouchSsdt,sizeof(mTouchSsdt),&Key);
  Text("Install enumeration SSDT="); Hex(Status); Text("\r\n");
  if (EFI_ERROR(Status)) return Status;
  Status=TrialTables(Sdt,TRUE);
  Text("Enumeration table readback="); Hex(Status); Text("\r\n");
  if (!EFI_ERROR(Status)) Status=Checkpoint(Image);
  if (!EFI_ERROR(Status)) {
    Status=Chainload(Image);
    if (!EFI_ERROR(Status)) Status=EFI_ABORTED;
  }
  Cleanup=Acpi->UninstallAcpiTable(Acpi,Key);
  Text("Remove trial SSDT on returned path="); Hex(Cleanup); Text("\r\n");
  return EFI_ERROR(Cleanup) ? Cleanup : Status;
}
