// SPDX-License-Identifier: BSD-2-Clause-Patent
#include <assert.h>
#include <stdio.h>
#include <string.h>
#include <setjmp.h>
#undef NULL
#include <Uefi.h>
STATIC VOID Text(CONST CHAR8 *S) { (VOID)S; }
STATIC VOID Hex(UINT64 V) { (VOID)V; }
#include "Trial.h"

static EFI_ACPI_TABLE_PROTOCOL acpi;
static EFI_ACPI_SDT_PROTOCOL sdt;
static UINT8 dsdt[sizeof(mTimelmDsdt)], ssdt[sizeof(mTouchSsdt)];
static EFI_ACPI_SDT_HEADER extra;
static int scenario, installed, installs, uninstalls, checkpoints, boots;
static jmp_buf handoff;

static EFI_STATUS EFIAPI get(UINTN I, EFI_ACPI_SDT_HEADER **T,
  EFI_ACPI_TABLE_VERSION *V, UINTN *K)
{
  *V=0; *K=99;
  if (scenario==3) return EFI_NOT_FOUND;
  if (scenario==4) return EFI_DEVICE_ERROR;
  if (I==0 || scenario==5) { *T=(VOID *)dsdt; return EFI_SUCCESS; }
  if (I==1 && (scenario==6 || scenario==7)) { *T=&extra; return EFI_SUCCESS; }
  if (I==1 && scenario==8) { *T=(VOID *)dsdt; return EFI_SUCCESS; }
  if (I==1 && scenario==9) { *T=NULL; return EFI_SUCCESS; }
  if (I==1 && installed && scenario!=11) {
    *T=(VOID *)ssdt;
    if (scenario==12) ssdt[40]^=1;
    return EFI_SUCCESS;
  }
  return EFI_NOT_FOUND;
}
static EFI_STATUS EFIAPI install(EFI_ACPI_TABLE_PROTOCOL *A, VOID *D, UINTN N, UINTN *K)
{
  assert(A==&acpi && !installed && checkpoints==1);
  assert(N==sizeof(ssdt) && !memcmp(D,mTouchSsdt,N));
  ++installs;
  if (scenario==10) return EFI_DEVICE_ERROR;
  memcpy(ssdt,D,N); installed=1; *K=99; return EFI_SUCCESS;
}
static EFI_STATUS EFIAPI uninstall(EFI_ACPI_TABLE_PROTOCOL *A, UINTN K)
{
  assert(A==&acpi && installed && K==99);
  ++uninstalls;
  if (scenario==16) return EFI_DEVICE_ERROR;
  installed=0; return EFI_SUCCESS;
}
static EFI_STATUS checkpoint(EFI_HANDLE H)
{
  assert(H==(EFI_HANDLE)1); ++checkpoints;
  return (scenario==13 || (scenario==14 && checkpoints==2)) ? EFI_VOLUME_FULL : EFI_SUCCESS;
}
static EFI_STATUS boot(EFI_HANDLE H)
{
  assert(H==(EFI_HANDLE)1 && installed && checkpoints==2);
  ++boots;
  if (scenario==17) longjmp(handoff,1);
  return scenario==15 ? EFI_LOAD_ERROR : EFI_SUCCESS;
}
int main(void)
{
  for (scenario=0; scenario<=19; ++scenario) {
    EFI_STATUS status;
    memcpy(dsdt,mTimelmDsdt,sizeof(dsdt));
    memset(ssdt,0,sizeof(ssdt)); memset(&extra,0,sizeof(extra));
    extra.Length=sizeof(extra);
    extra.Signature=scenario==6 ? SIGNATURE_32('I','O','R','T') : SIGNATURE_32('S','S','D','T');
    if (scenario==1) dsdt[0]^=1;
    if (scenario==2) { dsdt[8]^=1; dsdt[9]-=1; }
    if (scenario==18) {
      UINTN I; UINT8 sum=0;
      for (I=10; I<sizeof(dsdt); ++I) if (mTimelmDsdtMask[I]) { dsdt[I]^=1; break; }
      dsdt[9]=0; for (I=0; I<sizeof(dsdt); ++I) sum=(UINT8)(sum+dsdt[I]); dsdt[9]=(UINT8)(0-sum);
    }
    acpi.InstallAcpiTable=install; acpi.UninstallAcpiTable=uninstall;
    sdt.GetAcpiTable=get;
    if (scenario==19) acpi.UninstallAcpiTable=NULL;
    installed=installs=uninstalls=checkpoints=boots=0;
    if (setjmp(handoff)) { assert(scenario==17 && installed && boots==1 && !uninstalls); continue; }
    status=ExecuteTouchEnumeration((EFI_HANDLE)1,&acpi,&sdt,checkpoint,boot);
    assert(EFI_ERROR(status));
    if (scenario==0 || scenario==15 || scenario==16 || scenario==18) assert(boots==1);
    else assert(!boots);
    if (installs && scenario!=10) assert(uninstalls==1);
    else assert(!uninstalls);
    assert(!installed || scenario==16);
  }
  puts("Touch enumeration: namespace, no-IORT, rollback, checkpoint and one-boot handoff tests passed");
  return 0;
}
