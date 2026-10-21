/* SPDX-License-Identifier: GPL-2.0-only */
#ifndef TIMELM_BITBANG_I2C_H
#define TIMELM_BITBANG_I2C_H
#include "geni_fifo.h"

/* GPIO36=SDA, GPIO37=SCL on timelm. The adapter must own both GPIOs
 * exclusively, select GPIO mux, and emulate open drain: release means INPUT,
 * zero means OUTPUT LOW. No callback may ever drive either line HIGH.
 * This transport never accesses GENI/GPI, clocks, SMMU or DMA memory. */
#define BB_ADDRESS 0x28u
#define BB_MAX_BYTES 256u
#define BB_HALF_PERIOD_US 10u
#define BB_STRETCH_TIMEOUT_US 1000u
#define BB_MAX_TRANSACTION_US 100000u

typedef struct BB_IO {
    void *Context;
    int (*SetLines)(void *Context, int ReleaseScl, int ReleaseSda);
    int (*GetLines)(void *Context, int *Scl, int *Sda);
    GI_U64 (*NowUs)(void *Context);
    void (*DelayUs)(void *Context, GI_U32 Microseconds);
    int (*Cancelled)(void *Context);
} BB_IO;

typedef struct BB_MESSAGE {
    GI_U8 *Bytes;
    GI_U32 Length;
    int Read;
} BB_MESSAGE;

enum BB_RESULT {
    BbOk, BbInvalid, BbBusy, BbNack, BbTimeout, BbCancelled,
    BbArbitration, BbIoError
};

/* One or two atomic messages to address0x28, with a repeated START between
 * them and one final STOP. Sum of lengths must not exceed BB_MAX_BYTES.
 * Called at passive level, serialized by the adapter. Deadline uses the same
 * monotonic microsecond clock as NowUs; the function also imposes a100ms cap.
 * Report bytes are usable only on BbOk. No bus recovery pulses are emitted.
 * Bus busy/arbitration release both lines WITHOUT sending STOP. Other failures
 * after our START attempt a bounded STOP, then release both lines. Cleanup may
 * add at most one stretch timeout plus four half periods to the deadline. */
enum BB_RESULT BbTransfer(BB_IO *Io, BB_MESSAGE *Messages,
                         GI_U32 Count, GI_U64 Deadline);
#endif
