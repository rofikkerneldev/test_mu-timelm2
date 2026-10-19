// SPDX-License-Identifier: BSD-2-Clause-Patent
// Standalone UEFI application: clock queries only, no direct MMIO or clock writes.
#include <Uefi.h>
#include <Protocol/EFIClock.h>
#include <Protocol/LoadedImage.h>
#include <Protocol/SimpleFileSystem.h>

STATIC EFI_SYSTEM_TABLE *mSystem;
STATIC EFI_GUID mClockGuid = EFI_CLOCK_PROTOCOL_GUID;
STATIC EFI_GUID mLoadedImageGuid = EFI_LOADED_IMAGE_PROTOCOL_GUID;
STATIC EFI_GUID mFileSystemGuid = EFI_SIMPLE_FILE_SYSTEM_PROTOCOL_GUID;
STATIC CHAR8 mLog[8192];
STATIC UINTN mLogLength;
STATIC CONST CHAR8 *mNames[] = {
  "gcc_qupv3_wrap1_s5_clk",
  "gcc_qupv3_wrap1_s5_clk_src",
  "gcc_qupv3_wrap_1_m_ahb_clk",
  "gcc_qupv3_wrap_1_s_ahb_clk",
  // Some XBL clock databases omit the underscore before the wrapper number.
  "gcc_qupv3_wrap1_m_ahb_clk",
  "gcc_qupv3_wrap1_s_ahb_clk"
};

STATIC VOID Text (CONST CHAR8 *Ascii)
{
  CHAR16 Buffer[96];
  UINTN Index;
  while (*Ascii) {
    for (Index = 0; Index < 95 && *Ascii; ++Index) {
      if (mLogLength < sizeof (mLog)) mLog[mLogLength++] = *Ascii;
      Buffer[Index] = (CHAR16)*Ascii++;
    }
    Buffer[Index] = 0;
    mSystem->ConOut->OutputString (mSystem->ConOut, Buffer);
  }
}
STATIC VOID Hex (UINT64 Value)
{
  CHAR8 Buffer[19];
  UINTN Index;
  CONST CHAR8 *Digits = "0123456789abcdef";
  Buffer[0] = '0'; Buffer[1] = 'x'; Buffer[18] = 0;
  for (Index = 0; Index < 16; ++Index) {
    Buffer[17 - Index] = Digits[Value & 15];
    Value >>= 4;
  }
  Text (Buffer);
}

STATIC EFI_STATUS QueryClocks (EFI_SYSTEM_TABLE *System)
{
  EFI_CLOCK_PROTOCOL *Clock = NULL;
  EFI_STATUS Status;
  UINTN Index;
  Text ("timelm I2C clock query v1\r\nNo direct MMIO, enable, disable, rate change or reset.\r\n");
  Status = System->BootServices->LocateProtocol (&mClockGuid, NULL, (VOID **)&Clock);
  Text ("Locate EFI_CLOCK_PROTOCOL: "); Hex (Status); Text ("\r\n");
  if (EFI_ERROR (Status)) return Status;
  if (Clock == NULL) return EFI_NOT_FOUND;
  Text ("Protocol version: "); Hex (Clock->Version); Text ("\r\n");
  if (Clock->Version < EFI_CLOCK_PROTOCOL_VERSION) {
    Text ("Older ABI: queries skipped. Validate the matching header first.\r\n");
    return EFI_UNSUPPORTED;
  }
  if (!Clock->GetClockID || !Clock->IsClockEnabled || !Clock->IsClockOn || !Clock->GetClockFreqHz)
    return EFI_UNSUPPORTED;
  for (Index = 0; Index < sizeof (mNames) / sizeof (mNames[0]); ++Index) {
    UINTN Id = 0;
    UINT32 Hz = 0;
    BOOLEAN Enabled = FALSE, On = FALSE;
    EFI_STATUS EnabledStatus, OnStatus, HzStatus;
    Text (mNames[Index]); Text ("\r\n  GetID=");
    Status = Clock->GetClockID (Clock, mNames[Index], &Id);
    Hex (Status);
    if (EFI_ERROR (Status)) { Text ("\r\n"); continue; }
    Text (" id="); Hex (Id);
    EnabledStatus = Clock->IsClockEnabled (Clock, Id, &Enabled);
    OnStatus = Clock->IsClockOn (Clock, Id, &On);
    HzStatus = Clock->GetClockFreqHz (Clock, Id, &Hz);
    Text ("\r\n  Enabled(status,value)="); Hex (EnabledStatus); Text (","); Hex (Enabled);
    Text ("\r\n  On(status,value)="); Hex (OnStatus); Text (","); Hex (On);
    Text ("\r\n  Frequency(status,Hz)="); Hex (HzStatus); Text (","); Hex (Hz);
    Text ("\r\n");
  }
  Text ("Configured frequency alone does not prove clocks are on or retained at ExitBootServices.\r\n");
  Text ("Do not enable the Windows handoff gate from this snapshot alone.\r\n");
  return EFI_SUCCESS;
}

STATIC EFI_STATUS SaveLog (EFI_HANDLE Image)
{
  EFI_LOADED_IMAGE_PROTOCOL *Loaded = NULL;
  EFI_SIMPLE_FILE_SYSTEM_PROTOCOL *FileSystem = NULL;
  EFI_FILE_PROTOCOL *Root = NULL, *File = NULL;
  EFI_STATUS Status;
  UINTN Size = mLogLength;
  Status = mSystem->BootServices->HandleProtocol (Image, &mLoadedImageGuid, (VOID **)&Loaded);
  if (EFI_ERROR (Status)) return Status;
  if (Loaded == NULL) return EFI_NOT_FOUND;
  Status = mSystem->BootServices->HandleProtocol (Loaded->DeviceHandle, &mFileSystemGuid, (VOID **)&FileSystem);
  if (EFI_ERROR (Status)) return Status;
  if (FileSystem == NULL) return EFI_NOT_FOUND;
  Status = FileSystem->OpenVolume (FileSystem, &Root);
  if (EFI_ERROR (Status)) return Status;
  Status = Root->Open (Root, &File, L"timelm-i2c-clockdiag.txt",
    EFI_FILE_MODE_READ | EFI_FILE_MODE_WRITE | EFI_FILE_MODE_CREATE, 0);
  Root->Close (Root);
  if (EFI_ERROR (Status)) return Status;
  // Append only: previous diagnostic captures remain intact.
  Status = File->SetPosition (File, (UINT64)-1);
  if (!EFI_ERROR (Status)) {
    Status = File->Write (File, &Size, mLog);
    if (!EFI_ERROR (Status) && Size != mLogLength) Status = EFI_VOLUME_FULL;
  }
  if (!EFI_ERROR (Status)) Status = File->Flush (File);
  File->Close (File);
  return Status;
}

EFI_STATUS EFIAPI I2cClockDiagEntry (EFI_HANDLE Image, EFI_SYSTEM_TABLE *System)
{
  EFI_STATUS Result, LogStatus;
  if (System == NULL || System->ConOut == NULL || System->BootServices == NULL)
    return EFI_UNSUPPORTED;
  mSystem = System;
  mLogLength = 0;
  Result = QueryClocks (System);
  LogStatus = SaveLog (Image);
  Text ("Append timelm-i2c-clockdiag.txt on application's filesystem: ");
  Hex (LogStatus); Text ("\r\n");
  return EFI_ERROR (Result) ? Result : LogStatus;
}
