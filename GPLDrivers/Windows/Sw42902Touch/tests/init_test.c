/* SPDX-License-Identifier: GPL-3.0-or-later */
#include <assert.h>
#include <stdio.h>
#include "../driver/sw42902_init.h"
typedef struct MOCK { int Armed, Enabled, Scanning, LostEdge, FailScan; unsigned Delay; } MOCK;
static int Write(void *context, unsigned address, unsigned value)
{
    MOCK *m = context;
    if (address == 0xc01) m->Enabled = value != 0;
    if (address == 0xc03 && value == 0x8303) {
        if (m->FailScan) return 0;
        m->Scanning = 1;
        /* The IC may produce a frame immediately when U3 starts. */
        if (m->Enabled && !m->Armed) m->LostEdge = 1;
    }
    return 1;
}
static void Delay(void *context,unsigned ms) { ((MOCK *)context)->Delay += ms; }
int main(void)
{
    MOCK m = {0};
    assert(Sw42902PrepareScan(&m,Write,Delay));
    assert(!m.Enabled && !m.Scanning && !m.LostEdge && m.Delay >= 30);
    m.Armed = 1; /* framework's D0EntryPostInterruptsEnabled boundary */
    assert(Sw42902StartScan(&m,Write) && m.Enabled && m.Scanning && !m.LostEdge);
    m.Scanning = m.Enabled = 0; m.FailScan = 1;
    assert(!Sw42902StartScan(&m,Write) && !m.Enabled && !m.Scanning);
    puts("SW42902 scan/interrupt startup ordering passed");
    return 0;
}
