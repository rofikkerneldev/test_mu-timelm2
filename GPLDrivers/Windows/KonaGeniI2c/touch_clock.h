/* SPDX-License-Identifier: GPL-2.0-only */
#ifndef TIMELM_TOUCH_CLOCK_H
#define TIMELM_TOUCH_CLOCK_H
#include "geni_fifo.h"

/* GCC SM8250 wrap1/SE5 only. Offsets are relative to GCC, not the SE.
 * The Windows adapter accepts only the two exact ACPI page resources.
 * No PLL, RPMh, other SE, or secure ownership registers are written. */
#define TC_VOTE 0x52008u
#define TC_M_AHB 0x18004u
#define TC_S_AHB 0x18008u
#define TC_BRANCH 0x185fcu
#define TC_CMD 0x18600u
#define TC_CFG 0x18604u
#define TC_DFS 0x18614u
#define TC_PERF(n) (0x1861cu + 4u * (n))
#define TC_MASK ((1u << 20) | (1u << 21) | (1u << 27))
enum TC_RESULT { TcOk, TcInvalid, TcBusy, TcUnsupported, TcTimeout, TcReadback };
typedef struct TOUCH_CLOCK {
    void *Context;
    GI_U32 (*Read)(void *, GI_U32);
    void (*Write)(void *, GI_U32, GI_U32);
    void (*DelayUs)(void *, GI_U32);
    GI_U32 AddedVotes, SavedCfg, Select;
    int Active, ChangedCfg;
} TOUCH_CLOCK;
enum TC_RESULT TouchClockStart(TOUCH_CLOCK *clock);
enum TC_RESULT TouchClockStop(TOUCH_CLOCK *clock);
#endif
