/* SPDX-License-Identifier: MIT */
#include <assert.h>
#include <stdio.h>
#include "PinConfig.h"

int main(void)
{
    unsigned int original = 0xa5a5a5f1u;
    assert(KonaGpioPullValue(original, 0) == 0xa5a5a5f0u);
    assert(KonaGpioPullValue(original, 3) == 0xa5a5a5f3u);
    assert(KonaGpioPullValue(original, 1) == original);
    assert((KonaGpioPullValue(original, 3) & ~3u) == (original & ~3u));
    assert(KonaGpioIrqValue(0, 1, 0) == 0x0au); /* V60 falling edge */
    assert(KonaGpioIrqValue(0, 1, 1) == 0x06u); /* rising edge */
    assert(KonaGpioIrqValue(0, 0, 0) == 0x00u); /* active-low level */
    assert(KonaGpioIrqValue(0, 0, 1) == 0x02u); /* active-high level */
    assert((KonaGpioIrqValue(original, 1, 0) & ~0x0eu) == (original & ~0x0eu));
    assert((KonaGpioIrqValue(0xffffffffu, 0, 0) & 0x0eu) == 0);
    original = KonaGpioIrqValue(0xa5a5a5f1u, 1, 0);
    assert((KonaGpioMaskValue(original, 1) & 0x11u) == 0x10u);
    assert((KonaGpioMaskValue(original, 0) & 0x11u) == 0x11u);
    assert((KonaGpioMaskValue(original, 1) & 0x0eu) == 0x0au);
    for (unsigned int low = 0; low < 0x400u; ++low) {
        unsigned int value = 0xa5a58000u | low;
        unsigned int released = KonaGpioOpenDrainValue(value, 1);
        unsigned int driven = KonaGpioOpenDrainValue(value, 0);
        assert((released & 0x3ffu) == 0);
        assert((driven & 0x3ffu) == 0x200u);
        assert((released & ~0x3ffu) == (value & ~0x3ffu));
        assert((driven & ~0x3ffu) == (value & ~0x3ffu));
        assert(KonaGpioRestoreValue(released, value) == value);
        assert((KonaGpioLowLatchValue(value) & 2u) == 0);
        assert((KonaGpioLowLatchValue(value) & ~2u) == (value & ~2u));
    }
    puts("Kona GPIO pull/edge/mask register tests passed");
    return 0;
}
