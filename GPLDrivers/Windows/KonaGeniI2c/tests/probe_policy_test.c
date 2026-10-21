/* SPDX-License-Identifier: GPL-2.0-only */
#include <assert.h>
#include <stdio.h>
#include "../probe_policy.h"
int main(void)
{
    unsigned i;
    const GI_U32 votes=(1u<<20)|(1u<<21)|(1u<<27);
    assert(TimelmProbeEngineReadable(1,1,1,0,votes));
    assert(TimelmProbeEngineReadable(0,0,0,0,votes));
    for (i=0;i<5;++i) {
        GI_U32 a[5]={1,1,1,0,votes};a[i]=0xffffffffu;
        assert(!TimelmProbeEngineReadable(a[0],a[1],a[2],a[3],a[4]));
    }
    assert(!TimelmProbeEngineReadable(0x80000001,1,1,0,votes));
    assert(!TimelmProbeEngineReadable(1,0x80000001,1,0,votes));
    assert(!TimelmProbeEngineReadable(1,1,0x80000001,0,votes));
    /* A voted CBCR can have bit zero clear while another register contains
     * the enable vote. Bit 31, not bit zero, reports branch stop. */
    assert(TimelmProbeEngineReadable(2,0,0,2,votes));
    for (i=0;i<32;++i) {
        GI_U32 bit=1u<<i;
        int expected=(bit&0x800000f1u)==0;
        assert(TimelmProbeEngineReadable(1,1,1,bit,votes)==expected);
        /* Only dropping a required vote blocks a valid snapshot. */
        assert(TimelmProbeEngineReadable(1,1,1,0,votes&~bit)==!(votes&bit));
    }
    /* An idle command with ROOT_OFF is not an operating clock root. */
    assert(!TimelmProbeEngineReadable(0,0,0,0x80000000u,votes));
    assert(!TimelmProbeEngineReadable(0,0,0,0x80u,votes));
    assert(!TimelmProbeEngineReadable(0,0,0,0,0));
    puts("Clock snapshot policy: stopped branches/root, invalid reads and pending updates refuse GENI reads");
    return 0;
}
