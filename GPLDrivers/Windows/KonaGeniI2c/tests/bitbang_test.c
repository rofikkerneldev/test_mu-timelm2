/* SPDX-License-Identifier: GPL-2.0-only
 * Electrical open-drain slave model: reconstructs bytes from SCL edges,
 * supplies ACK/read data, and injects line/clock/callback failures. */
#include <assert.h>
#include <stdio.h>
#include <string.h>
#include "../bitbang_i2c.h"

enum PHASE { Idle, Receive, SlaveAck, Transmit, MasterAck };
typedef struct MOCK {
    GI_U64 Time, HoldUntil, CancelAt;
    unsigned Sets, Gets, Delays, FailSet, FailGet, InvalidGet, Rises, StretchAt, StretchUs;
    unsigned Starts, Stops, Bits, Used, ReadUsed, ReadLength, AckUsed, NackAt, ArbitrateAt;
    int MasterScl, MasterSda, SlaveSda, LastScl, LastSda, BusySda, ArbHold;
    int Address, Reading, Acked, Clocked, FreezeClock;
    GI_U8 Byte, Wire[520], ReadData[256], Acks[256];
    enum PHASE Phase;
    BB_IO Io;
} MOCK;

static int Clock(MOCK *m) { return m->MasterScl && m->Time >= m->HoldUntil; }
static int Data(MOCK *m) { return m->MasterSda && m->SlaveSda && !m->BusySda && !m->ArbHold; }
static void LoadRead(MOCK *m)
{
    assert(m->ReadUsed < m->ReadLength);
    m->Byte = m->ReadData[m->ReadUsed++];
    m->Bits = 0;
    m->SlaveSda = (m->Byte & 0x80u) != 0;
    m->Phase = Transmit;
}
static void Update(MOCK *m)
{
    int scl = Clock(m), sda = Data(m);
    if (m->LastScl && scl && m->LastSda != sda) {
        if (!sda) {
            ++m->Starts; m->Phase = Receive; m->Bits = 0;
            m->Byte = 0; m->Address = 1; m->Reading = 0;
        } else {
            ++m->Stops; m->Phase = Idle; m->SlaveSda = 1;
        }
    }
    if (!m->LastScl && scl) {
        ++m->Rises;
        if (m->Rises == m->ArbitrateAt) { m->ArbHold = 1; sda = 0; }
        switch (m->Phase) {
        case Receive:
            m->Byte = (GI_U8)((m->Byte << 1) | (unsigned)sda);
            if (++m->Bits == 8) {
                assert(m->Used < sizeof(m->Wire));
                m->Wire[m->Used++] = m->Byte;
                m->Acked = m->Used != m->NackAt;
                if (m->Address) {
                    m->Acked &= (m->Byte >> 1) == BB_ADDRESS;
                    m->Reading = m->Byte & 1u;
                    m->Address = 0;
                }
            }
            break;
        case SlaveAck: m->Clocked = 1; break;
        case Transmit: ++m->Bits; break;
        case MasterAck:
            assert(m->AckUsed < sizeof(m->Acks));
            m->Acks[m->AckUsed++] = (GI_U8)sda;
            m->Clocked = 1;
            break;
        default: break;
        }
    }
    if (m->LastScl && !scl) {
        switch (m->Phase) {
        case Receive:
            if (m->Bits == 8) {
                m->Phase = SlaveAck; m->Clocked = 0;
                m->SlaveSda = !m->Acked;
            }
            break;
        case SlaveAck:
            if (m->Clocked) {
                m->SlaveSda = 1;
                if (!m->Acked) m->Phase = Idle;
                else if (m->Reading) LoadRead(m);
                else { m->Phase = Receive; m->Bits = 0; m->Byte = 0; }
            }
            break;
        case Transmit:
            if (m->Bits == 8) { m->Phase = MasterAck; m->Clocked = 0; m->SlaveSda = 1; }
            else m->SlaveSda = ((m->Byte << m->Bits) & 0x80u) != 0;
            break;
        case MasterAck:
            if (m->Clocked) {
                if (m->Acks[m->AckUsed - 1]) { m->Phase = Idle; m->SlaveSda = 1; }
                else LoadRead(m);
            }
            break;
        default: break;
        }
    }
    m->LastScl = Clock(m); m->LastSda = Data(m);
}
static int SetLines(void *context, int scl, int sda)
{
    MOCK *m = context;
    assert((scl == 0 || scl == 1) && (sda == 0 || sda == 1));
    ++m->Sets;
    if (m->Sets == m->FailSet) return 0;
    if (!m->MasterScl && scl && m->Rises + 1 == m->StretchAt)
        m->HoldUntil = m->Time + m->StretchUs;
    m->MasterScl = scl; m->MasterSda = sda;
    Update(m);
    return 1;
}
static int GetLines(void *context, int *scl, int *sda)
{
    MOCK *m = context;
    ++m->Gets;
    if (m->Gets == m->FailGet) return 0;
    Update(m); *scl = Clock(m); *sda = Data(m);
    if (m->Gets == m->InvalidGet) *scl = 2;
    return 1;
}
static GI_U64 Now(void *context) { return ((MOCK *)context)->Time; }
static void Delay(void *context, GI_U32 us)
{
    MOCK *m = context;
    ++m->Delays;
    if (!m->FreezeClock) m->Time += us;
    Update(m);
}
static int Cancelled(void *context)
{
    MOCK *m = context;
    return m->CancelAt && m->Time >= m->CancelAt;
}
static void Init(MOCK *m)
{
    unsigned i;
    memset(m, 0, sizeof(*m));
    m->MasterScl = m->MasterSda = m->SlaveSda = m->LastScl = m->LastSda = 1;
    m->Io.Context = m; m->Io.SetLines = SetLines; m->Io.GetLines = GetLines;
    m->Io.NowUs = Now; m->Io.DelayUs = Delay; m->Io.Cancelled = Cancelled;
    m->ReadLength = 256;
    for (i = 0; i < 256; ++i) m->ReadData[i] = (GI_U8)(0xa5u ^ i);
}
static void Released(MOCK *m)
{
    assert(m->MasterScl && m->MasterSda);
    assert(m->Time <= BB_MAX_TRANSACTION_US + BB_STRETCH_TIMEOUT_US + 4 * BB_HALF_PERIOD_US);
}
static void IdentityAndReport(void)
{
    MOCK m;
    GI_U8 command[2] = {0x26, 0x44}, data[256];
    BB_MESSAGE messages[2] = {{command, 2, 0}, {data, 8, 1}};
    unsigned length, i;
    const unsigned lengths[] = {1, 8, 156, 254};
    for (length = 0; length < sizeof(lengths) / sizeof(lengths[0]); ++length) {
        Init(&m); messages[1].Length = lengths[length];
        assert(BbTransfer(&m.Io, messages, 2, 100000) == BbOk);
        assert(m.Starts == 2 && m.Stops == 1 && m.Used == 4);
        assert(m.Wire[0] == 0x50 && m.Wire[1] == 0x26 && m.Wire[2] == 0x44 && m.Wire[3] == 0x51);
        assert(m.ReadUsed == messages[1].Length && m.AckUsed == messages[1].Length);
        for (i = 0; i < messages[1].Length; ++i) {
            assert(data[i] == m.ReadData[i]);
            assert(m.Acks[i] == (i + 1 == messages[1].Length));
        }
        Released(&m);
    }
}
static void SingleMessages(void)
{
    MOCK m;
    GI_U8 bytes[256];
    BB_MESSAGE message = {bytes, sizeof(bytes), 0};
    unsigned i;
    for (i = 0; i < sizeof(bytes); ++i) bytes[i] = (GI_U8)i;
    Init(&m);
    assert(BbTransfer(&m.Io, &message, 1, 100000) == BbOk);
    assert(m.Starts == 1 && m.Stops == 1 && m.Used == 257);
    assert(!memcmp(m.Wire + 1, bytes, sizeof(bytes)));
    Released(&m);
    Init(&m); message.Read = 1;
    assert(BbTransfer(&m.Io, &message, 1, 100000) == BbOk);
    assert(!memcmp(bytes, m.ReadData, sizeof(bytes)));
    assert(m.Starts == 1 && m.Stops == 1 && m.Used == 1);
    Released(&m);
}
static void Failures(void)
{
    MOCK m;
    GI_U8 command[2] = {0x26, 0x00}, data[156];
    BB_MESSAGE messages[2] = {{command, 2, 0}, {data, sizeof(data), 1}};
    unsigned i, sets, gets, rises;
    GI_U64 duration;
    Init(&m);
    assert(BbTransfer(&m.Io, messages, 2, 100000) == BbOk);
    sets = m.Sets; gets = m.Gets; rises = m.Rises; duration = m.Time;
    /* Every callback boundary can fail, including address, repeated START,
     * read data, final STOP and final release. */
    for (i = 1; i <= sets; ++i) {
        Init(&m); m.FailSet = i;
        assert(BbTransfer(&m.Io, messages, 2, 100000) == BbIoError);
        /* The very last release failure is only advisory; prior STOP left
         * both lines released. Earlier failures get a fresh release attempt. */
        Released(&m);
    }
    for (i = 1; i <= gets; ++i) {
        Init(&m); m.FailGet = i;
        assert(BbTransfer(&m.Io, messages, 2, 100000) == BbIoError);
        Released(&m);
    }
    for (i = 1; i <= 4; ++i) {
        Init(&m); m.NackAt = i;
        assert(BbTransfer(&m.Io, messages, 2, 100000) == BbNack);
        assert(m.Stops == 1 && m.Used == i);
        Released(&m);
    }
    Init(&m); m.BusySda = 1; m.LastSda = 0;
    assert(BbTransfer(&m.Io, messages, 2, 100000) == BbBusy);
    assert(!m.Starts && !m.Stops); Released(&m);
    Init(&m); m.ArbitrateAt = 2; /* address0x50 second bit is releasedHIGH */
    assert(BbTransfer(&m.Io, messages, 2, 100000) == BbArbitration);
    assert(m.Starts == 1 && !m.Stops); Released(&m);
    Init(&m); m.StretchAt = 5; m.StretchUs = 500;
    assert(BbTransfer(&m.Io, messages, 2, 100000) == BbOk); Released(&m);
    Init(&m); m.StretchAt = 5; m.StretchUs = 1000000;
    assert(BbTransfer(&m.Io, messages, 2, 100000) == BbTimeout); Released(&m);
    Init(&m); m.StretchAt = 5; m.StretchUs = 1000000; m.FreezeClock = 1;
    assert(BbTransfer(&m.Io, messages, 2, 100000) == BbTimeout);
    assert(m.Delays < 3000); Released(&m);
    Init(&m); m.StretchAt = rises; m.StretchUs = 1000000;
    assert(BbTransfer(&m.Io, messages, 2, 100000) == BbTimeout); Released(&m);
    Init(&m); m.InvalidGet = 3;
    assert(BbTransfer(&m.Io, messages, 2, 100000) == BbIoError); Released(&m);
    /* STOP is deliberately noncancellable cleanup, so inject only while
     * address/data are still active, excluding its three final half periods. */
    for (i = 1; i + 4 * BB_HALF_PERIOD_US < duration; i += 37) {
        Init(&m); m.CancelAt = i;
        assert(BbTransfer(&m.Io, messages, 2, 100000) == BbCancelled);
        Released(&m);
    }
    Init(&m);
    assert(BbTransfer(&m.Io, messages, 2, 100) == BbTimeout); Released(&m);
    Init(&m); m.CancelAt = duration + 1;
    assert(BbTransfer(&m.Io, messages, 2, 100000) == BbOk); Released(&m);
}
static void Invalid(void)
{
    MOCK m;
    GI_U8 data[2] = {0};
    BB_MESSAGE messages[2] = {{data, 1, 0}, {data, 1, 1}};
    Init(&m);
    assert(BbTransfer(NULL, messages, 2, 1000) == BbInvalid);
    assert(BbTransfer(&m.Io, NULL, 2, 1000) == BbInvalid);
    assert(BbTransfer(&m.Io, messages, 0, 1000) == BbInvalid);
    assert(BbTransfer(&m.Io, messages, 3, 1000) == BbInvalid);
    messages[0].Length = 0;
    assert(BbTransfer(&m.Io, messages, 2, 1000) == BbInvalid);
    messages[0].Length = 256;
    assert(BbTransfer(&m.Io, messages, 2, 1000) == BbInvalid);
    messages[0].Length = 1; messages[0].Read = 2;
    assert(BbTransfer(&m.Io, messages, 2, 1000) == BbInvalid);
    messages[0].Read = 0; messages[0].Bytes = NULL;
    assert(BbTransfer(&m.Io, messages, 2, 1000) == BbInvalid);
    messages[0].Bytes = data;
    assert(BbTransfer(&m.Io, messages, 2, 0) == BbTimeout);
    assert(!m.Sets && !m.Gets);
    m.Time = ~(GI_U64)0 - 100;
    assert(BbTransfer(&m.Io, messages, 2, ~(GI_U64)0) == BbTimeout);
    assert(!m.Sets && !m.Gets);
    Init(&m); m.CancelAt = 1; m.Time = 1;
    assert(BbTransfer(&m.Io, messages, 2, 1000) == BbCancelled);
    assert(m.Sets == 1 && !m.Starts && !m.Stops); Released(&m);
}
int main(void)
{
    IdentityAndReport(); SingleMessages(); Failures(); Invalid();
    puts("bitbang I2C electrical lifecycle tests passed");
    return 0;
}
