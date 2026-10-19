/* SPDX-License-Identifier: GPL-3.0-or-later */
#include <assert.h>
#include <stdio.h>
#include <string.h>
#include "../driver/sw42902_protocol.h"
#include "../driver/sw42902_basic.h"
#include "recovery_v074.h"

static void Point(unsigned char *r, unsigned slot, unsigned id, unsigned flags, unsigned x, unsigned y)
{
    unsigned char *p = r+1+6*slot;
    r[0] = 0x54;
    p[0] = (unsigned char)flags; p[1] = (unsigned char)id;
    p[2] = (unsigned char)x; p[3] = (unsigned char)(x>>8);
    p[4] = (unsigned char)y; p[5] = (unsigned char)(y>>8);
    r[61] = (unsigned char)(slot+1);
}
static unsigned X(const unsigned char *r) { return r[3]+256u*r[4]; }
static unsigned Y(const unsigned char *r) { return r[5]+256u*r[6]; }
static const unsigned char *Check(SW_BASIC_STATE *s, unsigned down, unsigned x, unsigned y)
{
    unsigned i;
    const unsigned char *r = SwBasicPeek(s);
    assert(r && r[0] == 0x54 && r[1] == (down ? 7 : 4));
    assert(r[2] == 0 && r[61] == 1 && X(r) == x && Y(r) == y);
    for (i = 7; i < 61; ++i) assert(r[i] == 0);
    return r;
}
int main(void)
{
    SW_BASIC_STATE s;
    unsigned char r[62] = {0};
    unsigned i, before;
    SwBasicInit(&s);
    /* A complete tap before Windows supplies any HID read must retain DOWN/UP.
     * A zero-contact/palm packet must generate explicit lift, not Count=0. */
    assert(Sw42902Decode(RecoveryV074,sizeof(RecoveryV074),r) == 1);
    assert(SwBasicInput(&s,r));
    memset(r,0,sizeof(r)); r[0] = 0x54;
    assert(SwBasicInput(&s,r));
    assert(s.Count == 2);
    Check(&s,1,89,300); SwBasicConsume(&s);
    Check(&s,0,89,300); SwBasicConsume(&s);
    assert(!SwBasicPeek(&s) && !SwBasicInput(&s,r));
    /* Preserve the press location and latest swipe position under backpressure. */
    Point(r,0,7,3,0,0); assert(SwBasicInput(&s,r));
    for (i = 1; i <= 1000; ++i) {
        Point(r,0,7,3,i,2*i); assert(SwBasicInput(&s,r));
    }
    assert(s.Count == 2 && s.Coalesced == 999 && s.Overflows == 0);
    Point(r,0,7,0,5,5); assert(SwBasicInput(&s,r));
    Check(&s,1,0,0); SwBasicConsume(&s);
    Check(&s,1,1000,2000); SwBasicConsume(&s);
    Check(&s,0,1000,2000); SwBasicConsume(&s);
    /* All four corners and repeated taps through ring wrap. */
    for (i = 0; i < 200; ++i) {
        unsigned x = (i&1) ? 1080 : 0, y = (i&2) ? 2460 : 0;
        Point(r,0,i%10,3,x,y); assert(SwBasicInput(&s,r));
        Check(&s,1,x,y); SwBasicConsume(&s);
        assert(SwBasicRelease(&s)); Check(&s,0,x,y); SwBasicConsume(&s);
        r[61] = 0; assert(!SwBasicInput(&s,r));
    }
    /* Do not switch to a second finger mid-stroke or adopt an ignored contact
     * until it is lifted and touches again. Array order must not change ID. */
    Point(r,0,4,3,100,200); assert(SwBasicInput(&s,r));
    Point(r,0,8,3,700,800); Point(r,1,4,3,101,201);
    assert(SwBasicInput(&s,r));
    Check(&s,1,100,200); SwBasicConsume(&s);
    Check(&s,1,101,201); SwBasicConsume(&s);
    r[61] = 1; assert(SwBasicInput(&s,r));
    Check(&s,0,101,201); SwBasicConsume(&s);
    assert(!SwBasicInput(&s,r));
    r[61] = 0; assert(!SwBasicInput(&s,r));
    Point(r,0,8,3,700,800); assert(SwBasicInput(&s,r));
    Check(&s,1,700,800); SwBasicConsume(&s);
    /* I2C error release: retain ID/coordinates and require a fresh touch. */
    assert(SwBasicRelease(&s)); Check(&s,0,700,800); SwBasicConsume(&s);
    assert(!SwBasicInput(&s,r) && !SwBasicRelease(&s));
    r[61] = 0; assert(!SwBasicInput(&s,r));
    /* Failed HID copy: Peek is repeatable; only successful Consume pops. */
    Point(r,0,3,3,100,200); assert(SwBasicInput(&s,r));
    before = s.Count; Check(&s,1,100,200); Check(&s,1,100,200);
    assert(s.Count == before); SwBasicConsume(&s);
    /* Exhaust unread tap boundaries: explicitly release what Windows last saw,
     * with bounded memory, then publish the new state. */
    assert(SwBasicRelease(&s)); r[61] = 0; (void)SwBasicInput(&s,r);
    for (i = 0; i < SW_BASIC_QUEUE_SIZE/2; ++i) {
        Point(r,0,2,3,300,400); assert(SwBasicInput(&s,r));
        assert(SwBasicRelease(&s)); r[61] = 0; (void)SwBasicInput(&s,r);
    }
    assert(s.Overflows == 1 && s.Count <= SW_BASIC_QUEUE_SIZE);
    Check(&s,0,100,200);
    while (SwBasicPeek(&s)) SwBasicConsume(&s);
    assert(!(s.Delivered[1]&1u));
    puts("SW42902 basic tap/swipe, lift, backpressure and overflow tests passed");
    return 0;
}
