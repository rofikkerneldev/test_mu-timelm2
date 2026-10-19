/* SPDX-License-Identifier: GPL-2.0-only
 * GPI register/TRE sequencing based on Linux qcom GPI implementations.
 * Copyright (c) 2017-2020, The Linux Foundation. All rights reserved.
 * Copyright (c) 2020, Linaro Limited
 * Windows bring-up adaptation: fixed V60 wrapper1/SE5/GPII0 only.
 */
#ifndef TIMELM_GENI_GPI_H
#define TIMELM_GENI_GPI_H
#include "geni_fifo.h"
#define GP_CH(k) (0x1a000u + 0x80u * (k))
#define GP_EV 0x1b000u
#define GP_DB(k) (0x1c000u + 8u * (k))
#define GP_EV_DB 0x1c100u
#define GP_CMD 0x1d008u
#define GP_EV_CMD 0x1d010u
#define GP_IRQ_TYPE 0x1d080u
#define GP_IRQ_MASK 0x1d088u
#define GP_CH_IRQ 0x1d090u
#define GP_EV_IRQ 0x1d094u
#define GP_CH_IRQ_MASK 0x1d098u
#define GP_EV_IRQ_MASK 0x1d09cu
#define GP_CH_CLEAR 0x1d0a0u
#define GP_EV_CLEAR 0x1d0a4u
#define GP_IEOB_MASK 0x1d0b8u
#define GP_IEOB_CLEAR 0x1d0c0u
#define GP_GLOB_STATUS 0x1d100u
#define GP_GLOB_ENABLE 0x1d108u
#define GP_GLOB_CLEAR 0x1d110u
#define GP_GEN_STATUS 0x1d118u
#define GP_GEN_ENABLE 0x1d120u
#define GP_GEN_CLEAR 0x1d128u
#define GP_INTSET 0x1d180u
#define GP_ERROR 0x1d200u
#define GP_RING_COUNT 64u
#define GP_EVENT_COUNT 256u
typedef struct GP_ELEMENT { GI_U32 Dword[4]; } GP_ELEMENT;
enum GP_RESULT { GpOk, GpInvalid, GpBusy, GpTimeout, GpCancelled,
                 GpNack, GpShort, GpBadEvent, GpIoError, GpNotReady };
typedef struct GP_IO {
    void *Context;
    GI_U32 (*Read)(void *, GI_U32);
    void (*Write)(void *, GI_U32, GI_U32);
    void (*Barrier)(void *);
    GI_U64 (*NowUs)(void *);
    void (*Pause)(void *);
    int (*Cancelled)(void *);
    int (*HardwareError)(void *);
    GP_ELEMENT *Tx, *Rx, *Events;
    GI_U8 *TxBytes, *RxBytes;
    GI_U64 TxDma, RxDma, EventDma, TxBytesDma, RxBytesDma;
    GI_U32 TxWrite, RxWrite, EventRead, ClockSelect;
    GI_U32 LastEvent[4], Stage;
    int EventOwned, ChannelOwned[2], Ready, Configured, Unsafe;
} GP_IO;
enum GP_RESULT GpStart(GP_IO *io);
/* GpStop must succeed before unmapping/freeing ANY DMA buffer or adapter.
 * On failure all mappings must be retained until reboot, not recycled. */
enum GP_RESULT GpStop(GP_IO *io);
enum GP_RESULT GpTransfer(GP_IO *io, GI_U8 *data, GI_U32 length,
                          int read, int hold, GI_U64 deadline);
#endif
