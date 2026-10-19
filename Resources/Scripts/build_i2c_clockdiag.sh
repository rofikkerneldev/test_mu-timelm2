#!/usr/bin/env bash
set -euo pipefail
repo="$(cd -- "$(dirname -- "$0")/../.." && pwd)"
cd "$repo"
expected="$(git ls-tree HEAD Mu_Basecore | awk '{print $3}')"
actual="$(git -C Mu_Basecore rev-parse HEAD)"
if [[ "$expected" != "$actual" ]]; then
  printf 'Initialize the pinned Mu_Basecore first: git submodule update --init --depth 1 Mu_Basecore\n' >&2
  exit 1
fi
output="$repo/Build/I2cClockDiag"
mkdir -p "$output"
clang --target=aarch64-pc-windows-msvc -O2 -ffreestanding -fshort-wchar \
  -fno-stack-protector -fno-builtin -Wall -Wextra -Werror \
  -I Mu_Basecore/MdePkg/Include -I Mu_Basecore/MdePkg/Include/AArch64 \
  -I Silicon/Qualcomm/QcomPkg/Include \
  -c Platforms/LG/timelmPkg/Applications/I2cClockDiag/I2cClockDiag.c \
  -o "$output/I2cClockDiag.obj"
lld-link /machine:arm64 /subsystem:efi_application /entry:I2cClockDiagEntry \
  /nodefaultlib /out:"$output/I2cClockDiag.efi" "$output/I2cClockDiag.obj"
python3 - "$output" <<'PY'
from pathlib import Path
import hashlib, json, struct, subprocess, sys
out = Path(sys.argv[1])
data = (out / 'I2cClockDiag.efi').read_bytes()
pe = struct.unpack_from('<I', data, 0x3c)[0]
assert data[pe:pe+4] == b'PE\0\0'
assert struct.unpack_from('<H', data, pe+4)[0] == 0xaa64
assert struct.unpack_from('<H', data, pe+24+68)[0] == 10  # EFI application
# No CRT/OS imports: runs directly under UEFI, not Windows.
assert struct.unpack_from('<II', data, pe+24+112+8) == (0, 0)
metadata = {'sha256': hashlib.sha256(data).hexdigest(), 'size': len(data),
    'architecture': 'ARM64', 'subsystem': 'EFI application', 'imports': [],
    'commit': subprocess.check_output(['git','rev-parse','HEAD'], text=True).strip(),
    'purpose': 'read-only clock protocol query; no direct MMIO'}
(out / 'source.json').write_text(json.dumps(metadata, indent=2))
print(json.dumps(metadata))
PY
