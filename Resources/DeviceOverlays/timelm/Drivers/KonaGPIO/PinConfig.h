/* SPDX-License-Identifier: MIT
 * TLMM register fields shared by the patched WDK driver and host tests.
 * Only the relevant fields are changed; unrelated drive/routing bits survive.
 */
#ifndef TIMELM_KONA_GPIO_PIN_CONFIG_H
#define TIMELM_KONA_GPIO_PIN_CONFIG_H

static unsigned int KonaGpioPullValue(unsigned int value, unsigned int pull)
{
    return (value & ~3u) | (pull & 3u);
}

static unsigned int KonaGpioIrqValue(unsigned int value, int edge, int high)
{
    value &= ~0x0eu; /* polarity bit 1, detection bits 3:2 */
    if (edge) {
        /* 01 = rising, 10 = falling; polarity is set for both edge modes. */
        value |= (high ? 1u : 2u) << 2;
        value |= 2u;
    } else if (high) {
        value |= 2u;
    }
    return value;
}

static unsigned int KonaGpioMaskValue(unsigned int value, int masked)
{
    /* RAW_STATUS stays enabled when masked, retaining a latched edge. */
    value |= 0x10u;
    return masked ? (value & ~1u) : (value | 1u);
}
#endif
