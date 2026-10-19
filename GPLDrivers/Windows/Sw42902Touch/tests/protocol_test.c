/* SPDX-License-Identifier: GPL-3.0-or-later */
#include <assert.h>
#include <stdio.h>
#include <string.h>
#include "../driver/sw42902_protocol.h"
#include "recovery_v074.h"

static void le32(uint8_t *p, uint32_t value)
{
    unsigned i;
    for (i = 0; i < 4; ++i) p[i] = (uint8_t)(value >> (8 * i));
}
static void finger(uint8_t *p, unsigned id, unsigned event, unsigned x, unsigned y)
{
    le32(p, id | (event << 16) | (x << 18));
    le32(p + 4, y | (100u << 14));
}
int main(void)
{
    uint8_t packet[SW42902_PACKET_SIZE] = {0}, report[SW42902_REPORT_SIZE];
    unsigned i;
    le32(packet, 6u);
    le32(packet + 4, 0x005580e0u);
    le32(packet + 8, 1u << 8);
    memset(packet + 12, 0xff, 24); /* Pen bytes must never become fingers. */
    finger(packet + 36, 7, 1, 1080, 2460);
    assert(Sw42902Decode(packet, sizeof(packet), report) == 1);
    assert(report[0] == 0x54 && report[1] == 3 && report[2] == 7);
    assert(report[3] == 0x38 && report[4] == 4);
    assert(report[5] == 0x9c && report[6] == 9 && report[61] == 1);
    for (i = 0; i < 48; ++i)
        assert(Sw42902Decode(packet, i, report) == -1);
    le32(packet + 8, 11u << 8);
    assert(Sw42902Decode(packet, sizeof(packet), report) == -1);
    le32(packet + 8, 2u << 8);
    finger(packet + 48, 7, 2, 20, 30);
    assert(Sw42902Decode(packet, sizeof(packet), report) == -1); /* duplicate */
    finger(packet + 48, 8, 3, 20, 30);
    assert(Sw42902Decode(packet, sizeof(packet), report) == 1);
    assert(report[7] == 0 && report[8] == 8 && report[61] == 2);
    finger(packet + 48, 8, 2, 1081, 30);
    assert(Sw42902Decode(packet, sizeof(packet), report) == -1);
    finger(packet + 48, 8, 2, 10, 2461);
    assert(Sw42902Decode(packet, sizeof(packet), report) == -1);
    finger(packet + 48, 10, 2, 10, 30);
    assert(Sw42902Decode(packet, sizeof(packet), report) == -1);
    le32(packet + 8, 0x80000100u);
    assert(Sw42902Decode(packet, sizeof(packet), report) == 1 && report[61] == 0);
    le32(packet + 8, 1u << 8);
    finger(packet + 36, 15, 1, 0, 0);
    assert(Sw42902Decode(packet, sizeof(packet), report) == 1 && report[61] == 0);
    le32(packet + 8, 0);
    assert(Sw42902Decode(packet, sizeof(packet), report) == 1 && report[61] == 0);
    le32(packet + 8, 10u << 8);
    for (i = 0; i < 10; ++i) finger(packet + 36 + 12 * i, i, 2, i * 100, i * 200);
    assert(Sw42902Decode(packet, sizeof(packet), report) == 1 && report[61] == 10);
    le32(packet + 4, 3u << 16);
    assert(Sw42902Decode(packet, sizeof(packet), report) == 0);
    le32(packet + 4, 0x005580e0u);
    packet[0] |= 8; /* IC hardware fault: never publish coordinates. */
    assert(Sw42902Decode(packet, sizeof(packet), report) == -1);
    packet[0] = 6;
    packet[8] = 1; /* LPWG, not an absolute touch packet. */
    assert(Sw42902Decode(packet, sizeof(packet), report) == 0);
    /* Real v0.74 wire packet read while the user swiped Recovery. */
    assert(Sw42902Decode(RecoveryV074, sizeof(RecoveryV074), report) == 1);
    assert(report[1] == 3 && report[2] == 0 && report[61] == 1);
    assert(report[3] == 89 && report[4] == 0 && report[5] == 44 && report[6] == 1);
    assert(Sw42902Decode(RecoveryV074, 47, report) == -1);
    puts("SW42902 protocol tests passed");
    return 0;
}
