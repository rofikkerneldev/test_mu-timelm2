#!/usr/bin/env bash
#
# Captures the I2C traffic of the touch chip with ftrace.
#
# The tip of the maintainer of the G8 touch: everything the chip needs can
# be read from the trace.  The trace shows the bytes that really go over the
# bus, so the register map, the init sequence and the report format of the
# chip do not have to be guessed.
#
# The chip of the LG V60 is an SW42902 (product id B3W68TIM) on the GENI I2C
# bus at the address 0x28.  The script traces every transfer of that address
# and writes the raw trace next to the log of the kernel.
#
# Usage on the phone (Android, root):
#
#     su
#     sh capture_touch_ftrace.sh /sdcard/touch-ftrace
#
# The script stops after the given number of seconds (default 60).  Touch the
# screen while it runs.
#
set -euo pipefail

output="${1:-/sdcard/touch-ftrace}"
seconds="${2:-60}"

if [[ "$(id -u)" != "0" ]]; then
    echo "this script has to run as root" >&2
    exit 1
fi

tracefs=""
for candidate in /sys/kernel/tracing /sys/kernel/debug/tracing; do
    if [[ -d "$candidate" ]]; then
        tracefs="$candidate"
        break
    fi
done

if [[ -z "$tracefs" ]]; then
    echo "tracefs was not found, the kernel has no tracefs" >&2
    exit 1
fi

mkdir -p "$output"

#
# The address of the touch chip.  Every transfer of it is interesting, the
# transfers of the other devices of the bus are only kept as context.
#
touch_address="0x28"

echo "tracefs          : $tracefs"
echo "output           : $output"
echo "touch address    : $touch_address"
echo "duration         : ${seconds}s"

#
# Collect the list of the trace points that exist.  The i2c trace points are
# the important ones, a driver of the chip often has its own trace points
# with the register writes in them.
#
events="$tracefs/events"
: > "$output/events-available.txt"
if [[ -d "$events" ]]; then
    find "$events" -mindepth 2 -maxdepth 2 -type d \
        -printf '%P\n' 2>/dev/null | sort > "$output/events-available.txt" || true
fi

selected=()

for event in \
    i2c/i2c_write \
    i2c/i2c_read \
    i2c/i2c \
    i2c/i2c_smbus_write \
    i2c/i2c_smbus_read \
    i2c/i2c_smbus_write_byte \
    i2c/i2c_smbus_write_word_data \
    i2c/i2c_smbus_read_word_data \
    i2c/i2c_smbus_read_byte_data \
    irq/irq_handler_entry \
    irq/irq_handler_exit
do
    if [[ -d "$events/$event" ]]; then
        selected+=("$event")
    fi
done

#
# The trace points of the driver of the chip, they often carry the register
# writes with a readable name.
#
while read -r event; do
    case "$event" in
        i2c/*|irq/*|power/*|sched/*) continue ;;
    esac
    case "$event" in
        *touch*|*sw42902*|*b3w68*|*fts*|*hid*|*goodix*|*synaptics*)
            selected+=("$event")
            ;;
    esac
done < "$output/events-available.txt"

{
    echo "# the trace points that were enabled"
    for event in "${selected[@]:-}"; do
        [[ -n "$event" ]] && echo "$event"
    done
} > "$output/events-selected.txt"

for event in "${selected[@]:-}"; do
    [[ -n "$event" ]] || continue
    echo 1 > "$events/$event/enable" 2>/dev/null || true
done

echo 1 > "$tracefs/tracing_on" 2>/dev/null || true

echo ""
echo "tracing is running for ${seconds}s, touch the screen now"
sleep "$seconds"

echo 0 > "$tracefs/tracing_on" 2>/dev/null || true

for event in "${selected[@]:-}"; do
    [[ -n "$event" ]] || continue
    echo 0 > "$events/$event/enable" 2>/dev/null || true
done

#
# The trace of the buffer and the kernel log.  The log of the driver often
# has the chip id and the register writes in a readable form.
#
cp "$tracefs/trace" "$output/trace.txt" 2>/dev/null || true
dmesg > "$output/dmesg.txt" 2>/dev/null || true

#
# Only the lines of the touch chip, they are the interesting ones.
#
if [[ -f "$output/trace.txt" ]]; then
    grep -i -E "sw42902|b3w68|0x28|0028|touch" "$output/trace.txt" > "$output/trace-touch.txt" || true
fi

cat "$output/events-selected.txt"

echo ""
echo "the capture is in $output"
echo "  trace.txt        : the raw trace of ftrace"
echo "  trace-touch.txt  : the lines with the touch chip"
echo "  dmesg.txt        : the log of the kernel"
echo ""
echo "analyse it with"
echo "  python3 analyze_touch_ftrace.py $output"
