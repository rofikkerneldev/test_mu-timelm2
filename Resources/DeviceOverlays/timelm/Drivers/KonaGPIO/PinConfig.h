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

/* GPIO open drain is emulated by OUT=0 with output-enable only for LOW.
 * Drive=2mA, no pull, GPIO mux=0; preserve fields above bit nine. */
static unsigned int KonaGpioOpenDrainValue(unsigned int value, int released)
{
    return (value & ~0x3ffu) | (released ? 0u : 0x200u);
}
static unsigned int KonaGpioLowLatchValue(unsigned int value)
{
    return value & ~2u; /* IN bit zero is read-only; preserve all other fields. */
}
static unsigned int KonaGpioRestoreValue(unsigned int value, unsigned int saved)
{
    return (value & ~0x3ffu) | (saved & 0x3ffu);
}
#endif
