/* SPDX-License-Identifier: GPL-2.0-only */
#ifndef TIMELM_DMA_POLICY_H
#define TIMELM_DMA_POLICY_H
#include "geni_fifo.h"
typedef struct GP_DMA_SNAPSHOT { GI_U32 Control, Smr, S2cr, Matches; } GP_DMA_SNAPSHOT;
static int GpDirectDmaAllowed(void *context, GI_U32 (*read)(void *, GI_U32), GP_DMA_SNAPSHOT *snapshot)
{
    GI_U32 id, count, i;
    snapshot->Matches = snapshot->Smr = snapshot->S2cr = 0;
    snapshot->Control = read(context,0);
    id = read(context,0x20);
    count = id & 255u;
    /* Require enabled stream matching and a bounded, recognized layout. */
    if (id == 0xffffffffu || !(id & (1u << 27)) || !count || count > 128 ||
        (snapshot->Control & 1u)) return 0;
    for (i = 0; i < count; ++i) {
        GI_U32 smr = read(context,0x800u+i*4u);
        GI_U32 mask = (smr >> 16) & 0x7fffu;
        if ((smr & 0x80000000u) && ((0x56u & ~mask) == ((smr & 0x7fffu) & ~mask))) {
            snapshot->Smr = smr;
            snapshot->S2cr = read(context,0xc00u+i*4u);
            if (((snapshot->S2cr >> 16) & 3u) != 1u) return 0;
            ++snapshot->Matches;
        }
    }
    return snapshot->Matches != 0;
}
#endif
