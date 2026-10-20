/* SPDX-License-Identifier: MIT
 * PMIC arbiter command/packing/polling helpers used by the Windows driver.
 * Register-format facts checked against Linux v6.15 spmi-pmic-arb.c.
 */
#ifndef TIMELM_SPMI_TRANSACTION_H
#define TIMELM_SPMI_TRANSACTION_H

enum KONA_SPMI_RESULT { KonaSpmiDone, KonaSpmiDenied, KonaSpmiFailed, KonaSpmiTimeout };
typedef unsigned int (*KONA_SPMI_READ_STATUS)(void *context);
typedef void (*KONA_SPMI_DELAY)(void *context);

static int KonaSpmiCommand(unsigned int operation, unsigned int address,
    unsigned int length, unsigned int *command)
{
    if (!command || operation>1 || address>0xffff || !length || length>8 ||
        (address & 0xffu)+length>0x100u) return 0;
    *command=(operation<<27) | ((address & 0xffu)<<4) | (length-1u);
    return 1;
}
static unsigned int KonaSpmiPack(const unsigned char *data, unsigned int length)
{
    unsigned int value=0, i;
    for (i=0; i<length && i<4; ++i) value |= (unsigned int)data[i]<<(8u*i);
    return value;
}
static void KonaSpmiUnpack(unsigned int value, unsigned char *data, unsigned int length)
{
    unsigned int i;
    for (i=0; i<length && i<4; ++i) data[i]=(unsigned char)(value>>(8u*i));
}
static enum KONA_SPMI_RESULT KonaSpmiPoll(KONA_SPMI_READ_STATUS readStatus,
    KONA_SPMI_DELAY delay, void *context, unsigned int limit, unsigned int *raw)
{
    unsigned int i;
    *raw=0;
    for (i=0; i<limit; ++i) {
        *raw=readStatus(context);
        if (*raw & 4u) return KonaSpmiDenied;
        if (*raw & 10u) return KonaSpmiFailed;
        if (*raw & 1u) return KonaSpmiDone;
        if (i+1u<limit) delay(context);
    }
    return KonaSpmiTimeout;
}
#endif
