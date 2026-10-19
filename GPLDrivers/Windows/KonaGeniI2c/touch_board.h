/* SPDX-License-Identifier: GPL-2.0-only */
#ifndef TIMELM_TOUCH_BOARD_H
#define TIMELM_TOUCH_BOARD_H
#include "touch_clock.h"
/* Adapter-independent lifecycle, exercised with fault injection. GPIO
 * connections must already be reserved. Touch data/firmware is not flashed. */
enum TB_PIN { TbReset, TbVcl, TbVdd };
typedef struct TOUCH_BOARD {
    void *Context;
    int (*Pin)(void *, enum TB_PIN, int);
    int (*Mux)(void *, int);
    int (*EngineReady)(void *);
    void (*DelayMs)(void *, unsigned);
    TOUCH_CLOCK Clock;
    unsigned Stage;
    enum TC_RESULT ClockResult;
    int Powered, Muxed;
} TOUCH_BOARD;
int TouchBoardStart(TOUCH_BOARD *board);
int TouchBoardStop(TOUCH_BOARD *board);
#endif
