// SPDX-License-Identifier: BSD-2-Clause-Patent
#include <assert.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#undef NULL
#define TIMELM_USB_HOST_PROBE
#include "../I2cClockDiag.c"

STATIC EFI_BOOT_SERVICES mBs;
STATIC EFI_SIMPLE_TEXT_OUTPUT_PROTOCOL mConsole;
STATIC EFI_SYSTEM_TABLE mTable;
STATIC TIMELM_USB_CONFIG mConfig;
STATIC int mCheckpoint, mStarts, mStops, mRestores, mStalls, mHostOn, mAlloc, mFreed;
STATIC int mScenario;
STATIC EFI_STATUS EFIAPI Print(EFI_SIMPLE_TEXT_OUTPUT_PROTOCOL *This, CHAR16 *S)
{ (VOID)This; (VOID)S; return EFI_SUCCESS; }
STATIC EFI_STATUS EFIAPI LocateHandles(EFI_LOCATE_SEARCH_TYPE Type, EFI_GUID *Guid,
 VOID *Key, UINTN *Count, EFI_HANDLE **Handles)
{
  (VOID)Type; (VOID)Key;
  *Count=0; *Handles=NULL;
  if (memcmp(Guid,&mUsbHostGuid,sizeof(*Guid))!=0) return EFI_NOT_FOUND;
  if (mScenario==15 || (mScenario==16 && mRestores)) return EFI_DEVICE_ERROR;
  if (!mHostOn) return EFI_NOT_FOUND;
  *Count=1; *Handles=malloc(sizeof(**Handles)); assert(*Handles); ++mAlloc;
  **Handles=(EFI_HANDLE)1; return EFI_SUCCESS;
}
STATIC EFI_STATUS EFIAPI Handle(EFI_HANDLE H, EFI_GUID *G, VOID **P)
{ (VOID)H; (VOID)G; *P=NULL; return EFI_NOT_FOUND; }
STATIC EFI_STATUS EFIAPI Free(VOID *P) { free(P); ++mFreed; return EFI_SUCCESS; }
STATIC EFI_STATUS EFIAPI Stall(UINTN Us) { assert(Us==3000000); ++mStalls; return EFI_SUCCESS; }
STATIC EFI_STATUS Checkpoint(EFI_HANDLE Image)
{ (VOID)Image; ++mCheckpoint; return mScenario==10 ? EFI_VOLUME_FULL : EFI_SUCCESS; }
STATIC EFI_STATUS EFIAPI Cores(TIMELM_USB_CONFIG *C, UINT8 *Count)
{ assert(C==&mConfig); *Count=mScenario==2 ? 0 : 2; return mScenario==1 ? EFI_DEVICE_ERROR : EFI_SUCCESS; }
STATIC EFI_STATUS EFIAPI Supported(TIMELM_USB_CONFIG *C, UINT32 Core, UINT32 *Mode)
{ assert(C==&mConfig && Core==0); *Mode=mScenario==4 ? 4 : 0x18; return mScenario==3 ? EFI_DEVICE_ERROR : EFI_SUCCESS; }
STATIC EFI_STATUS EFIAPI HostConfig(TIMELM_USB_CONFIG *C, UINT32 Mode, UINT32 Core, UINT32 *Type)
{ assert(C==&mConfig && Mode==1 && Core==0); *Type=mScenario==6 ? 6 : 5; return mScenario==5 ? EFI_DEVICE_ERROR : EFI_SUCCESS; }
STATIC EFI_STATUS EFIAPI Base(TIMELM_USB_CONFIG *C, UINT32 Type, UINTN *Address)
{ assert(C==&mConfig && Type==5); *Address=mScenario==8 ? 0xa800000 : 0xa600000; return mScenario==7 ? EFI_DEVICE_ERROR : EFI_SUCCESS; }
STATIC EFI_STATUS EFIAPI Start(TIMELM_USB_CONFIG *C, UINT32 Core, UINT32 Mode)
{
  assert(C==&mConfig && Core==0 && mCheckpoint==1);
  if (Mode==1) {
    ++mStarts;
    if (mScenario==11) return EFI_DEVICE_ERROR;
    mHostOn=mScenario==17 ? 0 : 1;
  } else {
    assert(Mode==4 && mStops==1); ++mRestores;
    if (mScenario==13) return EFI_DEVICE_ERROR;
    mHostOn=mScenario==14;
  }
  return EFI_SUCCESS;
}
STATIC EFI_STATUS EFIAPI Stop(TIMELM_USB_CONFIG *C, UINT32 Core, UINT32 Mode)
{
  int WasOn=mHostOn;
  assert(C==&mConfig && Core==0 && Mode==1 && mStarts==1); ++mStops;
  if (mScenario==12) return EFI_DEVICE_ERROR;
  mHostOn=0; return WasOn ? EFI_SUCCESS : EFI_NOT_STARTED;
}
STATIC VOID Setup(VOID)
{
  memset(&mBs,0,sizeof(mBs)); memset(&mTable,0,sizeof(mTable)); memset(&mConfig,0,sizeof(mConfig));
  mCheckpoint=mStarts=mStops=mRestores=mStalls=mHostOn=mAlloc=mFreed=0; mLogLength=0;
  mBs.LocateHandleBuffer=LocateHandles; mBs.HandleProtocol=Handle; mBs.FreePool=Free; mBs.Stall=Stall;
  mConsole.OutputString=Print; mTable.ConOut=&mConsole; mTable.BootServices=&mBs; mSystem=&mTable;
  mConfig.Revision=0x10005; mConfig.CoreNum=0; mConfig.ModeType=4;
  mConfig.GetCoreCount=Cores; mConfig.GetSupportedMode=Supported; mConfig.GetUsbHostConfig=HostConfig;
  mConfig.GetCoreBaseAddr=Base; mConfig.StartController=Start; mConfig.StopController=Stop;
}
STATIC VOID TestOwner(VOID)
{
  UINT8 *Image=calloc(1,0x17000); UINTN I;
  assert(Image);
  for (I=0; I<6; ++I) memcpy(Image+mUsbMethodRvas[I],mUsbMethodCode[I],16);
  mConfig.GetCoreBaseAddr=(USB_CORE_BASE)(Image+0x141c);
  mConfig.GetUsbHostConfig=(USB_HOST_CONFIG)(Image+0x14d0);
  mConfig.StartController=(USB_CONTROLLER)(Image+0x14ec);
  mConfig.StopController=(USB_CONTROLLER)(Image+0x1534);
  mConfig.GetCoreCount=(USB_CORE_COUNT)(Image+0x15dc);
  mConfig.GetSupportedMode=(USB_SUPPORTED)(Image+0x1650);
  assert(UsbOwnerMatches(&mConfig,Image,0x17000));
  assert(!UsbOwnerMatches(&mConfig,Image,0x16000));
  assert(!UsbOwnerMatches(&mConfig,(VOID *)((UINTN)-1-8),0x17000));
  Image[0x1650]^=1; assert(!UsbOwnerMatches(&mConfig,Image,0x17000)); Image[0x1650]^=1;
  mConfig.StartController=(USB_CONTROLLER)(Image+0x14f0); assert(!UsbOwnerMatches(&mConfig,Image,0x17000));
  free(Image);
}

STATIC int mTopology, mTopologyReads;
STATIC EFI_STATUS EFIAPI TopologyLocate(EFI_LOCATE_SEARCH_TYPE Type, EFI_GUID *Guid,
 VOID *Key, UINTN *Count, EFI_HANDLE **Handles)
{
  UINTN I;
  (VOID)Type; (VOID)Key;
  *Count=memcmp(Guid,&mUsbConfigGuid,sizeof(*Guid))==0 && mTopology==2 ? 10 : 1;
  *Handles=malloc(*Count * sizeof(**Handles)); assert(*Handles); ++mAlloc;
  for (I=0; I<*Count; ++I) (*Handles)[I]=(EFI_HANDLE)1;
  return mTopology==3 ? EFI_DEVICE_ERROR : EFI_SUCCESS;
}
STATIC EFI_STATUS EFIAPI TopologyHandle(EFI_HANDLE H, EFI_GUID *Guid, VOID **P)
{
  (VOID)H; *P=NULL;
  if (memcmp(Guid,&mUsbConfigGuid,sizeof(*Guid))) return EFI_NOT_FOUND;
  ++mTopologyReads;
  if (mTopology==4) return EFI_DEVICE_ERROR;
  *P=&mConfig; return EFI_SUCCESS;
}
STATIC EFI_STATUS EFIAPI TopologyOpens(EFI_HANDLE H, EFI_GUID *Guid,
 EFI_OPEN_PROTOCOL_INFORMATION_ENTRY **Entries, UINTN *Count)
{
  UINTN I;
  (VOID)H; assert(!memcmp(Guid,&mUsbConfigGuid,sizeof(*Guid)));
  *Count=mTopology==2 ? 40 : 1;
  *Entries=calloc(*Count,sizeof(**Entries)); assert(*Entries); ++mAlloc;
  for (I=0; I<*Count; ++I)
    (*Entries)[I].Attributes=EFI_OPEN_PROTOCOL_BY_DRIVER | EFI_OPEN_PROTOCOL_BY_CHILD_CONTROLLER;
  return mTopology==4 ? EFI_DEVICE_ERROR : EFI_SUCCESS;
}
STATIC VOID TestTopology(VOID)
{
  for (mTopology=0; mTopology<5; ++mTopology) {
    Setup(); mTopologyReads=0;
    mBs.LocateHandleBuffer=TopologyLocate; mBs.HandleProtocol=TopologyHandle;
    mBs.OpenProtocolInformation=TopologyOpens;
    if (mTopology==1) mConfig.Revision=0x10004;
    UsbConfigSnapshot(&mTable,"test");
    assert(mAlloc==mFreed && !mStarts && !mStops && !mRestores);
    assert(mTopologyReads==(mTopology==3 ? 0 : mTopology==2 ? 8 : 1));
    assert(mLogLength<sizeof(mLog)); mLog[mLogLength]=0;
    assert(strstr(mLog,"USB config snapshot phase=test"));
    if (mTopology==0) assert(strstr(mLog,"core=0x0000000000000000 mode=0x0000000000000004"));
    if (mTopology==1) assert(!strstr(mLog," core="));
    if (mTopology==2) {
      assert(strstr(mLog,"drivers=0x0000000000000020 children=0x0000000000000020"));
      assert(strstr(mLog,"QCOM instances limited to first 8"));
    }
  }
  Setup(); mBs.OpenProtocolInformation=NULL;
  mBs.LocateHandleBuffer=TopologyLocate; mBs.HandleProtocol=TopologyHandle;
  UsbConfigSnapshot(&mTable,"no-open-info"); assert(mAlloc==mFreed && !mStarts);
}

STATIC int mBusScenario, mConnects;
STATIC EFI_LOADED_IMAGE_PROTOCOL mBusLoaded;
STATIC EFI_STATUS EFIAPI BusLocate(EFI_LOCATE_SEARCH_TYPE Type, EFI_GUID *Guid,
 VOID *Key, UINTN *Count, EFI_HANDLE **Handles)
{
  UINTN I;
  (VOID)Type; (VOID)Key;
  assert(!memcmp(Guid,&mUsbHostGuid,sizeof(*Guid)) || !memcmp(Guid,&mLoadedImageGuid,sizeof(*Guid)));
  *Count=mBusScenario==1 && !memcmp(Guid,&mUsbHostGuid,sizeof(*Guid)) ? 2 : 1;
  *Handles=malloc(*Count * sizeof(**Handles)); assert(*Handles); ++mAlloc;
  for (I=0; I<*Count; ++I) (*Handles)[I]=(EFI_HANDLE)1;
  return mBusScenario==15 ? EFI_DEVICE_ERROR : EFI_SUCCESS;
}
STATIC EFI_STATUS EFIAPI BusHandle(EFI_HANDLE H, EFI_GUID *Guid, VOID **P)
{
  STATIC EFI_GUID PciGuid=EFI_PCI_IO_PROTOCOL_GUID, PathGuid=EFI_DEVICE_PATH_PROTOCOL_GUID;
  assert(H==(EFI_HANDLE)1); *P=NULL;
  if (!memcmp(Guid,&mUsbConfigGuid,sizeof(*Guid))) { *P=&mConfig; return EFI_SUCCESS; }
  if (!memcmp(Guid,&mLoadedImageGuid,sizeof(*Guid))) { *P=&mBusLoaded; return EFI_SUCCESS; }
  if (!memcmp(Guid,&PciGuid,sizeof(*Guid))) {
    if (mBusScenario==6) return EFI_UNSUPPORTED;
  } else {
    assert(!memcmp(Guid,&PathGuid,sizeof(*Guid)));
    if (mBusScenario==7) return EFI_UNSUPPORTED;
  }
  *P=(VOID *)1; return EFI_SUCCESS;
}
STATIC EFI_STATUS EFIAPI BusOpens(EFI_HANDLE H, EFI_GUID *Guid,
 EFI_OPEN_PROTOCOL_INFORMATION_ENTRY **Entries, UINTN *Count)
{
  assert(H==(EFI_HANDLE)1 && !memcmp(Guid,&mUsbHostGuid,sizeof(*Guid)));
  *Count=mBusScenario==10 ? 33 : 1; *Entries=NULL;
  if (mBusScenario==11) return EFI_SUCCESS;
  *Entries=calloc(*Count,sizeof(**Entries)); assert(*Entries); ++mAlloc;
  (*Entries)[0].Attributes=mBusScenario==9 ? EFI_OPEN_PROTOCOL_BY_DRIVER : EFI_OPEN_PROTOCOL_BY_HANDLE_PROTOCOL;
  return mBusScenario==8 ? EFI_DEVICE_ERROR : EFI_SUCCESS;
}
STATIC EFI_STATUS EFIAPI BusConnect(EFI_HANDLE H, EFI_HANDLE *Drivers,
 EFI_DEVICE_PATH_PROTOCOL *Path, BOOLEAN Recursive)
{
  assert(H==(EFI_HANDLE)1 && Drivers==NULL && Path==NULL && Recursive);
  ++mConnects; return mBusScenario==14 ? EFI_DEVICE_ERROR : EFI_SUCCESS;
}
STATIC VOID TestBusConnect(VOID)
{
  UINT8 *Image=calloc(1,0x17000); UINTN I;
  assert(Image);
  for (I=0; I<6; ++I) memcpy(Image+mUsbMethodRvas[I],mUsbMethodCode[I],16);
  for (mBusScenario=0; mBusScenario<16; ++mBusScenario) {
    Setup(); mConnects=0;
    mConfig.CoreNum=0; mConfig.ModeType=1;
    mConfig.GetCoreBaseAddr=(USB_CORE_BASE)(Image+0x141c);
    mConfig.GetUsbHostConfig=(USB_HOST_CONFIG)(Image+0x14d0);
    mConfig.StartController=(USB_CONTROLLER)(Image+0x14ec);
    mConfig.StopController=(USB_CONTROLLER)(Image+0x1534);
    mConfig.GetCoreCount=(USB_CORE_COUNT)(Image+0x15dc);
    mConfig.GetSupportedMode=(USB_SUPPORTED)(Image+0x1650);
    mBusLoaded.ImageBase=Image; mBusLoaded.ImageSize=0x17000;
    mBs.LocateHandleBuffer=BusLocate; mBs.HandleProtocol=BusHandle;
    mBs.OpenProtocolInformation=BusOpens; mBs.ConnectController=BusConnect;
    if (mBusScenario==2) mConfig.Revision=0x10004;
    if (mBusScenario==3) mConfig.CoreNum=1;
    if (mBusScenario==4) mConfig.ModeType=4;
    if (mBusScenario==5) mBusLoaded.ImageSize=0x16000;
    if (mBusScenario==12) mBs.OpenProtocolInformation=NULL;
    if (mBusScenario==13) mBs.ConnectController=NULL;
    ConnectPrimaryUsbBus(&mTable);
    assert(mConnects==(mBusScenario==0 || mBusScenario==14 ? 1 : 0));
    assert(mAlloc==mFreed && !mStarts && !mStops && !mRestores);
  }
  free(Image);
}
int main(void)
{
  EFI_STATUS Result;
  Setup(); TestOwner(); TestTopology(); TestBusConnect();
  Setup(); assert(ExercisePrimaryHost((EFI_HANDLE)1,&mTable,&mConfig,FALSE,Checkpoint)==EFI_SUCCESS); assert(!mStarts && !mCheckpoint);
  Setup(); mConfig.Revision=0x10004;
  assert(ExercisePrimaryHost((EFI_HANDLE)1,&mTable,&mConfig,TRUE,Checkpoint)==EFI_SUCCESS); assert(!mStarts);
  Setup(); mConfig.CoreNum=1;
  assert(ExercisePrimaryHost((EFI_HANDLE)1,&mTable,&mConfig,TRUE,Checkpoint)==EFI_SUCCESS); assert(!mStarts);
  Setup(); mConfig.ModeType=1;
  assert(ExercisePrimaryHost((EFI_HANDLE)1,&mTable,&mConfig,TRUE,Checkpoint)==EFI_SUCCESS); assert(!mStarts);
  Setup(); mConfig.CoreNum=2; mConfig.ModeType=0x10000;
  assert(ExercisePrimaryHost((EFI_HANDLE)1,&mTable,&mConfig,TRUE,Checkpoint)==EFI_SUCCESS);
  assert(mStarts==1 && mStops==1 && mRestores==1 && !mHostOn);
  Setup(); mConfig.CoreNum=2;
  assert(ExercisePrimaryHost((EFI_HANDLE)1,&mTable,&mConfig,TRUE,Checkpoint)==EFI_SUCCESS); assert(!mStarts);
  Setup(); mConfig.ModeType=0x10000;
  assert(ExercisePrimaryHost((EFI_HANDLE)1,&mTable,&mConfig,TRUE,Checkpoint)==EFI_SUCCESS); assert(!mStarts);
  Setup(); mHostOn=1;
  assert(ExercisePrimaryHost((EFI_HANDLE)1,&mTable,&mConfig,TRUE,Checkpoint)==EFI_SUCCESS); assert(!mStarts && mAlloc==mFreed);
  for (mScenario=0; mScenario<18; ++mScenario) {
    Setup(); if (mScenario==9) mHostOn=1;
    Result=ExercisePrimaryHost((EFI_HANDLE)1,&mTable,&mConfig,TRUE,Checkpoint);
    assert(mAlloc==mFreed);
    if (mScenario>=12 && mScenario<=14) assert(EFI_ERROR(Result));
    else if (mScenario==16) assert(EFI_ERROR(Result));
    else assert(Result==EFI_SUCCESS);
    if ((mScenario>=1 && mScenario<=10) || mScenario==15) assert(!mStarts && !mStops && !mRestores);
    else assert(mCheckpoint==1 && mStarts==1 && mStops==1 && mRestores==1);
  }
  puts("USB host probe: owner bytes/offsets, ABI/core/base gates, checkpoint, failures and teardown passed");
  return 0;
}
