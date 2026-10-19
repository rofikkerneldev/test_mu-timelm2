/* SPDX-License-Identifier: GPL-3.0-or-later */
#include "sw42902_basic.h"

static void Copy(unsigned char *to, const unsigned char *from, unsigned count)
{
    unsigned i;
    for (i = 0; i < count; ++i) to[i] = from[i];
}
static void Append(SW_BASIC_STATE *s, const unsigned char *report)
{
    Copy(s->Reports[(s->Head+s->Count)%SW_BASIC_QUEUE_SIZE],report,SW_BASIC_REPORT_SIZE);
    ++s->Count;
}
static void Enqueue(SW_BASIC_STATE *s, const unsigned char *report)
{
    if (s->Count >= 2 && (report[1]&1u)) {
        unsigned char *last = s->Reports[(s->Head+s->Count-1)%SW_BASIC_QUEUE_SIZE];
        const unsigned char *before = s->Reports[(s->Head+s->Count-2)%SW_BASIC_QUEUE_SIZE];
        if ((last[1]&1u) && (before[1]&1u) && last[2] == report[2] && before[2] == report[2]) {
            /* Retain the first DOWN, coalescing only subsequent motion. */
            Copy(last,report,SW_BASIC_REPORT_SIZE);
            ++s->Coalesced;
            return;
        }
    }
    if (s->Count == SW_BASIC_QUEUE_SIZE) {
        unsigned char release[SW_BASIC_REPORT_SIZE];
        s->Head = s->Count = 0;
        ++s->Overflows;
        /* A bounded queue cannot preserve unlimited unread taps. Resynchronize
         * the contact Windows actually saw, rather than leave it pressed. */
        if (s->Delivered[1]&1u) {
            Copy(release,s->Delivered,SW_BASIC_REPORT_SIZE);
            release[1] = 4; /* Confidence stays set through lift. */
            Append(s,release);
        }
    }
    Append(s,report);
}
static void Emit(SW_BASIC_STATE *s, unsigned down)
{
    unsigned char report[SW_BASIC_REPORT_SIZE] = {0};
    report[0] = 0x54;
    Copy(report+1,s->Point,6);
    report[1] = down ? 7 : 4; /* Tip, InRange, Confidence. */
    report[2] = 0; /* One stable HID ID; Point keeps the physical tracking ID. */
    report[61] = 1;
    Enqueue(s,report);
}
void SwBasicInit(SW_BASIC_STATE *s)
{
    unsigned i;
    unsigned char *bytes = (unsigned char *)s;
    for (i = 0; i < sizeof(*s); ++i) bytes[i] = 0;
}
int SwBasicRelease(SW_BASIC_STATE *s)
{
    if (!s->Active) return 0;
    Emit(s,0);
    s->Active = 0;
    s->Blocked |= s->LastMask;
    return 1;
}
int SwBasicInput(SW_BASIC_STATE *s, const unsigned char *decoded)
{
    unsigned i, mask = 0;
    const unsigned char *current = 0, *candidate = 0;
    if (decoded[0] != 0x54 || decoded[61] > 10) return 0;
    for (i = 0; i < decoded[61]; ++i) {
        const unsigned char *p = decoded+1+6*i;
        if (p[1] < 10 && (p[0]&1u)) mask |= 1u << p[1];
    }
    s->LastMask = mask;
    s->Blocked &= mask;
    for (i = 0; i < decoded[61]; ++i) {
        const unsigned char *p = decoded+1+6*i;
        if (p[1] >= 10 || !(p[0]&1u)) continue;
        if (s->Active && p[1] == s->Point[1]) current = p;
        if (!candidate && !(s->Blocked & (1u << p[1]))) candidate = p;
    }
    if (s->Active) {
        if (!current) return SwBasicRelease(s);
        Copy(s->Point,current,6);
        s->Blocked |= mask & ~(1u << current[1]);
        Emit(s,1);
        return 1;
    }
    if (!candidate) return 0;
    Copy(s->Point,candidate,6);
    s->Active = 1;
    s->Blocked |= mask & ~(1u << candidate[1]);
    Emit(s,1);
    return 1;
}
const unsigned char *SwBasicPeek(const SW_BASIC_STATE *s)
{
    return s->Count ? s->Reports[s->Head] : 0;
}
void SwBasicConsume(SW_BASIC_STATE *s)
{
    if (!s->Count) return;
    Copy(s->Delivered,s->Reports[s->Head],SW_BASIC_REPORT_SIZE);
    s->Head = (s->Head+1)%SW_BASIC_QUEUE_SIZE;
    --s->Count;
}
