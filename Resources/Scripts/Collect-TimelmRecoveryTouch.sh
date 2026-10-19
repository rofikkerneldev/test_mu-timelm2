#!/system/bin/sh
# Read board facts and known SW42902 registers via the kernel I2C adapter.
# No GPIO/clock/PMIC writes, raw MMIO, scanning, firmware upload or reboot.
set -eu
out=${1:?Provide a new /tmp/timelm-touch-* output directory}
case "$out" in /tmp/timelm-touch-*) ;; *) echo 'Unexpected output path' >&2; exit 2;; esac
[ "$(id -u)" = 0 ] || { echo 'Root Recovery required' >&2; exit 2; }
[ ! -e "$out" ] || { echo 'Output already exists' >&2; exit 2; }
[ "$(cat /sys/bus/i2c/devices/2-0028/name)" = sw42902 ] || {
    echo 'Unexpected bus/address binding' >&2; exit 2;
}
[ "$(readlink -f /sys/bus/i2c/devices/2-0028/of_node)" = /sys/firmware/devicetree/base/soc/i2c@a94000/sw42902 ] || {
    echo 'Unexpected controller binding' >&2; exit 2;
}
mkdir "$out"
touch=/sys/devices/virtual/input/lge_touch
for name in version gpio_pin platform_data secure_touch_enable; do
    cat "$touch/$name" > "$out/$name.txt" 2>&1 || true
done
getevent -lp > "$out/input-capabilities.txt" 2>&1 || true
cat /proc/interrupts > "$out/interrupts-before.txt"
if [ "$(cat "$touch/secure_touch_enable")" != 0 ]; then
    echo 'Secure touch is active; raw reads skipped' > "$out/skipped.txt"
    exit 0
fi
i=0
while [ "$i" -lt 3 ]; do
    i2ctransfer -y 2 w2@0x28 0x26 0x44 r8 >> "$out/product-reads.txt" 2>> "$out/i2c-errors.txt"
    i=$((i+1))
done
cat /proc/interrupts > "$out/interrupts-after-product.txt"
if [ "${2:-}" = --packets ]; then
    echo 'Ready for a 15-second swipe capture'
    i=0
    while [ "$i" -lt 60 ]; do
        i2ctransfer -y 2 w2@0x28 0x26 0x00 r156 >> "$out/packets.txt" 2>> "$out/i2c-errors.txt"
        i=$((i+1))
        sleep 0.25
    done
fi
cat /proc/interrupts > "$out/interrupts-after.txt"
dmesg -S > "$out/dmesg.txt" 2>&1 || true
echo "Saved $out"
