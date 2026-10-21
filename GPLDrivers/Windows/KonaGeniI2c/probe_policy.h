/* SPDX-License-Identifier: GPL-2.0-only */
#ifndef TIMELM_PROBE_POLICY_H
#define TIMELM_PROBE_POLICY_H
#include "geni_fifo.h"
/* A read-only GENI snapshot is allowed only when all three observed clock
 * branches and their root report running. These are voted branches: CBCR bit
 * zero need not be set, because the enable votes live in GCC_APCS_CLOCK_BRANCH
 * ENA_VOTE. Therefore a zero CBCR is a valid running observation; it is not
 * independently proof of a valid/powered register window. Also require all
 * three AP enable votes, conservatively declining another owner's votes.
 * Reject the all-ones bus sentinel, CLK_OFF, ROOT_OFF, pending UPDATE and dirty
 * shadow registers. Votes without branch/root status are never sufficient.
 * Register facts: Linux gcc-sm8250.c, clk-branch.c and clk-rcg2.c. */
static int TimelmProbeEngineReadable(GI_U32 master, GI_U32 slave,
                                    GI_U32 engine, GI_U32 command, GI_U32 votes)
{
    const GI_U32 requiredVotes=(1u<<20)|(1u<<21)|(1u<<27);
    if (master==0xffffffffu || slave==0xffffffffu ||
        engine==0xffffffffu || command==0xffffffffu ||
        votes==0xffffffffu) return 0;
    if ((votes&requiredVotes)!=requiredVotes) return 0;
    if ((master|slave|engine)&0x80000000u) return 0;
    return !(command&0x800000f1u);
}
#endif
