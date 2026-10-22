#!/bin/sh
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
# The script runs on a phone with Android and on a recovery of AOSP:
#
#     sh capture_touch_ftrace.sh [output folder] [seconds] [module]
#
# The shell of a recovery of AOSP is mksh, it has no arrays and no bash, so
# the script stays in the plain POSIX shell.  The find of toybox has no
# -printf either, the list of the trace points is made with the glob of the
# shell.
#
# The third argument is optional.  It is the name of the module of the touch
# driver, the module is unloaded and loaded again while the trace runs, so
# that the sequence of the probe of the driver is in the trace as well.  A
# recovery has no modules, there the argument is left out.
#
# The third argument can also be a rebind of the i2c device of the touch:
#
#     sh capture_touch_ftrace.sh /data/local/tmp/touch-probe 15 rebind:2-0028
#
# The device is unbound from its driver and bound again, that is the probe of
# the driver again, so the sequence of the init of the chip is in the trace.
# The device of the touch of the LG V60 is 2-0028 on the adapter of the GENI
# bus.  The other chip at the same address, 0-0028, is the NFC of Sony.
#
# A rebind of the touch is dangerous.  The driver of LG registers a platform
# device with a fixed name, the second probe fails with a duplicate name and
# the kernel of the phone crashed with it.  Only do it with a phone that can
# be flashed again.
#
# Examples:
#
#     sh capture_touch_ftrace.sh
#     sh capture_touch_ftrace.sh /data/local/tmp/touch-ftrace 90
#     sh capture_touch_ftrace.sh /data/local/tmp/touch-ftrace 30 sw42902
#     sh capture_touch_ftrace.sh /data/local/tmp/touch-probe 15 rebind:2-0028
#
# The trace points of the i2c bus are needed.  If the kernel has none, the
# script says so, the trace of the kernel is still saved.
#
set -eu

output="${1:-/data/local/tmp/touch-ftrace}"
seconds="${2:-60}"
module="${3:-}"

#
# The address of the touch chip.  Every transfer of it is interesting, the
# transfers of the other devices of the bus are only kept as context.
#
touch_address="0x28"

if [ "$(id -u)" != "0" ]; then
    echo "this script has to run as root" >&2
    exit 1
fi

#
# The tracefs of the kernel.  It is often there but not mounted yet, in a
# recovery of AOSP it usually has to be mounted by hand.
#
tracefs=""
for candidate in /sys/kernel/tracing /sys/kernel/debug/tracing; do
    if [ -e "$candidate/trace" ]; then
        tracefs="$candidate"
        break
    fi
    if [ -d "$candidate" ]; then
        if mount -t tracefs nodev "$candidate" 2>/dev/null; then
            if [ -e "$candidate/trace" ]; then
                tracefs="$candidate"
                break
            fi
        fi
    fi
done

if [ -z "$tracefs" ]; then
    echo "tracefs was not found, the kernel has no tracefs" >&2
    exit 1
fi

mkdir -p "$output"

echo "tracefs          : $tracefs"
echo "output           : $output"
echo "touch address    : $touch_address"
echo "duration         : ${seconds}s"

if [ -n "$module" ]; then
    echo "module to reload : $module"
fi

#
# The list of the trace points that exist.  The i2c trace points are the
# important ones, a driver of the chip often has its own trace points with
# the register writes in them.
#
events="$tracefs/events"
: > "$output/events-available.txt"
if [ -d "$events" ]; then
    for group in "$events"/*; do
        [ -d "$group" ] || continue
        group_name="${group##*/}"
        for event in "$group"/*; do
            [ -d "$event" ] || continue
            printf '%s/%s\n' "$group_name" "${event##*/}" >> "$output/events-available.txt"
        done
    done
    sort "$output/events-available.txt" -o "$output/events-available.txt" 2>/dev/null || true
fi

#
# The trace points that are switched on.  They are kept in a file, the plain
# shell has no arrays.
#
selected="$output/events-selected.txt"
: > "$selected"

for event in \
    i2c/i2c_write \
    i2c/i2c_read \
    i2c/i2c \
    i2c/i2c_smbus_write \
    i2c/i2c_smbus_read \
    i2c/i2c_smbus_write_byte \
    i2c/i2c_smbus_write_byte_data \
    i2c/i2c_smbus_write_word_data \
    i2c/i2c_smbus_read_byte \
    i2c/i2c_smbus_read_byte_data \
    i2c/i2c_smbus_read_word_data \
    i2c/i2c_smbus_write_i2c_block_data \
    irq/irq_handler_entry \
    irq/irq_handler_exit
do
    if [ -d "$events/$event" ]; then
        printf '%s\n' "$event" >> "$selected"
    fi
done

#
# The trace points of the driver of the chip, they often carry the register
# writes with a readable name.
#
while read -r event; do
    [ -n "$event" ] || continue
    case "$event" in
        i2c/*|irq/*|power/*|sched/*|block/*|mmc/*|ext4/*|f2fs/*) continue ;;
    esac
    case "$event" in
        *touch*|*sw42902*|*b3w68*|*fts*|*hid*|*goodix*|*synaptics*|*input*)
            printf '%s\n' "$event" >> "$selected"
            ;;
    esac
done < "$output/events-available.txt"

#
# The list of the trace points is kept plain in the file events-selected.txt,
# the loops below read it.
#
if ! grep -q '^i2c/' "$selected" 2>/dev/null; then
    echo ""
    echo "the kernel has no i2c trace point, the register map of the chip"
    echo "cannot be read from a trace on this kernel"
fi

#
# A bigger buffer, the sequence of the probe of the driver can be long.
#
echo 8192 > "$tracefs/buffer_size_kb" 2>/dev/null || true

while read -r event; do
    [ -n "$event" ] || continue
    echo 1 > "$events/$event/enable" 2>/dev/null || true
done < "$selected"

echo 1 > "$tracefs/tracing_on" 2>/dev/null || true

#
# The probe of the driver is the interesting part, the module is loaded again
# or the i2c device is bound again while the trace runs.
#
if [ -n "$module" ]; then
    case "$module" in
        rebind:*)
            device="${module#rebind:}"
            device_path="/sys/bus/i2c/devices/$device"
            echo ""
            echo "WARNING: a rebind of the touch crashed the kernel of this phone."
            echo "         The driver of LG registers a platform device with a fixed"
            echo "         name, the second probe fails with a duplicate name."
            if [ -d "$device_path" ]; then
                driver_link=$(readlink "$device_path/driver" 2>/dev/null || true)
                driver_name="${driver_link##*/}"
                echo ""
                echo "the device $device is bound again, the sequence of the probe is in the trace"
                if [ -n "$driver_name" ]; then
                    echo "$device" > "/sys/bus/i2c/drivers/$driver_name/unbind" 2>/dev/null || true
                    sleep 1
                    echo "$device" > "/sys/bus/i2c/drivers/$driver_name/bind" 2>/dev/null || true
                fi
            else
                echo ""
                echo "the device $device is not there, the sequence of the probe is not in the trace"
            fi
            ;;
        *)
            if [ -d "/sys/module/$module" ]; then
                echo ""
                echo "the module $module is loaded again, the sequence of the probe is in the trace"
                rmmod "$module" 2>/dev/null || true
                sleep 1
                modprobe "$module" 2>/dev/null || insmod "$module.ko" 2>/dev/null || true
            else
                echo ""
                echo "the module $module is not loaded, the sequence of the probe is not in the trace"
            fi
            ;;
    esac
fi

echo ""
echo "tracing is running for ${seconds}s, touch the screen now"
sleep "$seconds"

echo 0 > "$tracefs/tracing_on" 2>/dev/null || true

while read -r event; do
    [ -n "$event" ] || continue
    echo 0 > "$events/$event/enable" 2>/dev/null || true
done < "$selected"

#
# The trace of the buffer and the kernel log.  The log of the driver often
# has the chip id and the register writes in a readable form.
#
cp "$tracefs/trace" "$output/trace.txt" 2>/dev/null || true

#
# The plain dmesg of a recovery of AOSP reads nothing, the option -S of the
# dmesg of toybox reads the buffer of the kernel instead.  The file /proc/kmsg
# is a stream, it would not end, so it is not used.
#
if ! dmesg -S > "$output/dmesg.txt" 2>/dev/null; then
    dmesg > "$output/dmesg.txt" 2>/dev/null || true
fi
if [ ! -s "$output/dmesg.txt" ]; then
    dmesg > "$output/dmesg.txt" 2>/dev/null || true
fi

#
# Only the lines of the touch chip, they are the interesting ones.
#
if [ -f "$output/trace.txt" ]; then
    grep -i -E "sw42902|b3w68|0x28|0028|touch" "$output/trace.txt" > "$output/trace-touch.txt" || true
fi

cat "$selected"

echo ""
echo "the capture is in $output"
echo "  trace.txt        : the raw trace of ftrace"
echo "  trace-touch.txt  : the lines with the touch chip"
echo "  dmesg.txt        : the log of the kernel"
echo ""
echo "analyse it with"
echo "  python3 analyze_touch_ftrace.py $output"
