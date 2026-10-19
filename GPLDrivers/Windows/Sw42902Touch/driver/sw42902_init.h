/* SPDX-License-Identifier: GPL-3.0-or-later
 * Split scan preparation from device interrupt enable. The Windows adapter
 * invokes Start only from D0EntryPostInterruptsEnabled. */
#ifndef SW42902_INIT_H
#define SW42902_INIT_H
typedef int (*SW_WRITE)(void *, unsigned, unsigned);
typedef void (*SW_DELAY)(void *, unsigned);
static int Sw42902PrepareScan(void *context, SW_WRITE write, SW_DELAY delay)
{
    if (!write(context,0xfe4,0) || !write(context,0xc00,1) ||
        !write(context,0xc01,0) || !write(context,0xf30,0) || !write(context,0xc03,4)) return 0;
    delay(context,30);
    return 1;
}
static int Sw42902StartScan(void *context, SW_WRITE write)
{
    if (!write(context,0xc01,1)) return 0;
    if (!write(context,0xc03,0x8303)) {
        (void)write(context,0xc01,0);
        return 0;
    }
    return 1;
}
#endif
