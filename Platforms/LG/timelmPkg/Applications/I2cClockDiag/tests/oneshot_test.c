// SPDX-License-Identifier: BSD-2-Clause-Patent
#include <assert.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <setjmp.h>
#undef NULL // Mu headers define their own firmware NULL spelling.
#define TIMELM_ONESHOT
#define TIMELM_WINDOWS_SIZE 64u
#define TIMELM_WINDOWS_CRC32 0x100ece8cu
#include "../I2cClockDiag.c"
#ifdef TIMELM_USB_HOST_PROBE
#define EXPECTED_QUERIES 2
#define EXPECTED_STARTS 0
#define EXPECTED_POWEROFFS 1
#else
#define EXPECTED_QUERIES 1
#define EXPECTED_STARTS 1
#define EXPECTED_POWEROFFS 0
#endif

typedef struct FILE_MOCK {
  EFI_FILE_PROTOCOL Api;
  CONST CHAR16 *Name;
  UINT8 Data[65536];
  UINTN Size, Position;
  int Index;
} FILE_MOCK;
STATIC FILE_MOCK mFiles[5];
STATIC EFI_BOOT_SERVICES mBs;
STATIC EFI_RUNTIME_SERVICES mRt;
STATIC EFI_SIMPLE_TEXT_OUTPUT_PROTOCOL mConsole;
STATIC EFI_SYSTEM_TABLE mTable;
STATIC EFI_LOADED_IMAGE_PROTOCOL mParent, mChild;
STATIC EFI_SIMPLE_FILE_SYSTEM_PROTOCOL mFs;
STATIC EFI_FILE_PROTOCOL mRoot;
STATIC EFI_DEVICE_PATH_PROTOCOL mVolumePath[2];
STATIC UINT8 mOriginal[64];
STATIC int mWrites, mQueries, mLoads, mStarts, mFailWrite, mShortWrite, mBadReadback;
STATIC int mUsbQueries;
STATIC int mPoweroffs;
STATIC jmp_buf mFirmwareEnd;
STATIC EFI_STATUS mShutdownStatus;
STATIC VOID EFIAPI Reset(EFI_RESET_TYPE Type, EFI_STATUS Status, UINTN Size, VOID *Data)
{
  assert(Type==EfiResetShutdown && Size==0 && Data==NULL);
  assert(!mLoads && !mStarts);
  ++mPoweroffs; mShutdownStatus=Status; longjmp(mFirmwareEnd,1);
}
STATIC EFI_STATUS RunEntry(VOID)
{
  if (setjmp(mFirmwareEnd)) return mShutdownStatus;
  return I2cClockDiagEntry((EFI_HANDLE)1,&mTable);
}

STATIC int SameGuid (CONST EFI_GUID *A, CONST EFI_GUID *B) { return memcmp(A, B, sizeof(*A)) == 0; }
STATIC int SameName (CONST CHAR16 *A, CONST CHAR16 *B)
{
  while (*A && *A == *B) { ++A; ++B; }
  return *A == *B;
}
STATIC EFI_STATUS EFIAPI Close (EFI_FILE_PROTOCOL *File) { (VOID)File; return EFI_SUCCESS; }
STATIC EFI_STATUS EFIAPI Open (EFI_FILE_PROTOCOL *Root, EFI_FILE_PROTOCOL **Result,
                              CHAR16 *Name, UINT64 Mode, UINT64 Attributes)
{
  UINTN I;
  (VOID)Root; (VOID)Mode; (VOID)Attributes;
  for (I = 0; I < 5; ++I) if (SameName(Name, mFiles[I].Name)) {
    *Result = &mFiles[I].Api; mFiles[I].Position = 0; return EFI_SUCCESS;
  }
  return EFI_NOT_FOUND;
}
STATIC EFI_STATUS EFIAPI Read (EFI_FILE_PROTOCOL *File, UINTN *Size, VOID *Buffer)
{
  FILE_MOCK *F = (FILE_MOCK *)File;
  if (*Size > F->Size - F->Position) *Size = F->Size - F->Position;
  memcpy(Buffer, F->Data + F->Position, *Size);
  if (mBadReadback && F->Index == 0 && F->Size == 64 && *Size) ((UINT8 *)Buffer)[0] ^= 1;
  F->Position += *Size;
  return EFI_SUCCESS;
}
STATIC EFI_STATUS EFIAPI Write (EFI_FILE_PROTOCOL *File, UINTN *Size, VOID *Buffer)
{
  FILE_MOCK *F = (FILE_MOCK *)File;
  if (F->Index < 2) {
    ++mWrites;
    if (mFailWrite) return EFI_WRITE_PROTECTED;
    if (mShortWrite) *Size /= 2;
  }
  assert(F->Position + *Size <= sizeof(F->Data));
  memcpy(F->Data + F->Position, Buffer, *Size);
  F->Position += *Size;
  if (F->Position > F->Size) F->Size = F->Position;
  return EFI_SUCCESS;
}
STATIC EFI_STATUS EFIAPI Position (EFI_FILE_PROTOCOL *File, UINT64 Offset)
{
  FILE_MOCK *F = (FILE_MOCK *)File;
  F->Position = Offset == (UINT64)-1 ? F->Size : (UINTN)Offset;
  return EFI_SUCCESS;
}
STATIC EFI_STATUS EFIAPI GetInfo (EFI_FILE_PROTOCOL *File, EFI_GUID *Guid, UINTN *Size, VOID *Buffer)
{
  FILE_MOCK *F = (FILE_MOCK *)File;
  EFI_FILE_INFO *Info = Buffer;
  assert(SameGuid(Guid, &mInfoGuid)); assert(*Size >= sizeof(*Info));
  memset(Buffer, 0, *Size); Info->Size = *Size; Info->FileSize = F->Size;
  return EFI_SUCCESS;
}
STATIC EFI_STATUS EFIAPI SetInfo (EFI_FILE_PROTOCOL *File, EFI_GUID *Guid, UINTN Size, VOID *Buffer)
{
  FILE_MOCK *F = (FILE_MOCK *)File;
  (VOID)Guid; (VOID)Size; F->Size = (UINTN)((EFI_FILE_INFO *)Buffer)->FileSize;
  return EFI_SUCCESS;
}
STATIC EFI_STATUS EFIAPI OpenVolume (EFI_SIMPLE_FILE_SYSTEM_PROTOCOL *Fs, EFI_FILE_PROTOCOL **Root)
{ (VOID)Fs; *Root = &mRoot; return EFI_SUCCESS; }
STATIC EFI_STATUS EFIAPI Print (EFI_SIMPLE_TEXT_OUTPUT_PROTOCOL *Console, CHAR16 *String)
{ (VOID)Console; (VOID)String; return EFI_SUCCESS; }
STATIC EFI_STATUS EFIAPI Handle (EFI_HANDLE H, EFI_GUID *Guid, VOID **Interface)
{
  if (SameGuid(Guid, &mLoadedImageGuid)) {
    *Interface = H == (EFI_HANDLE)1 ? &mParent : &mChild; return EFI_SUCCESS;
  }
  if (SameGuid(Guid, &mFileSystemGuid)) { *Interface = &mFs; return EFI_SUCCESS; }
  if (SameGuid(Guid, &mPathGuid)) { *Interface = &mVolumePath; return EFI_SUCCESS; }
  return EFI_NOT_FOUND;
}
STATIC EFI_STATUS EFIAPI Locate (EFI_GUID *Guid, VOID *Registration, VOID **Interface)
{
  (VOID)Guid; (VOID)Registration; (VOID)Interface;
  assert(memcmp(mFiles[0].Data, mOriginal, 64) == 0);
  assert(memcmp(mFiles[1].Data, mOriginal, 64) == 0);
  ++mQueries; return EFI_NOT_FOUND;
}
STATIC EFI_STATUS EFIAPI LocateHandles (EFI_LOCATE_SEARCH_TYPE Type, EFI_GUID *Guid,
                                       VOID *Key, UINTN *Count, EFI_HANDLE **Handles)
{
  (VOID)Type; (VOID)Guid; (VOID)Key;
  assert(memcmp(mFiles[0].Data, mOriginal, 64) == 0);
  assert(memcmp(mFiles[1].Data, mOriginal, 64) == 0);
  ++mUsbQueries; *Count = 0; *Handles = NULL; return EFI_NOT_FOUND;
}
STATIC EFI_STATUS EFIAPI Allocate (EFI_MEMORY_TYPE Type, UINTN Size, VOID **Buffer)
{ (VOID)Type; *Buffer = malloc(Size); return *Buffer ? EFI_SUCCESS : EFI_OUT_OF_RESOURCES; }
STATIC EFI_STATUS EFIAPI Free (VOID *Buffer) { free(Buffer); return EFI_SUCCESS; }
STATIC VOID EFIAPI Copy (VOID *D, VOID *S, UINTN Size) { memcpy(D, S, Size); }
STATIC EFI_STATUS EFIAPI Crc (VOID *Buffer, UINTN Size, UINT32 *Result)
{
  UINT32 Value = 0xffffffffu;
  UINTN I, J;
  for (I = 0; I < Size; ++I) {
    Value ^= ((UINT8 *)Buffer)[I];
    for (J = 0; J < 8; ++J) Value = (Value >> 1) ^ (0xedb88320u & (0u - (Value & 1u)));
  }
  *Result = ~Value; return EFI_SUCCESS;
}
STATIC EFI_STATUS EFIAPI Load (BOOLEAN Policy, EFI_HANDLE Parent, EFI_DEVICE_PATH_PROTOCOL *Path,
                              VOID *Buffer, UINTN Size, EFI_HANDLE *Image)
{
  EFI_DEVICE_PATH_PROTOCOL *Node = (EFI_DEVICE_PATH_PROTOCOL *)((UINT8 *)Path + 4);
  (VOID)Parent; assert(!Policy && !Buffer && Size == 0);
  assert(Node->Type == MEDIA_DEVICE_PATH && Node->SubType == MEDIA_FILEPATH_DP);
  assert(SameName((CHAR16 *)(Node + 1), mTargets[0]));
  ++mLoads; *Image = (EFI_HANDLE)2; return EFI_SUCCESS;
}
STATIC EFI_STATUS EFIAPI Start (EFI_HANDLE Image, UINTN *Size, CHAR16 **Data)
{
  (VOID)Image; (VOID)Size; (VOID)Data;
  assert(mChild.LoadOptions == mParent.LoadOptions);
  assert(mChild.LoadOptionsSize == mParent.LoadOptionsSize);
  ++mStarts; return EFI_SUCCESS;
}
STATIC EFI_STATUS EFIAPI Unload (EFI_HANDLE Image) { (VOID)Image; return EFI_SUCCESS; }
STATIC VOID Setup (VOID)
{
  UINTN I;
  memset(mFiles, 0, sizeof(mFiles)); memset(&mBs, 0, sizeof(mBs));
  memset(&mTable, 0, sizeof(mTable)); memset(&mParent, 0, sizeof(mParent));
  memset(&mChild, 0, sizeof(mChild));
  mWrites = mQueries = mLoads = mStarts = mFailWrite = mShortWrite = mBadReadback = 0;
  mUsbQueries = 0;
  mPoweroffs = 0; mShutdownStatus=EFI_SUCCESS;
  memset(&mRt,0,sizeof(mRt)); mRt.ResetSystem=Reset;
  for (I = 0; I < 64; ++I) mOriginal[I] = (UINT8)I;
  for (I = 0; I < 5; ++I) {
    mFiles[I].Api.Close = Close; mFiles[I].Api.Read = Read; mFiles[I].Api.Write = Write;
    mFiles[I].Api.SetPosition = Position; mFiles[I].Api.GetInfo = GetInfo;
    mFiles[I].Api.SetInfo = SetInfo; mFiles[I].Api.Flush = Close;
    mFiles[I].Index = (int)I;
    mFiles[I].Name = I < 2 ? mTargets[I] : I < 4 ? mBackups[I - 2] : mLogName;
    if (I < 2) { memcpy(mFiles[I].Data, "launcher", 8); mFiles[I].Size = 8; }
    else if (I < 4) { memcpy(mFiles[I].Data, mOriginal, 64); mFiles[I].Size = 64; }
  }
  mRoot.Open = Open; mRoot.Close = Close; mFs.OpenVolume = OpenVolume;
  mParent.DeviceHandle = (EFI_HANDLE)3;
  mParent.LoadOptions = (VOID *)L"options"; mParent.LoadOptionsSize = 16;
  mConsole.OutputString = Print; mTable.ConOut = &mConsole; mTable.BootServices = &mBs;
  mTable.RuntimeServices=&mRt;
  mBs.HandleProtocol = Handle; mBs.LocateProtocol = Locate;
  mBs.LocateHandleBuffer = LocateHandles;
  mBs.AllocatePool = Allocate; mBs.FreePool = Free; mBs.CopyMem = Copy;
  mBs.CalculateCrc32 = Crc; mBs.LoadImage = Load; mBs.StartImage = Start; mBs.UnloadImage = Unload;
  mVolumePath[0].Type = MEDIA_DEVICE_PATH; mVolumePath[0].SubType = MEDIA_HARDDRIVE_DP;
  mVolumePath[0].Length[0] = 4; mVolumePath[0].Length[1] = 0;
  mVolumePath[1].Type = END_DEVICE_PATH_TYPE; mVolumePath[1].SubType = END_ENTIRE_DEVICE_PATH_SUBTYPE;
  mVolumePath[1].Length[0] = 4; mVolumePath[1].Length[1] = 0;
}
int main(void)
{
  Setup(); assert(RunEntry() == EFI_SUCCESS);
  assert(mWrites == 2 && mQueries == EXPECTED_QUERIES && mLoads == EXPECTED_STARTS && mStarts == EXPECTED_STARTS);
  assert(mPoweroffs == EXPECTED_POWEROFFS);
  assert(mUsbQueries == 2);
  assert(mFiles[0].Size == 64 && mFiles[1].Size == 64);
  Setup(); mFiles[3].Data[0] ^= 1;
  assert(EFI_ERROR(RunEntry()));
  assert(!mWrites && !mQueries && !mUsbQueries && !mLoads);
  Setup(); mFailWrite = 1;
  assert(RunEntry() == EFI_WRITE_PROTECTED);
  assert(!mQueries && !mUsbQueries && !mLoads);
  Setup(); mShortWrite = 1;
  assert(RunEntry() == EFI_VOLUME_FULL);
  assert(!mQueries && !mUsbQueries && !mLoads);
  Setup(); mBadReadback = 1;
  assert(RunEntry() == EFI_COMPROMISED_DATA);
  assert(!mQueries && !mUsbQueries && !mLoads);
  Setup(); memcpy(mFiles[0].Data, mOriginal, 64); mFiles[0].Size = 64;
  memcpy(mFiles[1].Data, mOriginal, 64); mFiles[1].Size = 64;
  assert(RunEntry() == EFI_SUCCESS);
  assert(!mWrites && mQueries == EXPECTED_QUERIES && mStarts == EXPECTED_STARTS);
  assert(mPoweroffs == EXPECTED_POWEROFFS);
  puts("One-shot UEFI: restore ordering, failures, default chainload / USB firmware-only shutdown passed");
  return 0;
}
