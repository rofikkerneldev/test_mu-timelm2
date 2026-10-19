/* SPDX-License-Identifier: GPL-3.0-or-later
 * Replay read-only i2ctransfer captures through the actual driver decoder.
 * stdin: 156 hexadecimal bytes per frame, whitespace separated. */
#include <stdio.h>
#include "../driver/sw42902_protocol.h"
int main(void)
{
    SW42902_U8 packet[SW42902_PACKET_SIZE], report[SW42902_REPORT_SIZE];
    unsigned i, value, frames = 0, accepted = 0, invalid = 0, unrelated = 0;
    for (;;) {
        for (i = 0; i < SW42902_PACKET_SIZE; ++i) {
            int got = scanf("%x", &value);
            if (got == EOF && i == 0) goto Done;
            if (got != 1 || value > 255) return 2;
            packet[i] = (SW42902_U8)value;
        }
        {
            int result = Sw42902Decode(packet, sizeof(packet), report);
            ++frames;
            if (result == 1) ++accepted;
            else if (result < 0) ++invalid;
            else ++unrelated;
            printf("{\"frame\":%u,\"ic_status\":%u,\"tc_status\":%u,\"header\":%u,"
                "\"decode\":%d,\"contacts\":%u}\n", frames, Sw42902Le32(packet),
                Sw42902Le32(packet+4), Sw42902Le32(packet+8), result, report[61]);
        }
    }
Done:
    fprintf(stderr, "Frames=%u accepted=%u invalid=%u unrelated=%u\n", frames, accepted, invalid, unrelated);
    return frames ? 0 : 1;
}
