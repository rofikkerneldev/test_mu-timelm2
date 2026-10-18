#include <Library/ConfigurationMapLib.h>

STATIC
EFI_CONFIGURATION_ENTRY_DESCRIPTOR
gConfigurationDescriptor[] = {
  // Configuration Map (from genuine LG V60 xbl_a.bin uefiplatLA.cfg)
  {"NumCpusFuseAddr", 0x5C04C},
  {"EnableShell", 0x1},
  {"EUDEnableAddr", 0x88E2000},
  {"SecPagePoolCount", 0x680},
  {"SharedIMEMBaseAddr", 0x146BF000},
  {"DloadCookieAddr", 0x1FD3000},
  {"DloadCookieValue", 0x10},
  {"NumCpus", 0x8},
  {"NumActiveCores", 0x8},
  {"MaxLogFileSize", 0x400000},
  {"UefiMemUseThreshold", 0x77},
  {"USBHS1_Config", 0x0},
  {"UsbFnIoRevNum", 0x10001},
  {"PwrBtnShutdownFlag", 0x0},
  {"Sdc1GpioConfigOn", 0x1E92},
  {"Sdc2GpioConfigOn", 0x1E92},
  {"Sdc1GpioConfigOff", 0xA00},
  {"Sdc2GpioConfigOff", 0xA00},
  {"EnableSDHCSwitch", 0x1},
  {"EnableUfsIOC", 0x0},
  {"UfsSmmuConfigForOtherBootDev", 0x1},
  {"SecurityFlag", 0xC4},
  {"EnableLogFsSyncInRetail", 0x0},
  {"EnableSecurityHoleForSplashPartition", 0x1},
  {"ShmBridgememSize", 0xA00000},
  {"EnableMultiThreading", 0x1},
  {"MaxCoreCnt", 0x8},
  {"EarlyInitCoreCnt", 0x1},
  {"EnableUefiSecAppDebugLogDump", 0x0},
  {"AllowNonPersistentVarsInRetail", 0x1},
  {"EnableDisplayThread", 0x1},
  {"EnableDisplayImageFv", 0x0}
};

VOID
GetConfigurationMap (
  OUT EFI_CONFIGURATION_ENTRY_DESCRIPTOR **ConfigurationDescriptor,
  OUT UINT8                               *ConfigurationDescriptorCount)
{
  *ConfigurationDescriptor      = gConfigurationDescriptor;
  *ConfigurationDescriptorCount = ARRAY_SIZE (gConfigurationDescriptor);
}
