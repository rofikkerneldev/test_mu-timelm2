/* SPDX-License-Identifier: GPL-2.0-only
 * SM8250 register facts from Linux v6.15 gcc-sm8250.c and clk-rcg2.c.
 * Intentionally limited to a 19.2 MHz TCXO path and the touch engine.
 */
#include "touch_clock.h"

static int Wait(TOUCH_CLOCK *c, GI_U32 reg, GI_U32 mask, GI_U32 value)
{
    unsigned i;
    for (i = 0; i < 200u; ++i) {
        if ((c->Read(c->Context, reg) & mask) == value) return 1;
        c->DelayUs(c->Context, 1);
    }
    return 0;
}
static int IsTcxo(GI_U32 cfg)
{
    /* src=TCXO(0), HID divider=1 (divide by one), integer bypass. */
    return (cfg & 0x371fu) == 1u;
}
enum TC_RESULT TouchClockStop(TOUCH_CLOCK *c)
{
    GI_U32 votes;
    if (!c || !c->Read || !c->Write || !c->DelayUs) return TcInvalid;
    if (!c->Active) return TcOk;
    /* Remove only votes introduced by this instance, preserving other bits. */
    votes = c->Read(c->Context, TC_VOTE);
    c->Write(c->Context, TC_VOTE, votes & ~c->AddedVotes);
    if ((c->Read(c->Context, TC_VOTE) & c->AddedVotes) != 0) return TcReadback;
    if (c->ChangedCfg) {
        /* Refuse to retune a branch that another owner has enabled. */
        if (c->Read(c->Context, TC_VOTE) & (1u << 27)) return TcBusy;
        c->Write(c->Context, TC_CFG, c->SavedCfg);
        c->Write(c->Context, TC_CMD, c->Read(c->Context, TC_CMD) | 1u);
        if (!Wait(c, TC_CMD, 1u, 0)) return TcTimeout;
        if (c->Read(c->Context, TC_CFG) != c->SavedCfg) return TcReadback;
    }
    c->Active = c->ChangedCfg = 0;
    c->AddedVotes = 0;
    return TcOk;
}
enum TC_RESULT TouchClockStart(TOUCH_CLOCK *c)
{
    GI_U32 votes, cfg, dfs, cmd, i;
    enum TC_RESULT failure = TcTimeout;
    if (!c || !c->Read || !c->Write || !c->DelayUs) return TcInvalid;
    if (c->Active) return TcBusy;
    votes = c->Read(c->Context, TC_VOTE);
    cfg = c->Read(c->Context, TC_CFG);
    dfs = c->Read(c->Context, TC_DFS);
    cmd = c->Read(c->Context, TC_CMD);
    if (votes == 0xffffffffu || cfg == 0xffffffffu || dfs == 0xffffffffu ||
        cmd == 0xffffffffu) return TcReadback;
    if (cmd & 0xf1u) return TcBusy; /* pending UPDATE/dirty shadow */
    c->Select = 0;
    if (dfs & 1u) {
        /* DFS is firmware-owned. Select an existing 19.2 MHz performance
         * slot; never disable DFS or overwrite its performance table. */
        for (i = 0; i < 8u; ++i) if (IsTcxo(c->Read(c->Context, TC_PERF(i)))) break;
        if (i == 8u) return TcUnsupported;
        c->Select = i;
    } else if (!IsTcxo(cfg) && (votes & (1u << 27))) {
        return TcBusy; /* active engine owned at a different frequency */
    }
    c->SavedCfg = cfg;
    c->AddedVotes = (~votes) & TC_MASK;
    c->ChangedCfg = 0;
    c->Active = 1;
    c->Write(c->Context, TC_VOTE, votes | (3u << 20));
    if (!Wait(c, TC_M_AHB, 0x80000000u, 0) ||
        !Wait(c, TC_S_AHB, 0x80000000u, 0)) goto Fail;
    if (!(dfs & 1u) && !IsTcxo(cfg)) {
        c->ChangedCfg = 1;
        cfg = (cfg & ~0x10371fu) | 1u;
        c->Write(c->Context, TC_CFG, cfg);
        c->Write(c->Context, TC_CMD, cmd | 1u);
        if (!Wait(c, TC_CMD, 1u, 0)) goto Fail;
        if (c->Read(c->Context, TC_CFG) != cfg) { failure = TcReadback; goto Fail; }
    }
    c->Write(c->Context, TC_VOTE, c->Read(c->Context, TC_VOTE) | TC_MASK);
    if (!Wait(c, TC_BRANCH, 0x80000000u, 0)) goto Fail;
    if ((c->Read(c->Context, TC_VOTE) & TC_MASK) != TC_MASK) {
        failure = TcReadback; goto Fail;
    }
    return TcOk;
Fail:
    /* The caller also records/handles cleanup failure; keep Active on
     * incomplete rollback so release can retry rather than forget it. */
    (void)TouchClockStop(c);
    return failure;
}
