/* SPDX-License-Identifier: GPL-2.0-only */
#ifndef TIMELM_IOMMU_WINDOWS_H
#define TIMELM_IOMMU_WINDOWS_H
/* Experimental V60 contract: TI2C input ID 0 -> GPI1 stream 0x56.
 * This is not the QUP engine number and is not a Recovery IOVA. */
#define TIMELM_DMA_INPUT_ID 0u
#define TIMELM_DMA_STREAM_ID 0x56u
#define TIMELM_DMA_BYTES 8192u
#define TIMELM_DMA_IOVA 0x10000000ULL
typedef struct TIMELM_IOMMU {
    DMA_IOMMU_INTERFACE_EX Interface;
    PIOMMU_DMA_DEVICE Device;
    PIOMMU_DMA_DOMAIN Domain;
    PVOID Buffer;
    IOMMU_DMA_LOGICAL_ADDRESS Logical;
    ULONG Stage;
    NTSTATUS LastStatus;
    BOOLEAN Attached, Mapped, Ready, Retained;
} TIMELM_IOMMU;
NTSTATUS TimelmIommuAcquire(TIMELM_IOMMU *dma, PDEVICE_OBJECT pdo);
/* Caller must stop all GPI channels/events before passing quiesced=TRUE.
 * FALSE deliberately keeps every mapping and its backing memory alive. */
NTSTATUS TimelmIommuRelease(TIMELM_IOMMU *dma, BOOLEAN quiesced);
#endif
