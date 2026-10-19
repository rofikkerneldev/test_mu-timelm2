// SPDX-License-Identifier: BSD-2-Clause-Patent
#ifndef TIMELM_TOUCH_DMA_SNAPSHOT_H
#define TIMELM_TOUCH_DMA_SNAPSHOT_H

typedef unsigned int TD_U32;
typedef struct TD_ENTRY { TD_U32 Index, Smr, S2cr; } TD_ENTRY;
typedef struct TD_SNAPSHOT {
  TD_U32 Control, Id0, Id1, Count, Valid, Matches, Conflict, Bypass, DefaultFault;
  TD_ENTRY Entries[128];
} TD_SNAPSHOT;

// Exactly the global page already mapped by the known timelm firmware. Unknown
// IDs stop the scan. No context-bank access, clock request or MMIO write.
static int TouchDmaSnapshot(void *Context, TD_U32 (*Read)(void *, TD_U32), TD_SNAPSHOT *S)
{
  TD_U32 I;
  S->Count = S->Valid = S->Matches = S->Conflict = S->Bypass = 0;
  S->Id0 = Read(Context,0x20);
  S->Id1 = Read(Context,0x24);
  S->Control = Read(Context,0);
  S->DefaultFault = (S->Control >> 10)&1u;
  if (S->Id0 != 0x4c017e57u || S->Id1 != 0x6000004au || S->Control == 0xffffffffu)
    return 0;
  S->Count = S->Id0&255u;
  if (!(S->Id0&(1u<<27)) || !S->Count || S->Count > 128) return 0;
  for (I = 0; I < S->Count; ++I) {
    TD_U32 Smr = Read(Context,0x800u+4u*I);
    if (Smr&0x80000000u) {
      TD_U32 Mask = (Smr>>16)&0x7fffu;
      TD_ENTRY *E = &S->Entries[S->Valid++];
      E->Index = I; E->Smr = Smr; E->S2cr = Read(Context,0xc00u+4u*I);
      if ((0x56u&~Mask) == ((Smr&0x7fffu)&~Mask)) {
        ++S->Matches;
        if (((E->S2cr>>16)&3u) != 1u) S->Conflict = 1;
      }
    }
  }
  S->Bypass = S->Matches && !S->Conflict && !(S->Control&1u);
  return 1;
}
#endif
