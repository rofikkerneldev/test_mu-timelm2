/* SPDX-License-Identifier: GPL-2.0-only */
#include <assert.h>
#include <stdio.h>
#include <string.h>
#include "../touch_board.h"
typedef struct MOCK {
    GI_U32 Registers[0x53000 / 4];
    unsigned Writes, Delay, PinCalls, MuxCalls, FailPin, FailMux;
    unsigned Events[64], EventsUsed;
    int StuckCmd, StuckBranch, EngineBad, Pins[3], MuxOn;
} MOCK;
static GI_U32 Read(void *context, GI_U32 offset)
{
    MOCK *m = context;
    assert(offset < sizeof(m->Registers));
    return m->Registers[offset / 4];
}
static void Write(void *context, GI_U32 offset, GI_U32 value)
{
    MOCK *m = context;
    ++m->Writes;
    assert(offset == TC_VOTE || offset == TC_CFG || offset == TC_CMD);
    m->Registers[offset / 4] = value;
    if (offset == TC_CMD && !m->StuckCmd) m->Registers[offset / 4] &= ~0xf1u;
    if (offset == TC_VOTE) {
        m->Registers[TC_M_AHB / 4] = value & (1u << 20) ? 0 : 0x80000000u;
        m->Registers[TC_S_AHB / 4] = value & (1u << 21) ? 0 : 0x80000000u;
        m->Registers[TC_BRANCH / 4] = (value & (1u << 27)) && !m->StuckBranch ? 0 : 0x80000000u;
    }
}
static void Us(void *context, GI_U32 count) { ((MOCK *)context)->Delay += count; }
static void Ms(void *context, unsigned count) { Us(context, count * 1000); }
static int Pin(void *context, enum TB_PIN pin, int value)
{
    MOCK *m = context;
    assert(m->EventsUsed < 64);
    m->Events[m->EventsUsed++] = 10u + (unsigned)pin * 2u + (value != 0);
    if (++m->PinCalls == m->FailPin) return 0;
    m->Pins[pin] = value;
    return 1;
}
static int Mux(void *context, int enable)
{
    MOCK *m = context;
    if (++m->MuxCalls == m->FailMux) return 0;
    m->MuxOn = enable;
    return 1;
}
static int Engine(void *context) { return !((MOCK *)context)->EngineBad; }
static TOUCH_BOARD Setup(MOCK *m)
{
    TOUCH_BOARD b;
    memset(m, 0, sizeof(*m));
    memset(&b, 0, sizeof(b));
    m->Registers[TC_CFG / 4] = 0x206u; /* inactive different source */
    m->Registers[TC_VOTE / 4] = 0x00400040u; /* unrelated engines */
    b.Context = m; b.Pin = Pin; b.Mux = Mux; b.EngineReady = Engine; b.DelayMs = Ms;
    b.Clock.Context = m; b.Clock.Read = Read; b.Clock.Write = Write; b.Clock.DelayUs = Us;
    return b;
}
int main(void)
{
    MOCK m;
    TOUCH_BOARD b;
    unsigned i;
    b = Setup(&m);
    assert(TouchBoardStart(&b) && b.Stage == 7 && b.Clock.Active);
    assert(m.EventsUsed == 4 && m.Events[0] == 10 && m.Events[1] == 13 &&
        m.Events[2] == 15 && m.Events[3] == 11); /* reset low, VCL, VDD, reset high */
    assert(m.Delay >= 102000 && m.MuxOn && m.Pins[TbReset] && m.Pins[TbVcl] && m.Pins[TbVdd]);
    assert(TouchBoardStop(&b) && !b.Clock.Active && !b.Powered && !b.Muxed);
    assert(m.Registers[TC_CFG / 4] == 0x206u && m.Registers[TC_VOTE / 4] == 0x00400040u);
    assert(m.Events[4] == 10 && m.Events[5] == 14 && m.Events[6] == 12);
    for (i = 1; i <= 4; ++i) {
        b = Setup(&m); m.FailPin = i;
        assert(!TouchBoardStart(&b));
        assert(!m.MuxOn && !b.Clock.Active && !b.Powered);
        assert(!m.Pins[0] && !m.Pins[1] && !m.Pins[2]);
        assert(m.Registers[TC_VOTE / 4] == 0x00400040u);
    }
    b = Setup(&m); m.FailMux = 1;
    assert(!TouchBoardStart(&b) && !b.Clock.Active && m.PinCalls == 0);
    b = Setup(&m); m.EngineBad = 1;
    assert(!TouchBoardStart(&b) && b.Stage == 2 && m.PinCalls == 0 && m.MuxCalls == 0);
    b = Setup(&m); m.StuckBranch = 1;
    assert(!TouchBoardStart(&b) && b.ClockResult == TcTimeout && m.PinCalls == 0);
    assert(!b.Clock.Active && m.Registers[TC_VOTE / 4] == 0x00400040u);
    b = Setup(&m); m.Registers[TC_VOTE / 4] |= 1u << 27;
    assert(!TouchBoardStart(&b) && b.ClockResult == TcBusy && m.Writes == 0);
    b = Setup(&m); m.Registers[TC_DFS / 4] = 1;
    assert(!TouchBoardStart(&b) && b.ClockResult == TcUnsupported && m.Writes == 0);
    b = Setup(&m); m.Registers[TC_DFS / 4] = 1; m.Registers[TC_PERF(5) / 4] = 1;
    assert(TouchBoardStart(&b) && b.Clock.Select == 5 && !b.Clock.ChangedCfg);
    assert(TouchBoardStop(&b) && m.Registers[TC_CFG / 4] == 0x206u);
    b = Setup(&m); m.Registers[TC_CMD / 4] = 1;
    assert(!TouchBoardStart(&b) && b.ClockResult == TcBusy && m.Writes == 0);
    b = Setup(&m); m.Registers[TC_CFG / 4] = 0xffffffffu;
    assert(!TouchBoardStart(&b) && b.ClockResult == TcReadback && m.Writes == 0);
    b = Setup(&m); m.StuckCmd = 1;
    assert(!TouchBoardStart(&b) && b.ClockResult == TcTimeout && b.Clock.Active);
    assert(m.Delay <= 400); /* bounded even when update and rollback both stall */
    m.StuckCmd = 0;
    assert(TouchBoardStop(&b) && !b.Clock.Active);
    b = Setup(&m); assert(TouchBoardStart(&b)); m.FailPin = m.PinCalls + 1;
    assert(!TouchBoardStop(&b) && b.Powered); /* never forget failed cleanup */
    assert(TouchBoardStop(&b) && !b.Powered);
    puts("timelm native clock and touch power lifecycle tests passed");
    return 0;
}
