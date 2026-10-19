/* SPDX-License-Identifier: GPL-2.0-only
 * See geni_gpi.h for provenance. No Linux runtime is linked.
 */
#include "geni_gpi.h"

static GI_U32 State(GP_IO *g, GI_U32 base)
{
    return (g->Read(g->Context, base) >> 20) & 15u;
}
static void Clear(GP_IO *g, GP_ELEMENT *e)
{
    unsigned i;
    (void)g;
    for (i = 0; i < 4; ++i) e->Dword[i] = 0;
}
static enum GP_RESULT Command(GP_IO *g, unsigned channel, GI_U32 opcode, GI_U32 expected)
{
    GI_U32 base = channel < 2 ? GP_CH(channel) : GP_EV;
    GI_U32 bit = channel < 2 ? 1u << channel : 1u;
    GI_U32 status = channel < 2 ? GP_CH_IRQ : GP_EV_IRQ;
    GI_U32 clear = channel < 2 ? GP_CH_CLEAR : GP_EV_CLEAR;
    GI_U64 deadline = g->NowUs(g->Context) + 250000u;
    unsigned loops = 0;
    g->Write(g->Context, clear, bit);
    g->Write(g->Context, channel < 2 ? GP_CMD : GP_EV_CMD,
        (opcode << 24) | (channel < 2 ? channel : 0u));
    /* Require command completion as well as state. A pending timed-out
     * allocation must not be mistaken for an already-deallocated channel. */
    do {
        if ((g->Read(g->Context, status) & bit) && State(g, base) == expected) {
            g->Write(g->Context, clear, bit);
            return GpOk;
        }
        g->Pause(g->Context);
    } while (g->NowUs(g->Context) < deadline && ++loops < 250000u);
    g->Unsafe = 1;
    return GpTimeout;
}
static void RingConfig(GP_IO *g, GI_U32 base, GI_U32 doorbell, GI_U64 dma,
                       GI_U32 count, GI_U32 config)
{
    g->Write(g->Context, base, config);
    g->Write(g->Context, base + 4, count * 16u);
    g->Write(g->Context, base + 8, (GI_U32)dma);
    g->Write(g->Context, base + 12, (GI_U32)(dma >> 32));
    g->Write(g->Context, doorbell + 4, (GI_U32)(dma >> 32));
}
static int ValidRing(GI_U64 address, GI_U32 bytes)
{
    return address && !(address & (bytes - 1u)) &&
        (address >> 32) == ((address + bytes - 1u) >> 32) && address + bytes > address;
}
enum GP_RESULT GpStart(GP_IO *g)
{
    unsigned i, k;
    GI_U64 addresses[5];
    static const GI_U32 sizes[5] = {1024,1024,4096,256,256};
    enum GP_RESULT result;
    if (!g || !g->Read || !g->Write || !g->Barrier || !g->NowUs || !g->Pause ||
        !g->Cancelled || !g->HardwareError || !g->Tx || !g->Rx || !g->Events ||
        !g->TxBytes || !g->RxBytes || g->ClockSelect > 7u ||
        !ValidRing(g->TxDma, 1024) || !ValidRing(g->RxDma, 1024) ||
        !ValidRing(g->EventDma, 4096) || !g->TxBytesDma || !g->RxBytesDma) return GpInvalid;
    addresses[0] = g->TxDma; addresses[1] = g->RxDma; addresses[2] = g->EventDma;
    addresses[3] = g->TxBytesDma; addresses[4] = g->RxBytesDma;
    for (i = 0; i < 5; ++i) {
        if (addresses[i]+sizes[i] <= addresses[i]) return GpInvalid;
        for (k = 0; k < i; ++k)
            if (addresses[i] < addresses[k]+sizes[k] && addresses[k] < addresses[i]+sizes[i]) return GpInvalid;
    }
    if (g->Unsafe || g->Ready || g->EventOwned || g->ChannelOwned[0] || g->ChannelOwned[1])
        return GpBusy;
    g->Stage = 1;
    /* Never steal a live/allocated instance from firmware or another client. */
    if (State(g, GP_CH(0)) || State(g, GP_CH(1)) || State(g, GP_EV) ||
        (g->Read(g->Context, GP_IRQ_MASK) & 127u)) return GpBusy;
    for (i = 0; i < GP_RING_COUNT; ++i) { Clear(g, &g->Tx[i]); Clear(g, &g->Rx[i]); }
    for (i = 0; i < GP_EVENT_COUNT; ++i) Clear(g, &g->Events[i]);
    g->TxWrite = g->RxWrite = g->EventRead = 0;
    g->Configured = 0;
    /* Control commands are polled. The Windows ISR must not acknowledge
     * CH/EV control completion; only data/error interrupts are enabled. */
    g->Write(g->Context, GP_IRQ_MASK, 0);
    g->Write(g->Context, GP_CH_IRQ_MASK, 3);
    g->Write(g->Context, GP_EV_IRQ_MASK, 1);
    g->Write(g->Context, GP_IEOB_MASK, 1);
    g->Write(g->Context, GP_GLOB_ENABLE, 1);
    g->Write(g->Context, GP_GEN_ENABLE, 15);
    g->Write(g->Context, GP_INTSET, 1);
    g->Write(g->Context, 0x1d188u, 0);
    g->Write(g->Context, 0x1d18cu, 0);
    g->Write(g->Context, 0x1d400u, 0);
    g->Write(g->Context, 0x1d404u, 0);
    g->Stage = 2;
    g->EventOwned = 1;
    result = Command(g, 2, 0, 1);
    if (result != GpOk) return result;
    RingConfig(g, GP_EV, GP_EV_DB, g->EventDma, GP_EVENT_COUNT, (16u << 24) | (1u << 16) | 2u);
    for (i = 0x20; i <= 0x34; i += 4) g->Write(g->Context, GP_EV + i, 0);
    g->Barrier(g->Context);
    g->Write(g->Context, GP_EV_DB, (GI_U32)(g->EventDma + (GP_EVENT_COUNT-1u)*16u));
    for (k = 0; k < 2; ++k) {
        GI_U32 base = GP_CH(k);
        g->Stage = 3 + k;
        g->ChannelOwned[k] = 1;
        result = Command(g, k, 0, 1);
        if (result != GpOk) return result;
        RingConfig(g, base, GP_DB(k), k ? g->RxDma : g->TxDma,
            GP_RING_COUNT, (16u << 24) | (k ? 8u : 0u) | 2u);
        /* Paired channel, I2C protocol3, local SE5. */
        g->Write(g->Context, base + 0x60u, ((!k) << 16) | (3u << 4) | 5u);
        g->Write(g->Context, base + 0x64u, 0);
        g->Write(g->Context, base + 0x68u, 0);
        g->Write(g->Context, base + 0x6cu, 0);
        g->Write(g->Context, base + 0x5cu, 1);
    }
    for (k = 0; k < 2; ++k) {
        result = Command(g, k, 1, 2);
        if (result != GpOk) return result;
    }
    g->Stage = 5;
    g->Ready = 1;
    return GpOk;
}
enum GP_RESULT GpStop(GP_IO *g)
{
    unsigned k;
    int failed = 0;
    g->Ready = 0;
    g->Write(g->Context, GP_IRQ_MASK, 0);
    /* Stop/reset/deallocate even a partly completed allocation. Keep all
     * ownership flags and DMA mappings if any completion is unconfirmed. */
    for (k = 0; k < 2; ++k) if (g->ChannelOwned[k]) {
        GI_U32 state = State(g, GP_CH(k));
        if (state == 2 || state == 4) {
            if (Command(g, k, 2, 3) != GpOk) failed = 1;
        }
        if (Command(g, k, 9, 1) != GpOk) failed = 1;
        if (Command(g, k, 10, 0) != GpOk) failed = 1;
    }
    if (g->EventOwned && Command(g, 2, 10, 0) != GpOk) failed = 1;
    if (failed || (g->Read(g->Context, GP_IRQ_MASK) & 127u)) {
        g->Unsafe = 1; return GpIoError;
    }
    g->EventOwned = g->ChannelOwned[0] = g->ChannelOwned[1] = 0;
    g->Unsafe = g->Configured = 0;
    return GpOk;
}
static void DmaTre(GP_ELEMENT *e, GI_U64 address, GI_U32 length)
{
    e->Dword[0] = (GI_U32)address; e->Dword[1] = (GI_U32)(address >> 32);
    e->Dword[2] = length; e->Dword[3] = (0x10u << 16) | (1u << 9);
}
static GI_U32 Next(GI_U32 index, GI_U32 count) { return (index + 1u) & (count - 1u); }
enum GP_RESULT GpTransfer(GP_IO *g, GI_U8 *data, GI_U32 length,
                          int read, int hold, GI_U64 deadline)
{
    GI_U32 txLast, rxLast = 0, i;
    GI_U64 txExpected, rxExpected = 0;
    int txDone = 0, rxDone = !read;
    enum GP_RESULT result = GpOk;
    unsigned loops = 0;
    GP_ELEMENT *e;
    if (!g->Ready || g->Unsafe) return GpNotReady;
    if (!data || !length || length > GI_MAX_BYTES || (read != 0 && read != 1) ||
        (hold != 0 && hold != 1)) return GpInvalid;
    if (g->Cancelled(g->Context)) return GpCancelled;
    if (g->NowUs(g->Context) >= deadline) return GpTimeout;
    /* No pending event may be silently attributed to the next request. */
    if ((g->Read(g->Context, GP_EV + 0x10u) != (GI_U32)(g->EventDma + g->EventRead*16u)) ||
        (g->Read(g->Context, GP_EV + 0x14u) != (GI_U32)(g->EventDma >> 32))) return GpBadEvent;
    if (!g->Configured) {
        e = &g->Tx[g->TxWrite]; Clear(g, e);
        e->Dword[0] = (3u << 24) | (26u << 16) | (10u << 8) | 11u;
        e->Dword[2] = (g->ClockSelect << 16) | 7u;
        e->Dword[3] = (0x22u << 16) | 1u;
        g->TxWrite = Next(g->TxWrite, GP_RING_COUNT);
    }
    e = &g->Tx[g->TxWrite]; Clear(g, e);
    e->Dword[0] = (hold ? 1u << 26 : 0) | (0x28u << 8) | (read ? 2u : 1u);
    e->Dword[2] = read ? length : 0;
    e->Dword[3] = (0x20u << 16) | (read ? (1u << 11) | (1u << 8) : 1u);
    txLast = g->TxWrite; g->TxWrite = Next(g->TxWrite, GP_RING_COUNT);
    if (read) {
        rxLast = g->RxWrite;
        DmaTre(&g->Rx[rxLast], g->RxBytesDma, length);
        g->RxWrite = Next(g->RxWrite, GP_RING_COUNT);
        rxExpected = g->RxDma + rxLast*16u;
        for (i = 0; i < length; ++i) g->RxBytes[i] = 0;
    } else {
        for (i = 0; i < length; ++i) g->TxBytes[i] = data[i];
        txLast = g->TxWrite;
        DmaTre(&g->Tx[txLast], g->TxBytesDma, length);
        g->TxWrite = Next(g->TxWrite, GP_RING_COUNT);
    }
    txExpected = g->TxDma + txLast*16u;
    g->Barrier(g->Context);
    if (read) g->Write(g->Context, GP_DB(1), (GI_U32)(g->RxDma + g->RxWrite*16u));
    g->Write(g->Context, GP_DB(0), (GI_U32)(g->TxDma + g->TxWrite*16u));
    g->Configured = 1;
    for (;;) {
        GI_U64 producer;
        GI_U32 index, high, low;
        if (g->Cancelled(g->Context)) { result = GpCancelled; break; }
        if (g->NowUs(g->Context) >= deadline || ++loops > 250000u) { result = GpTimeout; break; }
        if (g->HardwareError(g->Context)) { result = GpIoError; break; }
        high = g->Read(g->Context, GP_EV + 0x14u);
        low = g->Read(g->Context, GP_EV + 0x10u);
        producer = ((GI_U64)high << 32) | low;
        if (producer < g->EventDma || producer >= g->EventDma + GP_EVENT_COUNT*16u ||
            ((producer - g->EventDma) & 15u)) { result = GpBadEvent; break; }
        index = (GI_U32)((producer - g->EventDma) / 16u);
        g->Barrier(g->Context);
        while (g->EventRead != index) {
            GI_U32 type, channel, code, bytes, status;
            GI_U64 pointer;
            e = &g->Events[g->EventRead];
            for (i = 0; i < 4; ++i) g->LastEvent[i] = e->Dword[i];
            type = (e->Dword[3] >> 16) & 255u;
            channel = e->Dword[3] >> 24;
            code = e->Dword[2] >> 24;
            bytes = e->Dword[2] & 0xffffffu;
            status = e->Dword[3] & 0xffffu;
            pointer = ((GI_U64)e->Dword[1] << 32) | e->Dword[0];
            if (type == 0x31u && channel < 2u) {
                result = (e->Dword[0] & 0x400u) ? GpNack : GpIoError; break;
            }
            if (type == 0x22u && channel < 2u && (status & 0x40u)) { result = GpNack; break; }
            if (type != 0x22u || channel > 1u || status || code == 16u) { result = GpBadEvent; break; }
            if (channel == 0 && !txDone && pointer == txExpected &&
                (read ? code == 4u : (code == 1u || code == 2u))) {
                /* GO EOB confirms descriptor consumption, not a DMA byte
                 * count. Only RX DMA's exact count authorizes a read copy. */
                if (!read && bytes != length) { result = GpShort; break; }
                txDone = 1;
            } else if (channel == 1 && read && !rxDone && pointer == rxExpected &&
                (code == 1u || code == 2u)) {
                if (bytes != length) { result = GpShort; break; }
                rxDone = 1;
            } else { result = GpBadEvent; break; }
            g->EventRead = Next(g->EventRead, GP_EVENT_COUNT);
        }
        if (result != GpOk) break;
        g->Barrier(g->Context);
        g->Write(g->Context, GP_EV_DB,
            (GI_U32)(g->EventDma + ((g->EventRead + GP_EVENT_COUNT-1u) & (GP_EVENT_COUNT-1u))*16u));
        g->Write(g->Context, GP_IEOB_CLEAR, 1);
        if (txDone && rxDone) {
            g->Barrier(g->Context);
            if (read) for (i = 0; i < length; ++i) data[i] = g->RxBytes[i];
            return GpOk;
        }
        g->Pause(g->Context);
    }
    g->Ready = 0;
    /* Caller quiesces both channels before buffer release or another use. */
    return result;
}
