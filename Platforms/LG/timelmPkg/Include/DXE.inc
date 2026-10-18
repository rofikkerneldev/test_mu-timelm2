  INF MdeModulePkg/Core/Dxe/DxeMain.inf
  INF MdeModulePkg/Universal/PCD/Dxe/Pcd.inf
  INF ArmPkg/Drivers/CpuDxe/CpuDxe.inf
  INF MdeModulePkg/Core/RuntimeDxe/RuntimeDxe.inf
  INF MdeModulePkg/Universal/SecurityStubDxe/SecurityStubDxe.inf

  INF Binaries/timelm/QcomPkg/Drivers/TzDxe/ScmDxeLA.inf

  INF MdeModulePkg/Universal/WatchdogTimerDxe/WatchdogTimer.inf
  INF MdeModulePkg/Universal/CapsuleRuntimeDxe/CapsuleRuntimeDxe.inf
  INF MdeModulePkg/Universal/ReportStatusCodeRouter/RuntimeDxe/ReportStatusCodeRouterRuntimeDxe.inf
  INF MdeModulePkg/Universal/StatusCodeHandler/RuntimeDxe/StatusCodeHandlerRuntimeDxe.inf
  INF MdeModulePkg/Universal/Variable/RuntimeDxe/VariableRuntimeDxe.inf
  INF EmbeddedPkg/EmbeddedMonotonicCounter/EmbeddedMonotonicCounter.inf
  INF EmbeddedPkg/SimpleTextInOutSerial/SimpleTextInOutSerial.inf
  INF MdeModulePkg/Universal/ResetSystemRuntimeDxe/ResetSystemRuntimeDxe.inf
  INF EmbeddedPkg/RealTimeClockRuntimeDxe/RealTimeClockRuntimeDxe.inf
  INF EmbeddedPkg/MetronomeDxe/MetronomeDxe.inf
  INF MdeModulePkg/Universal/PrintDxe/PrintDxe.inf
  INF MdeModulePkg/Universal/DevicePathDxe/DevicePathDxe.inf
  INF MdeModulePkg/Universal/Console/ConPlatformDxe/ConPlatformDxe.inf
  INF MdeModulePkg/Universal/Console/ConSplitterDxe/ConSplitterDxe.inf
  INF MdeModulePkg/Universal/Console/GraphicsConsoleDxe/GraphicsConsoleDxe.inf
  INF MdeModulePkg/Universal/HiiDatabaseDxe/HiiDatabaseDxe.inf

  INF Binaries/timelm/QcomPkg/Drivers/EnvDxe/EnvDxe.inf

  INF ArmPkg/Drivers/ArmGicDxe/ArmGicDxe.inf
  INF ArmPkg/Drivers/TimerDxe/TimerDxe.inf

  INF Binaries/timelm/QcomPkg/Drivers/ChipInfoDxe/ChipInfoDxe.inf
  INF Binaries/timelm/QcomPkg/Drivers/SmemDxe/SmemDxe.inf
  INF Binaries/timelm/QcomPkg/Drivers/ULogDxe/ULogDxe.inf
  INF Binaries/timelm/QcomPkg/Drivers/NpaDxe/NpaDxe.inf
  INF Binaries/timelm/QcomPkg/Drivers/CmdDbDxe/CmdDbDxe.inf
  INF Binaries/timelm/QcomPkg/Drivers/PwrUtilsDxe/PwrUtilsDxe.inf
  INF Binaries/timelm/QcomPkg/Drivers/RpmhDxe/RpmhDxe.inf
!if $(USE_CUSTOM_DISPLAY_DRIVER) == 1
	INF Binaries/timelm/QcomPkg/Drivers/CPRDxe/CPRDxe.inf
!endif

  INF Binaries/timelm/QcomPkg/Drivers/PdcDxe/PdcDxe.inf
  INF MdeModulePkg/Universal/Disk/DiskIoDxe/DiskIoDxe.inf
  INF MdeModulePkg/Universal/Disk/PartitionDxe/PartitionDxe.inf

  INF FatPkg/EnhancedFatDxe/Fat.inf
  INF MdeModulePkg/Universal/Disk/UnicodeCollation/EnglishDxe/EnglishDxe.inf

  INF Binaries/timelm/QcomPkg/Drivers/DALSYSDxe/DALSYSDxe.inf
  INF Binaries/timelm/QcomPkg/Drivers/ClockDxe/ClockDxe.inf
  INF Binaries/timelm/QcomPkg/Drivers/VcsDxe/VcsDxe.inf
  INF Binaries/timelm/QcomPkg/Drivers/HALIOMMUDxe/HALIOMMUDxe.inf
  INF Binaries/timelm/QcomPkg/Drivers/HWIODxe/HWIODxe.inf
  INF Binaries/timelm/QcomPkg/Drivers/GpiDxe/GpiDxe.inf
  INF Binaries/timelm/QcomPkg/Drivers/I2CDxe/I2CDxe.inf
  INF Binaries/timelm/QcomPkg/Drivers/SPIDxe/SPIDxe.inf
  INF Binaries/timelm/QcomPkg/Drivers/SPMIDxe/SPMIDxe.inf
  INF Binaries/timelm/QcomPkg/Drivers/SdccDxe/SdccDxe.inf
  INF Binaries/timelm/QcomPkg/Drivers/UFSDxe/UFSDxe.inf
  INF Binaries/timelm/QcomPkg/Drivers/TLMMDxe/TLMMDxe.inf
  INF Binaries/timelm/QcomPkg/Drivers/FeatureEnablerDxe/FeatureEnablerDxe.inf

!if $(USE_CUSTOM_DISPLAY_DRIVER) == 1
	INF Binaries/timelm/QcomPkg/Drivers/DisplayDxe/DisplayDxe.inf
!else
	INF SiliciumPkg/Drivers/SimpleFbDxe/SimpleFbDxe.inf
!endif

  INF Binaries/timelm/QcomPkg/Drivers/PlatformInfoDxe/PlatformInfoDxe.inf
  INF Binaries/timelm/QcomPkg/Drivers/ButtonsDxe/ButtonsDxe.inf
  INF Binaries/timelm/QcomPkg/Drivers/PmicDxe/PmicDxeLa.inf
  INF Binaries/timelm/QcomPkg/Drivers/ChargerExDxe/ChargerExDxe.inf
  INF Binaries/timelm/QcomPkg/Drivers/QcomChargerDxe/QcomChargerDxeLA.inf
  INF Binaries/timelm/QcomPkg/Drivers/UsbPwrCtrlDxe/UsbPwrCtrlDxe.inf
  INF Binaries/timelm/QcomPkg/Drivers/AdcDxe/AdcDxe.inf
  INF Binaries/timelm/QcomPkg/Drivers/TsensDxe/TsensDxe.inf
  INF Binaries/timelm/QcomPkg/Drivers/LimitsDxe/LimitsDxe.inf
  INF Binaries/timelm/QcomPkg/Drivers/DDRInfoDxe/DDRInfoDxe.inf
  INF Binaries/timelm/QcomPkg/Drivers/UsbfnDwc3Dxe/UsbfnDwc3Dxe.inf
  INF Binaries/timelm/QcomPkg/Drivers/XhciPciEmulationDxe/XhciPciEmulationDxe.inf
  INF Binaries/timelm/QcomPkg/Drivers/XhciDxe/XhciDxe.inf

  INF MdeModulePkg/Bus/Usb/UsbBusDxe/UsbBusDxe.inf
  INF MdeModulePkg/Bus/Usb/UsbKbDxe/UsbKbDxe.inf
  INF MdeModulePkg/Bus/Usb/UsbMassStorageDxe/UsbMassStorageDxe.inf

  INF Binaries/timelm/QcomPkg/Drivers/UsbMsdDxe/UsbMsdDxe.inf
  INF Binaries/timelm/QcomPkg/Drivers/UsbDeviceDxe/UsbDeviceDxe.inf
  INF Binaries/timelm/QcomPkg/Drivers/UsbConfigDxe/UsbConfigDxe.inf
  INF Binaries/timelm/QcomPkg/Drivers/UsbInitDxe/UsbInitDxe.inf
  INF Binaries/timelm/QcomPkg/Drivers/HashDxe/HashDxe.inf
  INF Binaries/timelm/QcomPkg/Drivers/CipherDxe/CipherDxe.inf
  INF Binaries/timelm/QcomPkg/Drivers/MacDxe/MacDxe.inf
  INF Binaries/timelm/QcomPkg/Drivers/RNGDxe/RngDxe.inf

  INF MdeModulePkg/Universal/BdsDxe/BdsDxe.inf

  # Remote processor and secure-app loading deferred during bring-up.
  INF Binaries/timelm/QcomPkg/Drivers/ShmBridgeDxe/ShmBridgeDxeLA.inf

!if $(TARGET) == DEBUG
  INF timelmPkg/Drivers/UfsDiagDxe/UfsDiagDxe.inf
!endif
