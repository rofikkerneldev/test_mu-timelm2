/* SPDX-License-Identifier: GPL-3.0-or-later
 * SW42902 wire format, independently decoded from the LG timelm register map.
 * No compiler bitfields: the 24-byte pen block must precede finger records.
 */
#ifndef SW42902_PROTOCOL_H
#define SW42902_PROTOCOL_H
#ifdef _KERNEL_MODE
/* ntddk.h is already included by the KMDF translation unit. Do not import
 * the user-mode CRT's stdint/vcruntime headers into that compilation. */
typedef UCHAR SW42902_U8;
typedef ULONG SW42902_U32;
#else
#include <stddef.h>
#include <stdint.h>
typedef uint8_t SW42902_U8;
typedef uint32_t SW42902_U32;
#endif

#define SW42902_X_MAX 1080u
#define SW42902_Y_MAX 2460u
#define SW42902_CONTACTS 10u
#define SW42902_PACKET_SIZE 156u
#define SW42902_REPORT_SIZE 62u
#define SW42902_REPORT_REGISTER 0x600u

static SW42902_U32 Sw42902Le32(const SW42902_U8 *p)
{
    return (SW42902_U32)p[0] | ((SW42902_U32)p[1] << 8) |
           ((SW42902_U32)p[2] << 16) | ((SW42902_U32)p[3] << 24);
}

/* 1 = touch report, 0 = unrelated IRQ, -1 = malformed packet.
 * Output is initialized first. Caller must publish only return value 1.
 * HID contact count includes explicit UP records, with Tip Switch cleared.
 */
static int Sw42902Decode(const SW42902_U8 *packet, size_t length,
                        SW42902_U8 report[SW42902_REPORT_SIZE])
{
    SW42902_U32 status, header, seen = 0;
    unsigned int i, count, out = 0;
    for (i = 0; i < SW42902_REPORT_SIZE; ++i) report[i] = 0;
    report[0] = 0x54;
    if (length < 36) return -1;
    status = Sw42902Le32(packet + 4);
    header = Sw42902Le32(packet + 8);
    if (((status >> 16) & 15u) != 5u || (header & 255u) != 0) return 0;
    /* Reject the vendor driver's hardware-reset/firmware-error conditions.
     * Recovery/reflashing belongs to a separate, validated lifecycle path.
     */
    if (((Sw42902Le32(packet) ^ 0x06u) & 0x2au) != 0 ||
        ((status ^ 0x005080e0u) & 0x6e0u) != 0) return -1;
    count = (header >> 8) & 31u;
    if (count > SW42902_CONTACTS || length < 36u + 12u * count) return -1;
    if (header & 0x80000000u) return 1; /* Palm: release all fingers. */
    for (i = 0; i < count; ++i) {
        const SW42902_U8 *finger = packet + 36u + 12u * i;
        SW42902_U32 a = Sw42902Le32(finger), b = Sw42902Le32(finger + 4);
        unsigned int id = a & 31u, event = (a >> 16) & 3u;
        unsigned int x = a >> 18, y = b & 0x3fffu;
        SW42902_U8 *point;
        if (id == 15u) { /* LG's palm sentinel. */
            unsigned int j;
            for (j = 1; j < SW42902_REPORT_SIZE; ++j) report[j] = 0;
            return 1;
        }
        if (event == 0) continue;
        if (id >= SW42902_CONTACTS || (seen & (1u << id)) ||
            x > SW42902_X_MAX || y > SW42902_Y_MAX) return -1;
        seen |= 1u << id;
        point = report + 1u + out * 6u;
        /* Neutral decoded contact state. The basic HID layer supplies the
         * descriptor's Confidence bit, stable HID ID and explicit lifts. */
        point[0] = (event == 3u) ? 0x00 : 0x03;
        point[1] = (SW42902_U8)id;
        point[2] = (SW42902_U8)x;
        point[3] = (SW42902_U8)(x >> 8);
        point[4] = (SW42902_U8)y;
        point[5] = (SW42902_U8)(y >> 8);
        ++out;
    }
    report[61] = (SW42902_U8)out;
    return 1;
}
#endif
