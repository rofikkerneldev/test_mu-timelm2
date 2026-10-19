/* SPDX-License-Identifier: GPL-3.0-or-later */
#ifndef SW42902_BASIC_H
#define SW42902_BASIC_H

/* Keep the existing parallel HID report layout, exposing one contact only. */
#define SW_BASIC_REPORT_SIZE 62u
#define SW_BASIC_QUEUE_SIZE 32u
typedef struct SW_BASIC_STATE {
    unsigned char Reports[SW_BASIC_QUEUE_SIZE][SW_BASIC_REPORT_SIZE];
    unsigned char Delivered[SW_BASIC_REPORT_SIZE], Point[6];
    unsigned Head, Count, Active, Blocked, LastMask;
    unsigned Coalesced, Overflows;
} SW_BASIC_STATE;

void SwBasicInit(SW_BASIC_STATE *state);
/* Accept validated decoder output. A missing/palm/UP contact emits an explicit
 * lift at the last DOWN coordinates, with the same ID and Contact Count=1. */
int SwBasicInput(SW_BASIC_STATE *state, const unsigned char *decoded);
int SwBasicRelease(SW_BASIC_STATE *state);
const unsigned char *SwBasicPeek(const SW_BASIC_STATE *state);
/* Consume only after the HID caller has successfully copied the front report. */
void SwBasicConsume(SW_BASIC_STATE *state);
#endif
