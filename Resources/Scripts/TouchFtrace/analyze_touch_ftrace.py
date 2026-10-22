#!/usr/bin/env python3
"""Analyses the ftrace capture of the touch chip.

The maintainer of the G8 touch gets everything the chip needs from the trace.
This script turns such a capture into a register map and an init sequence, so
that the Windows side does not have to guess them.

    python3 analyze_touch_ftrace.py /sdcard/touch-ftrace

The result is written next to the capture:

    touch-ftrace.json    the transfers, the register map, the init sequence
    touch-ftrace.md      the same as a short readable report

Two kinds of trace lines are understood:

    i2c-2 #0 a=028 f=0000 l=2 [00 12]     the format of the vendor kernel
    i2c_write: addr=0028 flags=0 len=2 ... the format of the mainline kernel

The line of the vendor kernel has the number of the adapter in it, that
matters because two chips of the phone sit at the same address: the touch
chip is on the adapter of the GENI bus, the other one is on another bus.
"""

from __future__ import annotations

import argparse
import json
import re
from pathlib import Path

DEFAULT_ADDRESS = 0x28

# i2c-2 #0 a=028 f=0000 l=2 [00 12]
RE_VENDOR = re.compile(
    r"i2c-(?P<adapter>\d+)\s+#(?P<msg>\d+)\s+a=(?P<addr>[0-9a-fA-F]+)"
    r"\s+f=(?P<flags>[0-9a-fA-F]+)\s+l=(?P<len>\d+)\s*\[(?P<buf>[0-9a-fA-F ]*)\]"
)

# i2c_write: pid=1234 comm=foo addr=0028 flags=0 len=4 buf=00 12 34 56
RE_MAINLINE = re.compile(
    r"\baddr=(?P<addr>[0-9a-fA-F]+)"
    r"(?:.*?\blen=(?P<len>\d+))?"
    r"(?:.*?\bbuf=(?P<buf>[0-9a-fA-F][0-9a-fA-F ]*))?"
)

RE_OP = re.compile(r"\b(i2c_write|i2c_read|i2c_reply|i2c_result|i2c_smbus_[a-z_]+)\b")
RE_ADDR = re.compile(r"\baddr=([0-9a-fA-F]+)")
RE_LEN = re.compile(r"\blen=(\d+)")
RE_BUF = re.compile(r"\bbuf=([0-9a-fA-F][0-9a-fA-F ]*)")

# dmesg of the driver, for example
#   sw42902: write reg 0x00a0 = 0x03
#   sw42902: chip id b3w68, reg 0x00 = 0x01
RE_REG = re.compile(r"\breg(?:ister)?\s*[:=]?\s*(0x[0-9a-fA-F]+)")
RE_VAL = re.compile(r"\bval(?:ue)?\s*[:=]?\s*(0x[0-9a-fA-F]+)")
RE_ID = re.compile(r"\b(?:chip\s*id|product\s*id|chip_id)\s*[:=]?\s*(0x[0-9a-fA-F]+)")


def parse_bytes(text: str) -> list[int]:
    """Turns '00 12 ab' or '0012ab' into a list of bytes."""
    cleaned = "".join(text.split())
    if len(cleaned) % 2:
        cleaned = cleaned[:-1]
    try:
        return [int(cleaned[i:i + 2], 16) for i in range(0, len(cleaned), 2)]
    except ValueError:
        return []


def read_lines(path: Path) -> list[str]:
    if not path.exists():
        return []
    return path.read_text(errors="replace").splitlines()


def parse_trace(lines: list[str], address: int, adapter: int | None) -> list[dict]:
    """Collects the transfers of the touch chip."""
    transfers: list[dict] = []
    for line in lines:
        match = RE_OP.search(line)
        if not match:
            continue

        entry: dict = {
            "op": match.group(1),
            "adapter": None,
            "address": None,
            "length": 0,
            "bytes": [],
            "raw": line.strip(),
        }

        vendor = RE_VENDOR.search(line)
        if vendor:
            entry["adapter"] = int(vendor.group("adapter"))
            entry["address"] = int(vendor.group("addr"), 16)
            entry["length"] = int(vendor.group("len"))
            entry["bytes"] = parse_bytes(vendor.group("buf"))
            entry["flags"] = int(vendor.group("flags"), 16)
        else:
            addr_match = RE_ADDR.search(line)
            if not addr_match:
                continue
            entry["address"] = int(addr_match.group(1), 16)
            length_match = RE_LEN.search(line)
            if length_match:
                entry["length"] = int(length_match.group(1))
            buf_match = RE_BUF.search(line)
            if buf_match:
                entry["bytes"] = parse_bytes(buf_match.group(1))
            if not entry["length"]:
                entry["length"] = len(entry["bytes"])

        if entry["address"] != address:
            continue
        if adapter is not None and entry["adapter"] is not None and entry["adapter"] != adapter:
            continue

        transfers.append(entry)
    return transfers


def parse_dmesg(lines: list[str]) -> tuple[list[dict], list[str]]:
    """Collects the register writes of the driver out of the kernel log."""
    writes: list[dict] = []
    ids: list[str] = []
    for line in lines:
        id_match = RE_ID.search(line)
        if id_match and id_match.group(1) not in ids:
            ids.append(id_match.group(1))
        reg_match = RE_REG.search(line)
        if not reg_match:
            continue
        val_match = RE_VAL.search(line)
        try:
            reg = int(reg_match.group(1), 16)
        except ValueError:
            continue
        value = None
        if val_match:
            try:
                value = int(val_match.group(1), 16)
            except ValueError:
                value = None
        writes.append({"register": reg, "value": value, "raw": line.strip()})
    return writes, ids


def guess_address_width(transfers: list[dict]) -> int:
    """8 bit or 16 bit register address, decided by the length of the writes."""
    lengths = [
        t["length"]
        for t in transfers
        if t["op"] in ("i2c_write", "i2c_smbus_write") and t["length"] > 0
    ]
    if not lengths:
        return 0
    # a write of one byte carries no register, two bytes carry an 8 bit
    # register, three bytes carry a 16 bit register
    if min(lengths) >= 3:
        return 16
    if min(lengths) == 2:
        return 8
    return 0


def split_register(data: list[int], width: int) -> tuple[int, list[int]] | None:
    if width == 8:
        if len(data) < 2:
            return None
        return data[0], data[1:]
    if width == 16:
        if len(data) < 3:
            return None
        return (data[0] << 8) | data[1], data[2:]
    return None


def build_register_map(transfers: list[dict], width: int) -> dict:
    """The register map out of the writes, the last value of a register wins."""
    registers: dict[str, dict] = {}
    if width == 0:
        return registers
    for transfer in transfers:
        if transfer["op"] not in ("i2c_write", "i2c_smbus_write"):
            continue
        parts = split_register(transfer["bytes"], width)
        if parts is None:
            continue
        reg, value = parts
        key = f"0x{reg:04x}"
        entry = registers.setdefault(key, {"writes": 0, "reads": 0, "values": []})
        entry["writes"] += 1
        if value and value not in entry["values"]:
            entry["values"].append(value)
    return registers


def build_init_sequence(transfers: list[dict], width: int) -> list[dict]:
    """The order of the writes, the first write of a register is the init."""
    sequence: list[dict] = []
    seen: set[str] = set()
    if width == 0:
        return sequence
    for transfer in transfers:
        if transfer["op"] not in ("i2c_write", "i2c_smbus_write"):
            continue
        parts = split_register(transfer["bytes"], width)
        if parts is None:
            continue
        reg, value = parts
        key = f"0x{reg:04x}"
        if key in seen:
            continue
        seen.add(key)
        sequence.append(
            {
                "register": key,
                "value": " ".join(f"{b:02x}" for b in value),
                "adapter": transfer.get("adapter"),
                "raw": transfer["raw"],
            }
        )
    return sequence


def read_lengths(transfers: list[dict]) -> list[int]:
    lengths: list[int] = []
    for transfer in transfers:
        if transfer["op"] in ("i2c_read", "i2c_smbus_read"):
            if transfer["length"] not in lengths:
                lengths.append(transfer["length"])
    return sorted(lengths)


def write_sequences(transfers: list[dict]) -> list[dict]:
    """Every write of the chip, in the order it happened."""
    result: list[dict] = []
    for transfer in transfers:
        if transfer["op"] not in ("i2c_write", "i2c_smbus_write"):
            continue
        result.append(
            {
                "adapter": transfer.get("adapter"),
                "length": transfer["length"],
                "bytes": " ".join(f"{b:02x}" for b in transfer["bytes"]),
                "raw": transfer["raw"],
            }
        )
    return result


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("capture", help="the folder of the capture or the trace file")
    parser.add_argument("--address", default=hex(DEFAULT_ADDRESS), help="the address of the chip")
    parser.add_argument("--adapter", default=None, type=int, help="only this i2c adapter")
    parser.add_argument("--out", default=None, help="where the report is written")
    args = parser.parse_args()

    capture = Path(args.capture)
    if capture.is_dir():
        trace_path = capture / "trace.txt"
        dmesg_path = capture / "dmesg.txt"
        out_dir = Path(args.out) if args.out else capture
    else:
        trace_path = capture
        dmesg_path = capture.with_name("dmesg.txt")
        out_dir = Path(args.out) if args.out else capture.parent

    address = int(args.address, 0)

    trace_lines = read_lines(trace_path)
    dmesg_lines = read_lines(dmesg_path)

    transfers = parse_trace(trace_lines, address, args.adapter)
    dmesg_writes, chip_ids = parse_dmesg(dmesg_lines)

    width = guess_address_width(transfers)
    registers = build_register_map(transfers, width)
    sequence = build_init_sequence(transfers, width)
    lengths = read_lengths(transfers)
    writes = write_sequences(transfers)

    adapters: dict[str, int] = {}
    for transfer in transfers:
        key = str(transfer.get("adapter"))
        adapters[key] = adapters.get(key, 0) + 1

    report = {
        "capture": str(capture),
        "trace": str(trace_path),
        "address": f"0x{address:02x}",
        "adapter_filter": args.adapter,
        "adapters": adapters,
        "chip_ids": chip_ids,
        "register_address_bits": width,
        "transfer_count": len(transfers),
        "write_count": len(writes),
        "read_lengths": lengths,
        "registers": registers,
        "init_sequence": sequence,
        "writes": writes,
        "transfers": transfers,
        "dmesg_register_writes": dmesg_writes,
    }

    out_dir.mkdir(parents=True, exist_ok=True)
    json_path = out_dir / "touch-ftrace.json"
    json_path.write_text(json.dumps(report, indent=2) + "\n")

    md: list[str] = []
    md.append("# Touch chip ftrace report")
    md.append("")
    md.append(f"- capture : {capture}")
    md.append(f"- address : 0x{address:02x}")
    md.append(f"- transfers : {len(transfers)}")
    md.append(f"- writes : {len(writes)}")
    md.append(
        f"- register address : {width} bit" if width else "- register address : unknown"
    )
    if adapters:
        md.append(
            "- adapters : "
            + ", ".join(f"{key} ({count})" for key, count in sorted(adapters.items()))
        )
    if chip_ids:
        md.append(f"- chip id in the log : {', '.join(chip_ids)}")
    if lengths:
        md.append(f"- length of the read reports : {', '.join(str(x) for x in lengths)}")
    md.append("")
    md.append("## Registers")
    md.append("")
    if registers:
        md.append("| register | writes | values |")
        md.append("| --- | --- | --- |")
        for key, entry in sorted(registers.items()):
            values = " ".join(
                " ".join(f"{b:02x}" for b in value) for value in entry["values"]
            )
            md.append(f"| {key} | {entry['writes']} | {values} |")
    else:
        md.append("No register was found, the trace has no write of the chip.")
    md.append("")
    md.append("## Init sequence")
    md.append("")
    if sequence:
        md.append("| order | register | value |")
        md.append("| --- | --- | --- |")
        for index, item in enumerate(sequence, start=1):
            md.append(f"| {index} | {item['register']} | {item['value']} |")
    else:
        md.append("No init sequence was found.")
    md.append("")
    md.append("## All writes")
    md.append("")
    if writes:
        md.append("| adapter | len | bytes |")
        md.append("| --- | --- | --- |")
        for item in writes:
            md.append(f"| {item['adapter']} | {item['length']} | {item['bytes']} |")
    else:
        md.append("No write was found.")
    md.append("")
    if dmesg_writes:
        md.append("## Register writes in the log of the kernel")
        md.append("")
        md.append("```")
        for item in dmesg_writes:
            md.append(item["raw"])
        md.append("```")
        md.append("")
    md_path = out_dir / "touch-ftrace.md"
    md_path.write_text("\n".join(md) + "\n")

    print(f"transfers      : {len(transfers)}")
    print(f"writes         : {len(writes)}")
    print(f"register width : {width} bit")
    print(f"registers      : {len(registers)}")
    print(f"read lengths   : {lengths}")
    print(f"adapters       : {adapters}")
    print(f"report         : {md_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
