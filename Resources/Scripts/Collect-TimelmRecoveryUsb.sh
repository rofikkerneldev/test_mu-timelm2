#!/system/bin/sh
# SPDX-License-Identifier: BSD-2-Clause-Patent
# Read-only USB/Type-C/input capture. Only output files under /tmp are written.
# Launch in Recovery before replacing the ADB cable with the OTG adapter.
trap '' HUP
out=${1:-/tmp/timelm-usb-capture}
samples=${2:-90}
case "$out" in /tmp/timelm-usb-*) ;; *) echo 'Output must be /tmp/timelm-usb-*' >&2; exit 2;; esac
case "$out" in *..*) echo 'Parent traversal is not allowed' >&2; exit 2;; esac
case "$samples" in ''|*[!0-9]*) echo 'Samples must be 1..150' >&2; exit 2;; esac
if [ "$samples" -lt 1 ] || [ "$samples" -gt 150 ]; then exit 2; fi
if [ -e "$out" ]; then echo 'Output already exists; preserve the previous capture' >&2; exit 2; fi
mkdir "$out" || exit 1
echo $$ > "$out/pid.txt"
exec > "$out/snapshots.txt" 2>&1
read_value() {
    if [ -r "$1" ]; then
        printf '%s=' "$1"
        cat "$1" 2>/dev/null
        printf '\n'
    fi
}
snapshot() {
    printf '\n--- sample %s; uptime ' "$1"
    cat /proc/uptime
    for base in /sys/class/power_supply/usb /sys/class/power_supply/pc_port /sys/class/power_supply/main /sys/class/power_supply/battery; do
        for attr in present online type real_type scope typec_mode typec_power_role typec_cc_orientation usb_otg otg_switch voltage_now current_now status; do
            read_value "$base/$attr"
        done
    done
    for base in /sys/class/typec/port*; do
        for attr in data_role power_role port_type power_operation_mode; do read_value "$base/$attr"; done
    done
    for base in /sys/class/dual_role_usb/*; do
        for attr in mode power_role data_role; do read_value "$base/$attr"; done
    done
    for base in /sys/class/usb_role/*; do read_value "$base/role"; done
    for base in /sys/class/extcon/extcon*; do read_value "$base/name"; read_value "$base/state"; done
    for base in /sys/bus/usb/devices/*; do
        for attr in idVendor idProduct product manufacturer busnum devnum speed authorized; do read_value "$base/$attr"; done
    done
    read_value /sys/devices/platform/soc/a600000.ssusb/mode
    read_value /sys/devices/platform/soc/a600000.ssusb/otg_state
    read_value /proc/bus/input/devices
}
uname -a > "$out/kernel.txt"
cat /proc/cmdline >> "$out/kernel.txt"
dmesg 2>&1 | tail -n 2000 > "$out/dmesg-before.txt"
if [ -r /proc/config.gz ] && command -v zcat >/dev/null 2>&1; then
    zcat /proc/config.gz 2>/dev/null | grep -E '^CONFIG_(USB|HID|TYPEC|EXTCON|INPUT_EVDEV|KEYBOARD)' > "$out/kernel-usb-config.txt"
fi
echo ready > "$out/ready.txt"
i=0
while [ "$i" -lt "$samples" ]; do
    snapshot "$i"
    if [ $((i % 5)) -eq 0 ]; then
        printf '\n--- dmesg at sample %s ---\n' "$i" >> "$out/dmesg-periodic.txt"
        dmesg 2>&1 | tail -n 150 >> "$out/dmesg-periodic.txt"
    fi
    i=$((i + 1))
    sleep 2
done
dmesg 2>&1 | tail -n 2000 > "$out/dmesg-after.txt"
echo complete > "$out/complete.txt"
