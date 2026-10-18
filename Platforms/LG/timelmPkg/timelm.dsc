##
#  Copyright (c) 2011 - 2022, ARM Limited. All rights reserved.
#  Copyright (c) 2014, Linaro Limited. All rights reserved.
#  Copyright (c) 2015 - 2020, Intel Corporation. All rights reserved.
#  Copyright (c) 2018, Bingxing Wang. All rights reserved.
#  Copyright (c) Microsoft Corporation.
#
#  SPDX-License-Identifier: BSD-2-Clause-Patent
##

################################################################################
#
# Defines Section - statements that will be processed to create a Makefile.
#
################################################################################
[Defines]
  PLATFORM_NAME                  = timelm
  PLATFORM_GUID                  = 28F1A3BF-193A-47E3-A7B9-5A435EAAB2EE
  PLATFORM_VERSION               = 0.1
  DSC_SPECIFICATION              = 0x00010005
  OUTPUT_DIRECTORY               = Build/timelmPkg
  SUPPORTED_ARCHITECTURES        = AARCH64
  BUILD_TARGETS                  = RELEASE|DEBUG
  SKUID_IDENTIFIER               = DEFAULT
  FLASH_DEFINITION               = timelmPkg/timelm.fdf
  USE_CUSTOM_DISPLAY_DRIVER      = 0

  #
  # 0 = SM8250
  # 1 = SM8250-AB
  # 2 = SM8250-AC
  #
  SOC_TYPE                       = 0

!include KonaPkg/KonaPkg.dsc.inc

[PcdsFixedAtBuild]
  #
  # DDR Memory
  #
  gArmTokenSpaceGuid.PcdSystemMemoryBase|0x80000000

  #
  # UEFI Stack
  #
  gArmPlatformTokenSpaceGuid.PcdCPUCoresStackBase|0x9FF90000
  gArmPlatformTokenSpaceGuid.PcdCPUCorePrimaryStackSize|0x40000

  #
  # SMBIOS
  #
  gSiliciumPkgTokenSpaceGuid.PcdSmbiosSystemManufacturer|"LG"
  gSiliciumPkgTokenSpaceGuid.PcdSmbiosSystemModel|"V60 ThinQ 5G"
  gSiliciumPkgTokenSpaceGuid.PcdSmbiosSystemRetailModel|"timelm"
  gSiliciumPkgTokenSpaceGuid.PcdSmbiosSystemRetailSku|"LM-V600"
  gSiliciumPkgTokenSpaceGuid.PcdSmbiosSystemBoardModel|"timelm"

  #
  # Simple GOP: mainline chosen framebuffer, 0x9C000000 / stride 4320.
  #
  gSiliciumPkgTokenSpaceGuid.PcdFrameBufferWidth|1080
  gSiliciumPkgTokenSpaceGuid.PcdFrameBufferHeight|2460
  gSiliciumPkgTokenSpaceGuid.PcdFrameBufferColorDepth|32

  #
  # Platform PEI
  #
  gQcomPkgTokenSpaceGuid.PcdPlatformType|"LA"

  gQcomPkgTokenSpaceGuid.PcdStorageIsUfs3|TRUE

[LibraryClasses]
  #
  # Memory Libraries
  #
  MemoryMapLib|timelmPkg/Library/MemoryMapLib/MemoryMapLib.inf

  #
  # QCOM Libraries
  #
  ConfigurationMapLib|timelmPkg/Library/ConfigurationMapLib/ConfigurationMapLib.inf

[Components]
  #
  # Disk and Filesystem Drivers
  #
  MdeModulePkg/Universal/Disk/DiskIoDxe/DiskIoDxe.inf
  MdeModulePkg/Universal/Disk/PartitionDxe/PartitionDxe.inf
  FatPkg/EnhancedFatDxe/Fat.inf

  #
  # ACPI Tables
  #
  timelm/AcpiTables.inf

!if $(TARGET) == DEBUG
  timelmPkg/Drivers/UfsDiagDxe/UfsDiagDxe.inf
!endif
