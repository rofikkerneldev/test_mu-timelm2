// SPDX-License-Identifier: BSD-2-Clause-Patent
// Included only by the once-only launcher variant. No Windows bytes embedded.
#include <Guid/FileInfo.h>
#include <Protocol/DevicePath.h>

#if !defined(TIMELM_WINDOWS_SIZE) || !defined(TIMELM_WINDOWS_CRC32)
#error A verified Windows image size and CRC32 must be supplied by the build.
#endif

STATIC EFI_GUID mInfoGuid = EFI_FILE_INFO_ID;
STATIC EFI_GUID mPathGuid = EFI_DEVICE_PATH_PROTOCOL_GUID;
STATIC CONST CHAR16 *mTargets[2] = {
  L"\\EFI\\Microsoft\\Boot\\bootmgfw.efi",
  L"\\EFI\\Boot\\bootaa64.efi"
};
STATIC CONST CHAR16 *mBackups[2] = {
  L"\\EFI\\Microsoft\\Boot\\bootmgfw.timelm-i2c-original.efi",
  L"\\EFI\\Boot\\bootaa64.timelm-i2c-original.efi"
};

STATIC EFI_STATUS OpenRoot (EFI_HANDLE Image, EFI_FILE_PROTOCOL **Root, EFI_HANDLE *Device)
{
  EFI_LOADED_IMAGE_PROTOCOL *Loaded = NULL;
  EFI_SIMPLE_FILE_SYSTEM_PROTOCOL *Fs = NULL;
  EFI_STATUS Status;
  Status = mSystem->BootServices->HandleProtocol (Image, &mLoadedImageGuid, (VOID **)&Loaded);
  if (EFI_ERROR (Status)) return Status;
  if (Loaded == NULL) return EFI_NOT_FOUND;
  *Device = Loaded->DeviceHandle;
  Status = mSystem->BootServices->HandleProtocol (*Device, &mFileSystemGuid, (VOID **)&Fs);
  if (EFI_ERROR (Status)) return Status;
  if (Fs == NULL) return EFI_NOT_FOUND;
  return Fs->OpenVolume (Fs, Root);
}

// All image reads are bounded, including one extra byte to detect trailing data.
STATIC EFI_STATUS ReadOriginal (EFI_FILE_PROTOCOL *Root, CONST CHAR16 *Name, VOID *Buffer)
{
  EFI_FILE_PROTOCOL *File = NULL;
  UINTN Size = TIMELM_WINDOWS_SIZE + 1u;
  UINT32 Crc = 0;
  EFI_STATUS Status;
  Status = Root->Open (Root, &File, (CHAR16 *)Name, EFI_FILE_MODE_READ, 0);
  if (EFI_ERROR (Status)) return Status;
  Status = File->Read (File, &Size, Buffer);
  File->Close (File);
  if (EFI_ERROR (Status)) return Status;
  if (Size != TIMELM_WINDOWS_SIZE) return EFI_COMPROMISED_DATA;
  Status = mSystem->BootServices->CalculateCrc32 (Buffer, Size, &Crc);
  if (EFI_ERROR (Status)) return Status;
  return Crc == TIMELM_WINDOWS_CRC32 ? EFI_SUCCESS : EFI_COMPROMISED_DATA;
}

STATIC BOOLEAN EqualOriginal (CONST UINT8 *A, CONST UINT8 *B)
{
  UINTN Index;
  for (Index = 0; Index < TIMELM_WINDOWS_SIZE; ++Index)
    if (A[Index] != B[Index]) return FALSE;
  return TRUE;
}

STATIC EFI_STATUS RestoreFile (EFI_FILE_PROTOCOL *Root, CONST CHAR16 *Name,
                              VOID *Original, VOID *Verify)
{
  EFI_FILE_PROTOCOL *File = NULL;
  EFI_STATUS Status;
  UINTN Size;
  union { EFI_FILE_INFO Info; UINT8 Bytes[512]; } Info;
  Status = ReadOriginal (Root, Name, Verify);
  if (!EFI_ERROR (Status) && EqualOriginal (Original, Verify)) return EFI_SUCCESS;
  if (EFI_ERROR (Status) && Status != EFI_COMPROMISED_DATA && Status != EFI_NOT_FOUND)
    return Status;
  Status = Root->Open (Root, &File, (CHAR16 *)Name,
    EFI_FILE_MODE_READ | EFI_FILE_MODE_WRITE | EFI_FILE_MODE_CREATE, 0);
  if (EFI_ERROR (Status)) return Status;
  Size = TIMELM_WINDOWS_SIZE;
  Status = File->Write (File, &Size, Original);
  if (!EFI_ERROR (Status) && Size != TIMELM_WINDOWS_SIZE) Status = EFI_VOLUME_FULL;
  if (!EFI_ERROR (Status)) {
    Size = sizeof (Info);
    Status = File->GetInfo (File, &mInfoGuid, &Size, &Info);
    if (!EFI_ERROR (Status) && Info.Info.FileSize != TIMELM_WINDOWS_SIZE) {
      Info.Info.FileSize = TIMELM_WINDOWS_SIZE;
      Status = File->SetInfo (File, &mInfoGuid, Size, &Info);
    }
  }
  if (!EFI_ERROR (Status)) Status = File->Flush (File);
  File->Close (File);
  if (EFI_ERROR (Status)) return Status;
  Status = ReadOriginal (Root, Name, Verify);
  if (EFI_ERROR (Status)) return Status;
  return EqualOriginal (Original, Verify) ? EFI_SUCCESS : EFI_COMPROMISED_DATA;
}

STATIC EFI_STATUS RestoreWindows (EFI_HANDLE Image)
{
  EFI_FILE_PROTOCOL *Root = NULL;
  EFI_HANDLE Device;
  VOID *Original = NULL, *Verify = NULL;
  EFI_STATUS Status;
  UINTN Index;
  Status = OpenRoot (Image, &Root, &Device);
  if (EFI_ERROR (Status)) return Status;
  Status = mSystem->BootServices->AllocatePool (EfiBootServicesData, TIMELM_WINDOWS_SIZE + 1u, &Original);
  if (EFI_ERROR (Status)) goto Done;
  Status = mSystem->BootServices->AllocatePool (EfiBootServicesData, TIMELM_WINDOWS_SIZE + 1u, &Verify);
  if (EFI_ERROR (Status)) goto Done;
  // Validate BOTH immutable backup files before modifying either boot entry.
  Status = ReadOriginal (Root, mBackups[0], Original);
  if (EFI_ERROR (Status)) goto Done;
  Status = ReadOriginal (Root, mBackups[1], Verify);
  if (EFI_ERROR (Status)) goto Done;
  if (!EqualOriginal (Original, Verify)) { Status = EFI_COMPROMISED_DATA; goto Done; }
  for (Index = 0; Index < 2; ++Index) {
    Status = RestoreFile (Root, mTargets[Index], Original, Verify);
    if (EFI_ERROR (Status)) goto Done;
  }
Done:
  if (Verify != NULL) mSystem->BootServices->FreePool (Verify);
  if (Original != NULL) mSystem->BootServices->FreePool (Original);
  Root->Close (Root);
  return Status;
}

STATIC EFI_STATUS StartWindows (EFI_HANDLE Image)
{
  EFI_LOADED_IMAGE_PROTOCOL *Parent = NULL, *Child = NULL;
  EFI_DEVICE_PATH_PROTOCOL *Base = NULL, *Node, *Path = NULL, *FileNode, *End;
  EFI_HANDLE Next = NULL;
  EFI_STATUS Status;
  UINTN Length, BaseLength = 0, FileLength, Total, ExitSize = 0;
  CHAR16 *ExitData = NULL;
  STATIC CONST CHAR16 Name[] = L"\\EFI\\Microsoft\\Boot\\bootmgfw.efi";
  Status = mSystem->BootServices->HandleProtocol (Image, &mLoadedImageGuid, (VOID **)&Parent);
  if (EFI_ERROR (Status)) return Status;
  if (Parent == NULL) return EFI_NOT_FOUND;
  Status = mSystem->BootServices->HandleProtocol (Parent->DeviceHandle, &mPathGuid, (VOID **)&Base);
  if (EFI_ERROR (Status)) return Status;
  if (Base == NULL) return EFI_NOT_FOUND;
  for (;;) {
    if (BaseLength + sizeof (*Node) > 4096) return EFI_COMPROMISED_DATA;
    Node = (EFI_DEVICE_PATH_PROTOCOL *)((UINT8 *)Base + BaseLength);
    Length = Node->Length[0] | ((UINTN)Node->Length[1] << 8);
    if (Length < sizeof (*Node) || BaseLength + Length > 4096) return EFI_COMPROMISED_DATA;
    if (Node->Type == END_DEVICE_PATH_TYPE) {
      if (Node->SubType != END_ENTIRE_DEVICE_PATH_SUBTYPE || Length != sizeof (*Node))
        return EFI_UNSUPPORTED;
      break;
    }
    BaseLength += Length;
  }
  FileLength = sizeof (*FileNode) + sizeof (Name);
  Total = BaseLength + FileLength + sizeof (*End);
  Status = mSystem->BootServices->AllocatePool (EfiBootServicesData, Total, (VOID **)&Path);
  if (EFI_ERROR (Status)) return Status;
  mSystem->BootServices->CopyMem (Path, Base, BaseLength);
  FileNode = (EFI_DEVICE_PATH_PROTOCOL *)((UINT8 *)Path + BaseLength);
  FileNode->Type = MEDIA_DEVICE_PATH; FileNode->SubType = MEDIA_FILEPATH_DP;
  FileNode->Length[0] = (UINT8)FileLength; FileNode->Length[1] = (UINT8)(FileLength >> 8);
  mSystem->BootServices->CopyMem (FileNode + 1, (VOID *)Name, sizeof (Name));
  End = (EFI_DEVICE_PATH_PROTOCOL *)((UINT8 *)FileNode + FileLength);
  End->Type = END_DEVICE_PATH_TYPE; End->SubType = END_ENTIRE_DEVICE_PATH_SUBTYPE;
  End->Length[0] = sizeof (*End); End->Length[1] = 0;
#if defined(TIMELM_USB_WINDOWS) || defined(TIMELM_CHAINLOAD_TRACE)
  Text("Windows stage: BEFORE LoadImage (original bootmgfw.efi).\r\n");
  Status=SaveLog(Image);
  if (EFI_ERROR(Status)) { mSystem->BootServices->FreePool(Path); return Status; }
#endif
  Status = mSystem->BootServices->LoadImage (FALSE, Image, Path, NULL, 0, &Next);
  mSystem->BootServices->FreePool (Path);
#if defined(TIMELM_USB_WINDOWS) || defined(TIMELM_CHAINLOAD_TRACE)
  {
    EFI_STATUS StageLog;
    Text("Windows stage: AFTER LoadImage status="); Hex(Status); Text("\r\n");
    StageLog=SaveLog(Image);
    if (EFI_ERROR(StageLog)) {
      if (Next!=NULL) mSystem->BootServices->UnloadImage(Next);
      return StageLog;
    }
  }
#endif
  if (EFI_ERROR (Status)) {
    if (Next != NULL) mSystem->BootServices->UnloadImage (Next);
    return Status;
  }
  Status = mSystem->BootServices->HandleProtocol (Next, &mLoadedImageGuid, (VOID **)&Child);
#if defined(TIMELM_USB_WINDOWS) || defined(TIMELM_CHAINLOAD_TRACE)
  Text("Windows stage: child LoadedImage status="); Hex(Status); Text("\r\n");
#endif
  if (!EFI_ERROR (Status) && Child != NULL) {
    Child->LoadOptions = Parent->LoadOptions;
    Child->LoadOptionsSize = Parent->LoadOptionsSize;
#if defined(TIMELM_USB_WINDOWS) || defined(TIMELM_CHAINLOAD_TRACE)
    Text("Windows stage: BEFORE StartImage (original Windows Boot Manager).\r\n");
    Status=SaveLog(Image);
    if (!EFI_ERROR(Status)) {
#endif
    Status = mSystem->BootServices->StartImage (Next, &ExitSize, &ExitData);
#if defined(TIMELM_USB_WINDOWS) || defined(TIMELM_CHAINLOAD_TRACE)
    Text("Windows stage: AFTER StartImage status="); Hex(Status); Text("\r\n");
    } else Text("Windows stage: checkpoint failed; StartImage skipped.\r\n");
    (VOID)SaveLog(Image);
#endif
  } else if (!EFI_ERROR (Status)) Status = EFI_NOT_FOUND;
  // Windows normally does not return; only cleanup on returned failure/exit.
  if (ExitData != NULL) mSystem->BootServices->FreePool (ExitData);
  mSystem->BootServices->UnloadImage (Next);
  return Status;
}
