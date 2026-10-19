/* SPDX-License-Identifier: GPL-2.0-only */
#ifndef TIMELM_GENI_FIFO_H
#define TIMELM_GENI_FIFO_H

/* Register facts and FIFO sequencing checked against Linux v6.15
 * i2c-qcom-geni.c and qcom-geni-se.c. This is a bounded polling bring-up
 * implementation, not a power manager or GENI firmware loader. */
typedef unsigned int GI_U32;
typedef unsigned char GI_U8;
typedef unsigned long long GI_U64;

#define GI_STATUS       0x040u
#define GI_FW_REV       0x068u
#define GI_IF_DISABLE   0x064u
#define GI_CLK_CFG      0x048u
#define GI_CLK_SEL      0x07cu
#define GI_BYTE_GRAN    0x254u
#define GI_DMA_MODE     0x258u
#define GI_TX_PACK0     0x260u
#define GI_TX_PACK1     0x264u
#define GI_TX_LEN       0x26cu
#define GI_RX_LEN       0x270u
#define GI_SCL          0x278u
#define GI_RX_PACK0     0x284u
#define GI_RX_PACK1     0x288u
#define GI_CMD          0x600u
#define GI_CMD_CTRL     0x604u
#define GI_IRQ_STATUS   0x610u
#define GI_IRQ_ENABLE   0x614u
#define GI_IRQ_CLEAR    0x618u
#define GI_TX_FIFO      0x700u
#define GI_RX_FIFO      0x780u
#define GI_TX_STATUS    0x800u
#define GI_RX_STATUS    0x804u
#define GI_TX_WM        0x80cu
#define GI_RX_WM        0x810u
#define GI_RX_RFR       0x814u
#define GI_HW_TX        0xe24u
#define GI_HW_RX        0xe28u
#define GI_IRQ_GATE     0xe1cu
#define GI_GSI_EVENT    0xe18u
#define GI_DONE         0x00000001u
#define GI_NACK         0x00000400u
#define GI_ERRORS       0x33007e2eu
#define GI_MAX_BYTES    256u

enum GI_RESULT { GiOk, GiNotReady, GiInvalid, GiNack, GiIoError,
                 GiTimeout, GiCancelled, GiShort };

typedef struct GI_IO {
    void *Context;
    GI_U32 (*Read)(void *, GI_U32);
    void (*Write)(void *, GI_U32, GI_U32);
    GI_U64 (*NowUs)(void *);
    int (*Cancelled)(void *);
    void (*Pause)(void *);
    GI_U32 TxDepth, RxDepth;
    int Ready;
} GI_IO;

enum GI_RESULT GiInitialize(GI_IO *io);
enum GI_RESULT GiTransfer(GI_IO *io, GI_U8 *buffer, GI_U32 length,
                         int read, int hold, GI_U64 deadline);
enum GI_RESULT GiAbort(GI_IO *io);
#endif
