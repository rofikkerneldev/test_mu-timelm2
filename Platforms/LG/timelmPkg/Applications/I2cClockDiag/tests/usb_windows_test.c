// SPDX-License-Identifier: BSD-2-Clause-Patent
#define TIMELM_USB_HOST_PROBE
#define TIMELM_USB_WINDOWS
#define main UnusedDiagnosticTestMain
#include "oneshot_test.c"
#undef main

STATIC EFI_ACPI_TABLE_PROTOCOL mAcpi;
STATIC EFI_ACPI_SDT_PROTOCOL mSdt;
STATIC EFI_USB2_HC_PROTOCOL mHc;
STATIC TIMELM_USB_CONFIG mProto, mLive;
STATIC UINT8 mDsdt[sizeof(mTimelmDsdt)], mSsdt[sizeof(mUsbHostSsdt)];
STATIC int mCase, mNativeStarts, mNativeStops, mNativeRestores, mActive;
STATIC int mInstalled, mInstalls, mUninstalls, mCheckpoints;
STATIC int mStageFlushes, mUnloads;
STATIC jmp_buf mHandoff;

STATIC EFI_STATUS EFIAPI WinCores(TIMELM_USB_CONFIG *C, UINT8 *Count)
{ assert(C==&mProto); *Count=2; return EFI_SUCCESS; }
STATIC EFI_STATUS EFIAPI WinSupported(TIMELM_USB_CONFIG *C, UINT32 Core, UINT32 *Mode)
{ assert(C==&mProto && Core==0); *Mode=0x18; return EFI_SUCCESS; }
STATIC EFI_STATUS EFIAPI WinHost(TIMELM_USB_CONFIG *C, UINT32 Mode, UINT32 Core, UINT32 *Type)
{ assert(C==&mProto && Mode==1 && Core==0); *Type=5; return EFI_SUCCESS; }
STATIC EFI_STATUS EFIAPI WinBase(TIMELM_USB_CONFIG *C, UINT32 Type, UINTN *Base)
{ assert(C==&mProto && Type==5); *Base=0xa600000; return EFI_SUCCESS; }
STATIC EFI_STATUS EFIAPI WinNativeStart(TIMELM_USB_CONFIG *C, UINT32 Core, UINT32 Mode)
{
  assert(C==&mProto && Core==0 && mCheckpoints>=1);
  assert(!memcmp(mFiles[0].Data,mOriginal,64) && !memcmp(mFiles[1].Data,mOriginal,64));
  if (Mode==1) {
    ++mNativeStarts; mActive=1; mLive=mProto; mLive.CoreNum=0; mLive.ModeType=1;
    if (mCase==13) mLive.CoreNum=1;
    if (mCase==14) mLive.ModeType=4;
    if (mCase==15) mLive.GetCoreCount=NULL;
    return mCase==11 ? EFI_DEVICE_ERROR : EFI_SUCCESS;
  }
  assert(Mode==4 && mNativeStops==1); ++mNativeRestores;
  if (mCase==28) mActive=1;
  return mCase==27 ? EFI_DEVICE_ERROR : EFI_SUCCESS;
}
STATIC EFI_STATUS EFIAPI WinNativeStop(TIMELM_USB_CONFIG *C, UINT32 Core, UINT32 Mode)
{
  assert(C==&mProto && Core==0 && Mode==1 && mNativeStarts==1);
  ++mNativeStops; mActive=0;
  return mCase==26 ? EFI_DEVICE_ERROR : EFI_SUCCESS;
}
STATIC EFI_STATUS EFIAPI WinLocate(EFI_LOCATE_SEARCH_TYPE Type, EFI_GUID *Guid,
 VOID *Key, UINTN *Count, EFI_HANDLE **Handles)
{
  (VOID)Type; (VOID)Key; *Count=0; *Handles=NULL;
  if (SameGuid(Guid,&mUsbHostGuid) && ((mActive && mCase!=12) || mCase==31)) *Count=1;
  if (SameGuid(Guid,&mUsbConfigGuid)) *Count=mActive ? 2 : 1;
  if (!*Count) return EFI_NOT_FOUND;
  *Handles=malloc(*Count*sizeof(**Handles)); assert(*Handles);
  (*Handles)[0]=SameGuid(Guid,&mUsbHostGuid) ? (EFI_HANDLE)101 : (EFI_HANDLE)100;
  if (*Count==2) (*Handles)[1]=(EFI_HANDLE)101;
  return EFI_SUCCESS;
}
STATIC EFI_STATUS EFIAPI WinHandle(EFI_HANDLE H, EFI_GUID *Guid, VOID **P)
{
  if (H!=(EFI_HANDLE)100 && H!=(EFI_HANDLE)101) return Handle(H,Guid,P);
  *P=NULL;
  if (SameGuid(Guid,&mUsbConfigGuid)) { *P=H==(EFI_HANDLE)100 ? &mProto : &mLive; return EFI_SUCCESS; }
  if (SameGuid(Guid,&mUsbHostGuid)) { *P=&mHc; return EFI_SUCCESS; }
  return EFI_NOT_FOUND;
}
STATIC EFI_STATUS EFIAPI WinState(EFI_USB2_HC_PROTOCOL *H, EFI_USB_HC_STATE *State)
{ assert(H==&mHc); *State=mCase==17 ? EfiUsbHcStateHalt : EfiUsbHcStateOperational; return mCase==16 ? EFI_DEVICE_ERROR : EFI_SUCCESS; }
STATIC EFI_STATUS EFIAPI WinCapability(EFI_USB2_HC_PROTOCOL *H, UINT8 *Speed, UINT8 *Ports, UINT8 *Address64)
{ assert(H==&mHc); *Speed=3; *Ports=mCase==19 ? 1 : 2; *Address64=1; return mCase==18 ? EFI_DEVICE_ERROR : EFI_SUCCESS; }
STATIC EFI_STATUS EFIAPI WinTable(UINTN Index, EFI_ACPI_SDT_HEADER **Table,
 EFI_ACPI_TABLE_VERSION *Version, UINTN *Key)
{
  *Version=EFI_ACPI_TABLE_VERSION_5_0; *Key=77;
  if (mCase==6 || (mCase==34 && mInstalled)) return EFI_DEVICE_ERROR;
  if (mCase==32) return EFI_NOT_FOUND;
  if (Index==0 || mCase==33) { *Table=(EFI_ACPI_SDT_HEADER *)mDsdt; return EFI_SUCCESS; }
  if (Index==1 && (mCase==5 || (mInstalled && mCase!=21))) {
    *Table=(EFI_ACPI_SDT_HEADER *)mSsdt; return EFI_SUCCESS;
  }
  return EFI_NOT_FOUND;
}
STATIC EFI_STATUS EFIAPI WinInstall(EFI_ACPI_TABLE_PROTOCOL *This, VOID *Data, UINTN Size, UINTN *Key)
{
  assert(This==&mAcpi && mNativeStarts==1 && !mNativeStops && mActive && !mInstalled);
  assert(Size==sizeof(mSsdt) && !memcmp(Data,mUsbHostSsdt,Size));
  ++mInstalls;
  if (mCase==20) return EFI_ACCESS_DENIED;
  memcpy(mSsdt,Data,Size); mInstalled=1; *Key=77; return EFI_SUCCESS;
}
STATIC EFI_STATUS EFIAPI WinUninstall(EFI_ACPI_TABLE_PROTOCOL *This, UINTN Key)
{
  assert(This==&mAcpi && Key==77 && mInstalled && !mNativeStops);
  ++mUninstalls;
  if (mCase==25) return EFI_DEVICE_ERROR;
  mInstalled=0; return EFI_SUCCESS;
}
STATIC EFI_STATUS WinCheckpoint(EFI_HANDLE Image)
{
  assert(Image==(EFI_HANDLE)1); ++mCheckpoints;
  if ((mCase==10 && mCheckpoints==1) || (mCase==22 && mCheckpoints==2)) return EFI_VOLUME_FULL;
  return SaveLog(Image);
}
STATIC EFI_STATUS EFIAPI WinStall(UINTN Us)
{ assert(Us==3000000); return EFI_SUCCESS; }
STATIC EFI_STATUS EFIAPI WinLoad(BOOLEAN Policy, EFI_HANDLE Parent, EFI_DEVICE_PATH_PROTOCOL *Path,
 VOID *Buffer, UINTN Size, EFI_HANDLE *Image)
{
  assert(mInstalled && mActive && mCheckpoints==2 && !mNativeStops);
  assert(strstr((char *)mFiles[4].Data,"Windows stage: BEFORE LoadImage"));
  assert(!strstr((char *)mFiles[4].Data,"Windows stage: AFTER LoadImage"));
  if (mCase==23) return EFI_LOAD_ERROR;
  return Load(Policy,Parent,Path,Buffer,Size,Image);
}
STATIC EFI_STATUS EFIAPI WinStart(EFI_HANDLE Image, UINTN *Size, CHAR16 **Data)
{
  EFI_STATUS Status=Start(Image,Size,Data);
  assert(mInstalled && mActive && !mNativeStops);
  assert(strstr((char *)mFiles[4].Data,"Windows stage: AFTER LoadImage status="));
  assert(strstr((char *)mFiles[4].Data,"Windows stage: BEFORE StartImage"));
  if (mCase==30) longjmp(mHandoff,1);
  return mCase==24 ? EFI_LOAD_ERROR : Status;
}
STATIC EFI_STATUS EFIAPI WinUnload(EFI_HANDLE Image)
{ ++mUnloads; return Unload(Image); }
STATIC EFI_STATUS EFIAPI WinLogFlush(EFI_FILE_PROTOCOL *File)
{
  assert(File==&mFiles[4].Api); ++mStageFlushes;
  if ((mCase==35 && mStageFlushes==3) || (mCase==36 && mStageFlushes==4) ||
      (mCase==37 && mStageFlushes==5)) return EFI_DEVICE_ERROR;
  return EFI_SUCCESS;
}
STATIC VOID FixChecksum(VOID)
{
  UINTN I; UINT8 Sum=0;
  mDsdt[9]=0; for (I=0; I<sizeof(mDsdt); ++I) Sum=(UINT8)(Sum+mDsdt[I]);
  mDsdt[9]=(UINT8)(0-Sum);
}
STATIC VOID WinSetup(VOID)
{
  UINTN I;
  Setup(); mSystem=&mTable; mLogLength=0;
  assert(RestoreWindows((EFI_HANDLE)1)==EFI_SUCCESS);
  mNativeStarts=mNativeStops=mNativeRestores=mActive=mInstalled=mInstalls=mUninstalls=mCheckpoints=0;
  mStageFlushes=mUnloads=0;
  mFiles[4].Api.Flush=WinLogFlush;
  mBs.HandleProtocol=WinHandle; mBs.LocateHandleBuffer=WinLocate;
  mBs.Stall=WinStall; mBs.LoadImage=WinLoad; mBs.StartImage=WinStart;
  mBs.UnloadImage=WinUnload;
  memset(&mProto,0,sizeof(mProto)); memset(&mHc,0,sizeof(mHc));
  mProto.Revision=0x10005; mProto.CoreNum=2; mProto.ModeType=0x10000;
  mProto.GetCoreCount=WinCores; mProto.GetSupportedMode=WinSupported; mProto.GetUsbHostConfig=WinHost;
  mProto.GetCoreBaseAddr=WinBase; mProto.StartController=WinNativeStart; mProto.StopController=WinNativeStop;
  mHc.GetState=WinState; mHc.GetCapability=WinCapability;
  mAcpi.InstallAcpiTable=WinInstall; mAcpi.UninstallAcpiTable=WinUninstall;
  mSdt.GetAcpiTable=WinTable;
  memcpy(mDsdt,mTimelmDsdt,sizeof(mDsdt)); memcpy(mSsdt,mUsbHostSsdt,sizeof(mSsdt));
  if (mCase==2) { mDsdt[sizeof(mDsdt)-1]^=1; FixChecksum(); }
  if (mCase==3) {
    for (I=10; I<sizeof(mDsdt) && !mTimelmDsdtMask[I]; ++I) {}
    assert(I<sizeof(mDsdt)); mDsdt[I]^=0x55; FixChecksum();
  }
  if (mCase==4) mDsdt[9]^=1;
  if (mCase==7) mAcpi.InstallAcpiTable=NULL;
  if (mCase==8) mAcpi.UninstallAcpiTable=NULL;
  if (mCase==9) mSdt.GetAcpiTable=NULL;
}
int main(void)
{
  EFI_STATUS Status;
  for (mCase=0; mCase<=37; ++mCase) {
    WinSetup();
    if (mCase==30 && setjmp(mHandoff)) {
      assert(mStarts==1 && mInstalled && mActive && !mNativeStops && !mUninstalls);
      continue;
    }
    Status=ExecuteUsbWindowsTrial((EFI_HANDLE)1,&mTable,&mProto,mCase!=1,&mAcpi,&mSdt,WinCheckpoint);
    assert(EFI_ERROR(Status)); // A returning Windows manager is not OS handoff.
    if (mCase==0 || mCase==3) assert(mStarts==1 && mInstalls==1 && mUninstalls==1 && Status==EFI_ABORTED);
    else assert(!mStarts || mCase==24 || mCase==25 || mCase==26 || mCase==27 || mCase==28 || mCase==29);
    if (mNativeStarts) assert(mNativeStops==1 && mNativeRestores==1);
    if (mInstalls && mCase!=20) assert(mUninstalls==1);
    if (mCase!=25) assert(!mInstalled);
    if (mCase!=28) assert(!mActive);
    if (mCase==35) assert(!mLoads && !mStarts && !mUnloads);
    if (mCase==36 || mCase==37) assert(mLoads==1 && !mStarts && mUnloads==1);
  }
  // Entry-point restore failures never reach clock/USB/ACPI discovery.
  Setup(); mFiles[3].Data[0]^=1;
  assert(EFI_ERROR(RunEntry())); assert(!mWrites && !mQueries && !mUsbQueries && !mLoads);
  puts("Windows USB trial: namespace mask, native/host/ACPI gates, one-boot handoff and returned-path rollback passed");
  return 0;
}
