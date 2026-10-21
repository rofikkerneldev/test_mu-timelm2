/* SPDX-License-Identifier: GPL-2.0-only
 * Bounded single-master GPIO I2C for basic timelm SW42902 bring-up.
 * Wire sequencing is independent of the Windows GPIO adapter. */
#include "bitbang_i2c.h"

typedef struct BB_TRANSACTION {
    BB_IO *Io;
    GI_U64 Deadline;
    int Started, Cleanup;
} BB_TRANSACTION;

static enum BB_RESULT Check(BB_TRANSACTION *t)
{
    if (!t->Cleanup && t->Io->Cancelled(t->Io->Context)) return BbCancelled;
    return t->Io->NowUs(t->Io->Context) >= t->Deadline ? BbTimeout : BbOk;
}
static enum BB_RESULT Lines(BB_TRANSACTION *t, int scl, int sda)
{
    enum BB_RESULT r = Check(t);
    if (r != BbOk) return r;
    return t->Io->SetLines(t->Io->Context, scl, sda) ? BbOk : BbIoError;
}
static enum BB_RESULT Sample(BB_TRANSACTION *t, int *scl, int *sda)
{
    enum BB_RESULT r = Check(t);
    if (r != BbOk) return r;
    if (!t->Io->GetLines(t->Io->Context, scl, sda) ||
        (*scl != 0 && *scl != 1) || (*sda != 0 && *sda != 1)) return BbIoError;
    return BbOk;
}
static enum BB_RESULT Half(BB_TRANSACTION *t)
{
    enum BB_RESULT r = Check(t);
    GI_U64 now, remaining;
    if (r != BbOk) return r;
    now = t->Io->NowUs(t->Io->Context);
    if (now >= t->Deadline) return BbTimeout;
    remaining = t->Deadline - now;
    if (remaining < BB_HALF_PERIOD_US) return BbTimeout;
    t->Io->DelayUs(t->Io->Context, BB_HALF_PERIOD_US);
    return Check(t);
}
static enum BB_RESULT Raise(BB_TRANSACTION *t, int sda)
{
    GI_U64 now = t->Io->NowUs(t->Io->Context);
    GI_U64 end = now > ~(GI_U64)0 - BB_STRETCH_TIMEOUT_US ?
        ~(GI_U64)0 : now + BB_STRETCH_TIMEOUT_US;
    enum BB_RESULT r = Lines(t, 1, sda);
    int clock, data;
    unsigned polls = 0;
    if (r != BbOk) return r;
    if (end > t->Deadline) end = t->Deadline;
    for (;;) {
        r = Sample(t, &clock, &data);
        if (r != BbOk) return r;
        if (clock) return BbOk;
        if (t->Io->NowUs(t->Io->Context) >= end ||
            ++polls >= BB_STRETCH_TIMEOUT_US + 1u) return BbTimeout;
        t->Io->DelayUs(t->Io->Context, 1);
    }
}
static enum BB_RESULT Start(BB_TRANSACTION *t, int repeated)
{
    enum BB_RESULT r;
    int clock, data;
    r = Lines(t, repeated ? 0 : 1, 1);
    if (r != BbOk) return r;
    r = Half(t);
    if (r != BbOk) return r;
    if (repeated) {
        r = Raise(t, 1);
        if (r != BbOk) return r;
        r = Half(t);
        if (r != BbOk) return r;
    }
    r = Sample(t, &clock, &data);
    if (r != BbOk) return r;
    if (!clock || !data) return repeated ? BbArbitration : BbBusy;
    r = Lines(t, 1, 0);
    /* Once START is requested, conservatively attempt STOP on local errors. */
    t->Started = 1;
    if (r != BbOk) return r;
    r = Half(t);
    if (r != BbOk) return r;
    return Lines(t, 0, 0);
}
static enum BB_RESULT Stop(BB_TRANSACTION *t)
{
    enum BB_RESULT r = Lines(t, 0, 0);
    int clock, data;
    if (r != BbOk) return r;
    r = Half(t);
    if (r != BbOk) return r;
    r = Raise(t, 0);
    if (r != BbOk) return r;
    r = Half(t);
    if (r != BbOk) return r;
    r = Lines(t, 1, 1);
    if (r != BbOk) return r;
    r = Half(t);
    if (r != BbOk) return r;
    r = Sample(t, &clock, &data);
    if (r != BbOk) return r;
    if (!clock || !data) return BbIoError;
    t->Started = 0;
    return BbOk;
}
static enum BB_RESULT WriteByte(BB_TRANSACTION *t, GI_U8 value)
{
    enum BB_RESULT r;
    unsigned bit;
    int clock, data;
    for (bit = 0; bit < 8; ++bit) {
        int released = (value & 0x80u) != 0;
        r = Lines(t, 0, released);
        if (r != BbOk) return r;
        r = Half(t);
        if (r != BbOk) return r;
        r = Raise(t, released);
        if (r != BbOk) return r;
        r = Half(t);
        if (r != BbOk) return r;
        r = Sample(t, &clock, &data);
        if (r != BbOk) return r;
        if (released && !data) return BbArbitration;
        r = Lines(t, 0, released);
        if (r != BbOk) return r;
        value = (GI_U8)(value << 1);
    }
    r = Lines(t, 0, 1);
    if (r != BbOk) return r;
    r = Half(t);
    if (r != BbOk) return r;
    r = Raise(t, 1);
    if (r != BbOk) return r;
    r = Half(t);
    if (r != BbOk) return r;
    r = Sample(t, &clock, &data);
    if (r != BbOk) return r;
    r = Lines(t, 0, 1);
    if (r != BbOk) return r;
    return data ? BbNack : BbOk;
}
static enum BB_RESULT ReadByte(BB_TRANSACTION *t, GI_U8 *output, int last)
{
    GI_U8 value = 0;
    enum BB_RESULT r;
    unsigned bit;
    int clock, data;
    for (bit = 0; bit < 8; ++bit) {
        r = Lines(t, 0, 1);
        if (r != BbOk) return r;
        r = Half(t);
        if (r != BbOk) return r;
        r = Raise(t, 1);
        if (r != BbOk) return r;
        r = Half(t);
        if (r != BbOk) return r;
        r = Sample(t, &clock, &data);
        if (r != BbOk) return r;
        value = (GI_U8)((value << 1) | (unsigned)data);
        r = Lines(t, 0, 1);
        if (r != BbOk) return r;
    }
    /* ACK every byte except the last, then release SDA before STOP/restart. */
    r = Lines(t, 0, last);
    if (r != BbOk) return r;
    r = Half(t);
    if (r != BbOk) return r;
    r = Raise(t, last);
    if (r != BbOk) return r;
    r = Half(t);
    if (r != BbOk) return r;
    r = Lines(t, 0, last);
    if (r != BbOk) return r;
    r = Lines(t, 0, 1);
    if (r == BbOk) *output = value;
    return r;
}

enum BB_RESULT BbTransfer(BB_IO *io, BB_MESSAGE *messages,
                         GI_U32 count, GI_U64 deadline)
{
    BB_TRANSACTION t;
    GI_U64 now, cap;
    GI_U32 index, byte, length = 0;
    enum BB_RESULT result = BbOk, stopped;
    if (!io || !io->SetLines || !io->GetLines || !io->NowUs ||
        !io->DelayUs || !io->Cancelled || !messages || !count || count > 2)
        return BbInvalid;
    for (index = 0; index < count; ++index) {
        if (!messages[index].Bytes || !messages[index].Length ||
            messages[index].Length > BB_MAX_BYTES - length ||
            (messages[index].Read != 0 && messages[index].Read != 1)) return BbInvalid;
        length += messages[index].Length;
    }
    now = io->NowUs(io->Context);
    if (now >= deadline || now > ~(GI_U64)0 - BB_MAX_TRANSACTION_US)
        return BbTimeout;
    cap = now + BB_MAX_TRANSACTION_US;
    t.Io = io; t.Deadline = deadline < cap ? deadline : cap;
    t.Started = t.Cleanup = 0;
    for (index = 0; index < count && result == BbOk; ++index) {
        BB_MESSAGE *m = &messages[index];
        result = Start(&t, index != 0);
        if (result == BbOk) result = WriteByte(&t, (GI_U8)((BB_ADDRESS << 1) | (unsigned)m->Read));
        for (byte = 0; byte < m->Length && result == BbOk; ++byte)
            result = m->Read ? ReadByte(&t, &m->Bytes[byte], byte + 1 == m->Length) :
                              WriteByte(&t, m->Bytes[byte]);
    }
    if (t.Started && result != BbArbitration) {
        /* Cancellation/deadline aborts still need an electrical STOP. Cleanup
         * ignores cancellation, but cannot exceed its own bounded deadline. */
        t.Cleanup = 1;
        now = io->NowUs(io->Context);
        cap = BB_STRETCH_TIMEOUT_US + 4u * BB_HALF_PERIOD_US;
        t.Deadline = now > ~(GI_U64)0 - cap ? ~(GI_U64)0 : now + cap;
        stopped = Stop(&t);
        if (result == BbOk) result = stopped;
    }
    /* Including arbitration loss: release only; never generate recovery clocks.
     * Callback failure here is reportable even when data transfers succeeded. */
    if (!io->SetLines(io->Context, 1, 1) && result == BbOk) result = BbIoError;
    return result;
}
