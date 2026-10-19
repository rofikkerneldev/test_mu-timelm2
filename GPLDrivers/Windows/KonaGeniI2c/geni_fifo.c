/* SPDX-License-Identifier: GPL-2.0-only */
#include "geni_fifo.h"

enum GI_RESULT GiConfigureGpi(GI_IO *io)
{
    if (io->ClockSelect > 7u) return GiInvalid;
    if (((io->Read(io->Context, GI_FW_REV) >> 8) & 255u) != 3u ||
        (io->Read(io->Context, GI_STATUS) & 0x1001u)) return GiNotReady;
    /* Called only after board preparation and exclusive GPI ring ownership.
     * Suppress event/IRQ output while clearing stale SE/DMA status. */
    io->Write(io->Context, GI_GSI_EVENT, 0);
    io->Write(io->Context, GI_IRQ_GATE, 0);
    io->Write(io->Context, GI_IRQ_CLEAR, 0xffffffffu);
    io->Write(io->Context, 0x648u, 0xffffffffu); /* secondary IRQ clear */
    io->Write(io->Context, 0xc44u, 0xffffffffu); /* SE DMA TX IRQ clear */
    io->Write(io->Context, 0xd44u, 0xffffffffu); /* SE DMA RX IRQ clear */
    io->Write(io->Context, GI_IRQ_ENABLE,
        io->Read(io->Context, GI_IRQ_ENABLE) & ~0x4c000001u);
    io->Write(io->Context, GI_DMA_MODE, 1);
    io->Write(io->Context, GI_CLK_SEL, io->ClockSelect);
    io->Write(io->Context, GI_CLK_CFG, (7u << 4) | 1u);
    io->Write(io->Context, GI_GSI_EVENT, 15);
    return GiOk;
}

enum GI_RESULT GiInitialize(GI_IO *io)
{
    GI_U32 tx, rx;
    io->Ready = 0;
    if (io->ClockSelect > 7u) return GiInvalid;
    /* Caller must establish a powered, clocked, owned MMIO domain BEFORE
     * even these reads. Register values cannot prove that prerequisite. */
    if (((io->Read(io->Context, GI_FW_REV) >> 8) & 255u) != 3u ||
        (io->Read(io->Context, GI_IF_DISABLE) & 1u) ||
        (io->Read(io->Context, GI_STATUS) & 0x1001u)) return GiNotReady;
    tx = io->Read(io->Context, GI_HW_TX);
    rx = io->Read(io->Context, GI_HW_RX);
    io->TxDepth = (tx >> 16) & 63u;
    io->RxDepth = (rx >> 16) & 63u;
    if (((tx >> 24) & 63u) != 32u || ((rx >> 24) & 63u) != 32u ||
        io->TxDepth < 2u || io->RxDepth < 2u ||
        (io->Read(io->Context, GI_TX_STATUS) & 0x0fffffffu) ||
        (io->Read(io->Context, GI_RX_STATUS) & 0x01ffffffu)) return GiNotReady;
    /* Poll primary status locally; do not assert an unhandled GIC IRQ. */
    io->Write(io->Context, GI_IRQ_GATE, 0);
    io->Write(io->Context, GI_GSI_EVENT, 0);
    io->Write(io->Context, GI_DMA_MODE, 0);
    io->Write(io->Context, 0x028u, io->Read(io->Context, 0x028u) | 0x7fu);
    io->Write(io->Context, 0xe30u, io->Read(io->Context, 0xe30u) | 0x0fu);
    io->Write(io->Context, 0x024u, 0x7fu);
    io->Write(io->Context, 0x020u, 1);
    /* Four 8-bit MSB-first words packed into one little-endian FIFO word. */
    io->Write(io->Context, GI_TX_PACK0, 0x0007f8feu);
    io->Write(io->Context, GI_TX_PACK1, 0x000ffefeu);
    io->Write(io->Context, GI_RX_PACK0, 0x0007f8feu);
    io->Write(io->Context, GI_RX_PACK1, 0x000ffefeu);
    io->Write(io->Context, GI_BYTE_GRAN, 0);
    io->Write(io->Context, GI_RX_WM, 1);
    io->Write(io->Context, GI_RX_RFR, io->RxDepth);
    io->Write(io->Context, GI_TX_WM, 1);
    /* Fixed 100 kHz, only after a verified 19.2 MHz firmware handoff. */
    io->Write(io->Context, GI_CLK_SEL, io->ClockSelect);
    io->Write(io->Context, GI_CLK_CFG, (7u << 4) | 1u);
    io->Write(io->Context, GI_SCL, (10u << 20) | (12u << 10) | 26u);
    io->Write(io->Context, GI_IRQ_CLEAR, 0xffffffffu);
    io->Write(io->Context, GI_IRQ_ENABLE, GI_ERRORS | GI_DONE | 0x4c000000u);
    io->Ready = 1;
    return GiOk;
}

enum GI_RESULT GiAbort(GI_IO *io)
{
    GI_U64 deadline = io->NowUs(io->Context) + 2000u;
    io->Ready = 0; /* No reuse after failure until an explicit D0 re-init. */
    io->Write(io->Context, GI_CMD_CTRL, 2u);
    do {
        if (!(io->Read(io->Context, GI_STATUS) & 1u)) {
            io->Write(io->Context, GI_IRQ_CLEAR, 0xffffffffu);
            return GiOk;
        }
        io->Pause(io->Context);
    } while (io->NowUs(io->Context) < deadline);
    return GiTimeout;
}

enum GI_RESULT GiTransfer(GI_IO *io, GI_U8 *buffer, GI_U32 length,
                         int read, int hold, GI_U64 deadline)
{
    GI_U32 offset = 0;
    enum GI_RESULT result = GiOk;
    if (!io->Ready) return GiNotReady;
    if (!buffer || !length || length > GI_MAX_BYTES) return GiInvalid;
    if (io->Cancelled(io->Context)) return GiCancelled;
    if (io->NowUs(io->Context) >= deadline) return GiTimeout;
    /* This prototype owns only the V60 internal touch address 0x28. */
    io->Write(io->Context, GI_IRQ_CLEAR, 0xffffffffu);
    io->Write(io->Context, read ? GI_RX_LEN : GI_TX_LEN, length);
    io->Write(io->Context, GI_CMD, ((read ? 2u : 1u) << 27) |
              (0x28u << 9) | (hold ? 4u : 0u));
    for (;;) {
        GI_U32 irq, words, j;
        if (io->Cancelled(io->Context)) { result = GiCancelled; break; }
        if (io->NowUs(io->Context) >= deadline) { result = GiTimeout; break; }
        irq = io->Read(io->Context, GI_IRQ_STATUS);
        if (irq & GI_NACK) { result = GiNack; break; }
        if (irq & GI_ERRORS) { result = GiIoError; break; }
        if (read) {
            GI_U32 rxStatus = io->Read(io->Context, GI_RX_STATUS);
            words = rxStatus & 0x01ffffffu;
            if (words > io->RxDepth) { result = GiIoError; break; }
            for (j = 0; j < words; ++j) {
                GI_U32 value = io->Read(io->Context, GI_RX_FIFO), k, valid = 4u;
                if ((rxStatus & 0x80000000u) && j + 1u == words) {
                    GI_U32 tail = (rxStatus >> 28) & 7u;
                    if (tail) valid = tail;
                    if (valid > 4u) { result = GiIoError; break; }
                }
                if (offset >= length) { result = GiIoError; break; }
                for (k = 0; k < valid && offset < length; ++k) {
                    buffer[offset++] = (GI_U8)value;
                    value >>= 8;
                }
            }
            if (result != GiOk) break;
        } else if (!(irq & GI_DONE)) {
            GI_U32 occupied = io->Read(io->Context, GI_TX_STATUS) & 0x0fffffffu;
            if (occupied > io->TxDepth) { result = GiIoError; break; }
            words = io->TxDepth - occupied;
            for (j = 0; j < words && offset < length; ++j) {
                GI_U32 value = 0, k;
                for (k = 0; k < 4u && offset < length; ++k)
                    value |= (GI_U32)buffer[offset++] << (k * 8u);
                io->Write(io->Context, GI_TX_FIFO, value);
            }
        }
        if (irq & GI_DONE) {
            io->Write(io->Context, GI_IRQ_CLEAR, irq);
            if (offset == length) return GiOk;
            result = GiShort;
            break;
        }
        if (irq) io->Write(io->Context, GI_IRQ_CLEAR, irq);
        io->Pause(io->Context);
    }
    (void)GiAbort(io);
    return result;
}
