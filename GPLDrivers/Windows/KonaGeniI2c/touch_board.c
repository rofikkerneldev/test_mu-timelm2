/* SPDX-License-Identifier: GPL-2.0-only */
#include "touch_board.h"

int TouchBoardStop(TOUCH_BOARD *b)
{
    int ok = 1;
    if (b->Powered) {
        /* Same off order as the V60 vendor kernel. Try every cleanup step. */
        if (!b->Pin(b->Context, TbReset, 0)) ok = 0;
        b->DelayMs(b->Context, 1);
        if (!b->Pin(b->Context, TbVdd, 0)) ok = 0;
        b->DelayMs(b->Context, 1);
        if (!b->Pin(b->Context, TbVcl, 0)) ok = 0;
        b->DelayMs(b->Context, 1);
        if (ok) b->Powered = 0;
    }
    if (b->Muxed) {
        if (!b->Mux(b->Context, 0)) ok = 0;
        else b->Muxed = 0;
    }
    if (TouchClockStop(&b->Clock) != TcOk) ok = 0;
    return ok;
}
int TouchBoardStart(TOUCH_BOARD *b)
{
    if (!b || !b->Pin || !b->Mux || !b->EngineReady || !b->DelayMs || b->Powered || b->Muxed)
        return 0;
    b->Stage = 1;
    b->ClockResult = TouchClockStart(&b->Clock);
    if (b->ClockResult != TcOk) return 0;
    b->Stage = 2;
    if (!b->EngineReady(b->Context)) goto Fail;
    if (!b->Mux(b->Context, 1)) goto Fail;
    b->Muxed = 1;
    b->Stage = 3;
    b->Powered = 1; /* include partial power-up in rollback */
    if (!b->Pin(b->Context, TbReset, 0)) goto Fail;
    b->DelayMs(b->Context, 1);
    b->Stage = 4;
    if (!b->Pin(b->Context, TbVcl, 1)) goto Fail;
    b->DelayMs(b->Context, 1);
    b->Stage = 5;
    if (!b->Pin(b->Context, TbVdd, 1)) goto Fail;
    b->DelayMs(b->Context, 10);
    b->Stage = 6;
    if (!b->Pin(b->Context, TbReset, 1)) goto Fail;
    b->DelayMs(b->Context, 90);
    b->Stage = 7;
    return 1;
Fail:
    (void)TouchBoardStop(b);
    return 0;
}
