/* SPDX-License-Identifier: GPL-2.0-only */
#include <assert.h>
#include <stdio.h>
#include <string.h>
#include "../geni_fifo.h"

typedef struct MOCK {
    GI_U32 Regs[0x1000 / 4], Queue[64], Head, Used;
    GI_U8 Source[256], Wire[256];
    GI_U32 Offset, Length, Commands[8], CommandCount, AbortCount;
    GI_U64 Time, CancelAt;
    int Read, Stuck, Nack, Short, Overflow;
} MOCK;

static GI_U32 Read(void *context, GI_U32 reg)
{
    MOCK *m = context;
    if (reg == GI_TX_STATUS) return m->Overflow ? 1000u : m->Used;
    if (reg == GI_RX_STATUS) {
        GI_U32 left, available;
        if (!m->Read || m->Stuck) return 0;
        left = m->Length - m->Offset;
        available = left > 16 ? 16 : left; /* four-word hardware FIFO */
        return (available + 3u) / 4u |
            ((available == left && available) ?
                (0x80000000u | ((available % 4u) << 28)) : 0);
    }
    if (reg == GI_RX_FIFO) {
        GI_U32 value = 0, i;
        for (i = 0; i < 4 && m->Offset < m->Length; ++i)
            value |= (GI_U32)m->Source[m->Offset++] << (8u * i);
        return value;
    }
    return m->Regs[reg / 4];
}
static void Write(void *context, GI_U32 reg, GI_U32 value)
{
    MOCK *m = context;
    if (reg == GI_IRQ_CLEAR) { m->Regs[GI_IRQ_STATUS / 4] &= ~value; return; }
    m->Regs[reg / 4] = value;
    if (reg == GI_CMD) {
        assert(m->CommandCount < 8);
        m->Commands[m->CommandCount++] = value;
        m->Read = (value >> 27) == 2u;
        m->Length = m->Regs[(m->Read ? GI_RX_LEN : GI_TX_LEN) / 4];
        m->Offset = 0;
        m->Regs[GI_STATUS / 4] = 1;
        m->Regs[GI_IRQ_STATUS / 4] = m->Nack ? GI_NACK : 0;
        if (m->Short) m->Regs[GI_IRQ_STATUS / 4] |= GI_DONE;
    }
    if (reg == GI_TX_FIFO) {
        assert(m->Used < 4);
        m->Queue[(m->Head + m->Used++) % 64] = value;
    }
    if (reg == GI_CMD_CTRL && value == 2u) {
        ++m->AbortCount;
        if (!m->Stuck) m->Regs[GI_STATUS / 4] = 0;
    }
}
static GI_U64 Now(void *context) { return ((MOCK *)context)->Time; }
static int Cancel(void *context)
{
    MOCK *m = context;
    return m->CancelAt && m->Time >= m->CancelAt;
}
static void Pause(void *context)
{
    MOCK *m = context;
    m->Time += 20;
    if (m->Stuck || m->Nack) return;
    if (!m->Read && m->Used) {
        GI_U32 value = m->Queue[m->Head++ % 64], i;
        --m->Used;
        for (i = 0; i < 4 && m->Offset < m->Length; ++i) {
            m->Wire[m->Offset++] = (GI_U8)value;
            value >>= 8;
        }
    }
    if (m->Offset == m->Length) {
        m->Regs[GI_IRQ_STATUS / 4] |= GI_DONE;
        m->Regs[GI_STATUS / 4] = 0;
    }
}
static GI_IO Setup(MOCK *m)
{
    GI_IO io = {m, Read, Write, Now, Cancel, Pause, 0, 0, 0};
    memset(m, 0, sizeof(*m));
    m->Regs[GI_FW_REV / 4] = 3u << 8;
    m->Regs[GI_HW_TX / 4] = m->Regs[GI_HW_RX / 4] = (32u << 24) | (4u << 16);
    return io;
}
int main(void)
{
    MOCK m;
    GI_IO io;
    GI_U8 bytes[256], output[258];
    GI_U32 length, i;
    for (i = 0; i < sizeof(bytes); ++i) bytes[i] = (GI_U8)(i * 37u + 5u);
    /* Exercise FIFO refill/drain and every 1..256-byte tail alignment. */
    for (length = 1; length <= 256; ++length) {
        io = Setup(&m);
        assert(GiInitialize(&io) == GiOk);
        assert(m.Regs[GI_TX_PACK0 / 4] == 0x7f8feu);
        assert(m.Regs[GI_TX_PACK1 / 4] == 0xffefeu);
        assert(GiTransfer(&io, bytes, length, 0, 1, 50000) == GiOk);
        assert(memcmp(bytes, m.Wire, length) == 0);
        assert(m.Commands[0] == ((1u << 27) | (0x28u << 9) | 4u));
        memcpy(m.Source, bytes, length);
        memset(output, 0x55, sizeof(output));
        assert(GiTransfer(&io, output + 1, length, 1, 0, 50000) == GiOk);
        assert(memcmp(bytes, output + 1, length) == 0);
        assert(output[0] == 0x55 && output[length + 1] == 0x55);
        assert(m.Commands[1] == ((2u << 27) | (0x28u << 9)));
    }
    io = Setup(&m); m.Regs[GI_FW_REV / 4] = 1u << 8;
    assert(GiInitialize(&io) == GiNotReady && m.CommandCount == 0);
    io = Setup(&m); m.Regs[GI_IF_DISABLE / 4] = 1;
    assert(GiInitialize(&io) == GiNotReady);
    io = Setup(&m); m.Regs[GI_STATUS / 4] = 1;
    assert(GiInitialize(&io) == GiNotReady);
    io = Setup(&m); m.Regs[GI_HW_TX / 4] = (16u << 24) | (4u << 16);
    assert(GiInitialize(&io) == GiNotReady);
    io = Setup(&m); assert(GiInitialize(&io) == GiOk);
    assert(GiTransfer(&io, bytes, 257, 0, 0, 50000) == GiInvalid);
    assert(GiTransfer(&io, bytes, 0, 0, 0, 50000) == GiInvalid && m.CommandCount == 0);
    m.Nack = 1;
    assert(GiTransfer(&io, bytes, 2, 0, 0, 50000) == GiNack);
    assert(m.AbortCount == 1 && !io.Ready);
    assert(GiTransfer(&io, bytes, 2, 0, 0, 50000) == GiNotReady);
    io = Setup(&m); assert(GiInitialize(&io) == GiOk); m.Stuck = 1;
    assert(GiTransfer(&io, bytes, 2, 0, 0, 100) == GiTimeout);
    assert(m.Time <= 2120 && m.AbortCount == 1 && !io.Ready);
    io = Setup(&m); assert(GiInitialize(&io) == GiOk); m.CancelAt = 20;
    assert(GiTransfer(&io, bytes, 156, 0, 0, 50000) == GiCancelled);
    assert(m.AbortCount == 1 && !io.Ready);
    io = Setup(&m); assert(GiInitialize(&io) == GiOk); m.Short = 1;
    assert(GiTransfer(&io, bytes, 2, 0, 0, 50000) == GiShort && !io.Ready);
    io = Setup(&m); assert(GiInitialize(&io) == GiOk); m.Overflow = 1;
    assert(GiTransfer(&io, bytes, 2, 0, 0, 50000) == GiIoError && !io.Ready);
    puts("GENI FIFO: all lengths, repeated-start, faults, cancel and timeout passed");
    return 0;
}
