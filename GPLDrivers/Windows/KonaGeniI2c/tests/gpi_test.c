/* SPDX-License-Identifier: GPL-2.0-only */
#include <assert.h>
#include <stdio.h>
#include <string.h>
#include "../geni_gpi.h"
#include "../dma_policy.h"
typedef struct MOCK {
    GI_U32 Regs[0x20000 / 4];
    GP_ELEMENT Tx[64], Rx[64], Events[256];
    GI_U8 TxBytes[256], RxBytes[256], Source[256], Wire[256];
    GI_U64 Time, CancelAt;
    GP_IO *Io;
    GI_U32 TxRead, RxRead, EventWrite, Doorbells, Writes, Commands;
    unsigned Read, Length, Hold, Configs, Clock;
    int Pending, Stuck, BadPointer, BadChannel, BadType, BadStatus, Short, Reverse;
    int BadProducer, SilentCommand, FailStop, HardwareFail;
    int Duplicate, Nack, GoCount;
} MOCK;
static GI_U32 Read(void *context, GI_U32 offset)
{
    MOCK *m = context;
    assert(offset < sizeof(m->Regs) && !(offset & 3u));
    if (m->BadProducer && m->Pending && offset == GP_EV + 0x10u) return 3;
    return m->Regs[offset/4];
}
static void Write(void *context, GI_U32 offset, GI_U32 value)
{
    MOCK *m = context;
    GP_IO *g = m->Io;
    unsigned k;
    assert(offset < sizeof(m->Regs) && !(offset & 3u));
    ++m->Writes;
    if (offset == GP_CH_CLEAR) { m->Regs[GP_CH_IRQ/4] &= ~value; return; }
    if (offset == GP_EV_CLEAR) { m->Regs[GP_EV_IRQ/4] &= ~value; return; }
    for (k = 0; k < 2; ++k) if (offset == GP_CH(k)) {
        m->Regs[offset/4] = (m->Regs[offset/4] & 0xf00000u) | (value & ~0xf00000u);
        return;
    }
    if (offset == GP_EV) {
        m->Regs[offset/4] = (m->Regs[offset/4] & 0xf00000u) | (value & ~0xf00000u);
        return;
    }
    m->Regs[offset/4] = value;
    if (offset == GP_CMD || offset == GP_EV_CMD) {
        unsigned ch = value & 255u, op = value >> 24;
        GI_U32 base = offset == GP_CMD ? GP_CH(ch) : GP_EV;
        unsigned state = op == 0 || op == 9 ? 1 : op == 1 ? 2 : op == 2 ? 3 : 0;
        assert(ch < 2 && (op == 0 || op == 1 || op == 2 || op == 9 || op == 10));
        ++m->Commands;
        if (m->FailStop && op != 0 && op != 1) return;
        m->Regs[base/4] = (m->Regs[base/4] & ~0xf00000u) | (state << 20);
        if (!m->SilentCommand) m->Regs[(offset == GP_CMD ? GP_CH_IRQ : GP_EV_IRQ)/4] |=
            offset == GP_CMD ? 1u << ch : 1u;
        return;
    }
    if (offset == GP_EV+12) {
        m->EventWrite = 0;
        m->Regs[(GP_EV+16)/4] = (GI_U32)g->EventDma;
        m->Regs[(GP_EV+20)/4] = (GI_U32)(g->EventDma >> 32);
    }
    if (offset == GP_DB(0)) {
        GI_U32 end = (value - (GI_U32)g->TxDma)/16u;
        assert(end < 64 && m->TxRead != end);
        ++m->Doorbells;
        while (m->TxRead != end) {
            GP_ELEMENT *e = &m->Tx[m->TxRead];
            unsigned type = (e->Dword[3] >> 16) & 255u;
            if (type == 0x22) {
                assert(e->Dword[0] == 0x031a0a0bu && (e->Dword[2] & 4095u) == 7u);
                ++m->Configs; m->Clock = e->Dword[2] >> 16;
            } else if (type == 0x20) {
                assert(((e->Dword[0] >> 8) & 127u) == 0x28);
                m->Read = (e->Dword[0] & 31u) == 2u;
                m->Hold = (e->Dword[0] >> 26) & 1u;
                if (m->Read) m->Length = e->Dword[2];
            } else {
                assert(type == 0x10 && !m->Read);
                assert((((GI_U64)e->Dword[1] << 32) | e->Dword[0]) == g->TxBytesDma);
                m->Length = e->Dword[2];
                memcpy(m->Wire, m->TxBytes, m->Length);
            }
            m->TxRead = (m->TxRead + 1) & 63u;
        }
        m->Pending = 1;
    }
}
static void Barrier(void *context) { (void)context; }
static GI_U64 Now(void *context) { return ((MOCK *)context)->Time; }
static int Cancel(void *context)
{
    MOCK *m = context;
    return m->CancelAt && m->Time >= m->CancelAt;
}
static int Error(void *context) { return ((MOCK *)context)->HardwareFail; }
static void Event(MOCK *m, int rx)
{
    GP_IO *g = m->Io;
    GP_ELEMENT *e = &m->Events[m->EventWrite];
    GI_U32 index = rx ? m->RxRead : (m->TxRead + 63u) & 63u;
    GI_U64 address = (rx ? g->RxDma : g->TxDma) + index*16u;
    unsigned bytes = rx || !m->Read || m->GoCount ? m->Length : 0;
    if (m->BadPointer) address += 16;
    e->Dword[0] = (GI_U32)address; e->Dword[1] = (GI_U32)(address >> 32);
    e->Dword[2] = ((rx || !m->Read ? 2u : 4u) << 24) | (m->Short && bytes ? bytes-1 : bytes);
    e->Dword[3] = ((m->BadChannel ? 2u : (rx ? 1u : 0u)) << 24) |
        ((m->BadType ? 0x30u : 0x22u) << 16) | (m->BadStatus ? 32u : 0u);
    if (m->Nack) { e->Dword[0] = 0x400; e->Dword[3] = 0x31u << 16; }
    m->EventWrite = (m->EventWrite+1)&255u;
    m->Regs[(GP_EV+16)/4] = (GI_U32)(g->EventDma + m->EventWrite*16u);
    m->Regs[(GP_EV+20)/4] = (GI_U32)(g->EventDma >> 32);
    if (rx) m->RxRead = (m->RxRead+1)&63u;
}
static void Pause(void *context)
{
    MOCK *m = context;
    m->Time += 20;
    if (!m->Pending || m->Stuck) return;
    if (m->Read) {
        GP_ELEMENT *e = &m->Rx[m->RxRead];
        assert(e->Dword[2] == m->Length);
        memcpy(m->RxBytes, m->Source, m->Length);
    }
    if (m->Read && m->Reverse) Event(m, 1);
    Event(m, 0);
    if (m->Duplicate) Event(m, 0);
    if (m->Read && !m->Reverse) Event(m, 1);
    m->Pending = 0;
}
static GP_IO Setup(MOCK *m)
{
    GP_IO g;
    memset(m, 0, sizeof(*m)); memset(&g, 0, sizeof(g));
    g.Context = m; g.Read = Read; g.Write = Write; g.Barrier = Barrier;
    g.NowUs = Now; g.Cancelled = Cancel; g.Pause = Pause; g.HardwareError = Error;
    g.Tx = m->Tx; g.Rx = m->Rx; g.Events = m->Events;
    g.TxBytes = m->TxBytes; g.RxBytes = m->RxBytes;
    g.EventDma = 0x123000000ull; g.TxDma = g.EventDma+4096;
    g.RxDma = g.EventDma+5120; g.TxBytesDma = g.EventDma+6144; g.RxBytesDma = g.EventDma+6400;
    return g;
}
static void Start(MOCK *m, GP_IO *g)
{
    *g = Setup(m); m->Io = g;
    assert(GpStart(g) == GpOk);
    assert(m->Regs[(GP_CH(0)+0x60)/4] == 0x10035u);
    assert(m->Regs[(GP_CH(1)+0x60)/4] == 0x35u);
}
int main(void)
{
    static MOCK m;
    GP_IO g;
    GI_U8 bytes[256], output[256];
    unsigned i, length;
    GP_DMA_SNAPSHOT snapshot;
    for (i = 0; i < 256; ++i) bytes[i] = (GI_U8)(i*13u+7u);
    Start(&m, &g);
    /* Both 64-TRE channel rings and the 256-event ring must wrap repeatedly. */
    for (length = 1; length <= 256; ++length) {
        memcpy(m.Source, bytes, sizeof(bytes));
        assert(GpTransfer(&g, bytes, length, 0, 1, m.Time+50000) == GpOk);
        assert(m.Hold && memcmp(bytes,m.Wire,length) == 0);
        m.Reverse = length & 1;
        m.GoCount = length & 1;
        memset(output,0xa5,sizeof(output));
        assert(GpTransfer(&g, output, length, 1, 0, m.Time+50000) == GpOk);
        assert(!m.Hold && memcmp(bytes,output,length) == 0);
        if (length < 256) assert(output[length] == 0xa5);
    }
    assert(m.Configs == 1 && m.Doorbells == 512);
    assert(GpStop(&g) == GpOk && !g.Unsafe);
    Start(&m,&g); m.Stuck = 1;
    assert(GpTransfer(&g,bytes,2,0,0,m.Time+50000) == GpTimeout && !g.Ready);
    assert(GpStop(&g) == GpOk);
    Start(&m,&g); m.Stuck = 1; m.CancelAt = m.Time+40;
    assert(GpTransfer(&g,bytes,2,0,0,m.Time+50000) == GpCancelled);
    assert(GpStop(&g) == GpOk);
    Start(&m,&g); m.Duplicate = 1;
    assert(GpTransfer(&g,bytes,2,0,0,m.Time+50000) == GpBadEvent);
    assert(GpStop(&g) == GpOk);
    Start(&m,&g); m.Nack = 1;
    assert(GpTransfer(&g,bytes,2,0,0,m.Time+50000) == GpNack);
    assert(GpStop(&g) == GpOk);
    for (i = 0; i < 6; ++i) {
        Start(&m,&g);
        m.BadPointer = i == 0; m.BadType = i == 1; m.BadChannel = i == 2;
        m.BadStatus = i == 3; m.Short = i == 4; m.BadProducer = i == 5;
        memset(output,0xa5,sizeof(output));
        assert(GpTransfer(&g,output,8,1,0,m.Time+50000) != GpOk);
        assert(output[0] == 0xa5 && output[7] == 0xa5); /* no DMA leak on error */
        assert(GpStop(&g) == GpOk);
    }
    g = Setup(&m); m.Io = &g; m.Regs[GP_CH(0)/4] = 2u << 20;
    assert(GpStart(&g) == GpBusy && m.Writes == 0);
    g = Setup(&m); m.Io = &g; g.TxDma += 16;
    assert(GpStart(&g) == GpInvalid && m.Writes == 0);
    g = Setup(&m); m.Io = &g; g.RxDma = g.TxDma;
    assert(GpStart(&g) == GpInvalid && m.Writes == 0);
    g = Setup(&m); m.Io = &g; m.SilentCommand = 1;
    assert(GpStart(&g) == GpTimeout && g.Unsafe && g.EventOwned);
    assert(GpStop(&g) != GpOk && g.Unsafe); /* state zero alone cannot prove quiescence */
    Start(&m,&g); m.FailStop = 1;
    assert(GpStop(&g) != GpOk && g.Unsafe && g.ChannelOwned[0]);
    g = Setup(&m); m.Io = &g;
    m.Regs[0x20/4] = 0x4c017e57u; /* actual SMMU ID0 from firmware capture */
    assert(!GpDirectDmaAllowed(&m,Read,&snapshot)); /* no matching stream */
    m.Regs[0x800/4] = 0x80000056u;
    assert(!GpDirectDmaAllowed(&m,Read,&snapshot)); /* translated context is not identity */
    m.Regs[0xc00/4] = 1u << 16;
    assert(GpDirectDmaAllowed(&m,Read,&snapshot) && snapshot.Matches == 1);
    m.Regs[0xc00/4] = 2u << 16;
    assert(!GpDirectDmaAllowed(&m,Read,&snapshot)); /* faulting stream */
    m.Regs[0xc00/4] = 1u << 16; m.Regs[0] = 1;
    assert(!GpDirectDmaAllowed(&m,Read,&snapshot)); /* unknown disabled global mode */
    m.Regs[0] = 0; m.Regs[0x804/4] = 0x807f0050u;
    assert(!GpDirectDmaAllowed(&m,Read,&snapshot)); /* overlapping translated match */
    puts("GPI: all lengths, ring wrap, repeated START, completion faults and DMA quiescence passed");
    return 0;
}
