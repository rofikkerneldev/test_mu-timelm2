#!/usr/bin/env bash
set -euo pipefail
repo="$(cd -- "$(dirname -- "$0")/../.." && pwd)"
cd "$repo"
expected="$(git ls-tree HEAD Mu_Basecore | awk '{print $3}')"
[[ "$(git -C Mu_Basecore rev-parse HEAD)" == "$expected" ]]
output="$repo/Build/TouchDmaCheck"
mkdir -p "$output"
mapfile -t reference < <(python3 - <<'PY'
import json
r=json.load(open('Platforms/LG/timelmPkg/Applications/I2cClockDiag/WindowsBootReference.json'))
assert 4096 < r['size'] < 64*1024*1024
assert 0 <= int(r['crc32'],0) <= 0xffffffff
print(r['size']); print(int(r['crc32'],0))
PY
)
[[ ${#reference[@]} == 2 ]]
clang --target=aarch64-pc-windows-msvc -O2 -ffreestanding -fshort-wchar \
  -fno-stack-protector -fno-builtin -Wall -Wextra -Werror \
  -I Mu_Basecore/MdePkg/Include -I Mu_Basecore/MdePkg/Include/AArch64 \
  "-DTIMELM_WINDOWS_SIZE=${reference[0]}u" "-DTIMELM_WINDOWS_CRC32=${reference[1]}u" \
  -c Platforms/LG/timelmPkg/Applications/TouchDmaCheck/TouchDmaCheck.c \
  -o "$output/TouchDmaCheck.obj"
lld-link /machine:arm64 /subsystem:efi_application /entry:TouchDmaCheckEntry \
  /nodefaultlib /out:"$output/TouchDmaCheckOnce.efi" "$output/TouchDmaCheck.obj"
python3 - "$output" <<'PY'
from pathlib import Path
import hashlib,json,struct,subprocess,sys
out=Path(sys.argv[1]); data=(out/'TouchDmaCheckOnce.efi').read_bytes()
pe=struct.unpack_from('<I',data,0x3c)[0]
assert data[pe:pe+4] == b'PE\0\0' and struct.unpack_from('<H',data,pe+4)[0] == 0xaa64
assert struct.unpack_from('<H',data,pe+24+68)[0] == 10
assert struct.unpack_from('<II',data,pe+24+112+8) == (0,0)
meta=dict(commit=subprocess.check_output(['git','rev-parse','HEAD'],text=True).strip(),
    size=len(data),sha256=hashlib.sha256(data).hexdigest(),architecture='ARM64',
    subsystem='EFI application',imports=[],probe_version=1,
    log='timelm-touch-dma-check.txt',restores_windows_first=True,windows_chainload=True,
    smmu_read_only=True,usb_requests=False,clock_requests=False,persistent_acpi=False,
    windows_reference=json.load(open('Platforms/LG/timelmPkg/Applications/I2cClockDiag/WindowsBootReference.json')))
(out/'touch-dma-check.json').write_text(json.dumps(meta,indent=2)+'\n')
print(json.dumps(meta,indent=2))
PY
