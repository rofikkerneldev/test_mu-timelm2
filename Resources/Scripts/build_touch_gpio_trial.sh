#!/usr/bin/env bash
set -euo pipefail
repo="$(cd -- "$(dirname -- "$0")/../.." && pwd)"
cd "$repo"
expected="$(git ls-tree HEAD Mu_Basecore | awk '{print $3}')"
[[ "$(git -C Mu_Basecore rev-parse HEAD)" == "$expected" ]]
output="$repo/Build/TouchGpio"
mkdir -p "$output"
if [[ -n "${TIMELM_TOUCH_DSDT_SNAPSHOT:-}" && -n "${TIMELM_TOUCH_SSDT_SNAPSHOT:-}" ]]; then
  python3 Resources/Scripts/generate_touch_enumeration.py "$output" --gpio --snapshot \
    "$TIMELM_TOUCH_DSDT_SNAPSHOT" "$TIMELM_TOUCH_SSDT_SNAPSHOT"
elif [[ -z "${TIMELM_TOUCH_DSDT_SNAPSHOT:-}" && -z "${TIMELM_TOUCH_SSDT_SNAPSHOT:-}" ]]; then
  python3 Resources/Scripts/generate_touch_enumeration.py "$output" --gpio --snapshot \
    Resources/Tests/TouchGpio/DSDT-952.aml Resources/Tests/TouchGpio/SSDT-451.aml
else
  echo 'Set both TIMELM_TOUCH_DSDT_SNAPSHOT and TIMELM_TOUCH_SSDT_SNAPSHOT, or neither.' >&2
  exit 2
fi
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
  -I Mu_Basecore/MdePkg/Include -I Mu_Basecore/MdePkg/Include/AArch64 -I "$output" \
  -DTIMELM_TOUCH_GPIO_TRIAL "-DTIMELM_WINDOWS_SIZE=${reference[0]}u" "-DTIMELM_WINDOWS_CRC32=${reference[1]}u" \
  -c Platforms/LG/timelmPkg/Applications/TouchEnumeration/TouchEnumeration.c \
  -o "$output/TouchEnumeration.obj"
lld-link /machine:arm64 /subsystem:efi_application /entry:TouchEnumerationEntry \
  /nodefaultlib /out:"$output/TouchGpioOnce.efi" "$output/TouchEnumeration.obj"
python3 Resources/Scripts/record_touch_source.py --component launcher --output "$output/source-inputs.json"
python3 - "$output" <<'PY'
from pathlib import Path
import hashlib,json,struct,subprocess,sys
out=Path(sys.argv[1]); data=(out/'TouchGpioOnce.efi').read_bytes()
pe=struct.unpack_from('<I',data,0x3c)[0]
assert data[pe:pe+4] == b'PE\0\0' and struct.unpack_from('<H',data,pe+4)[0] == 0xaa64
assert struct.unpack_from('<H',data,pe+24+68)[0] == 10
assert struct.unpack_from('<II',data,pe+24+112+8) == (0,0)
meta=dict(commit=subprocess.check_output(['git','rev-parse','HEAD'],text=True).strip(),
    size=len(data),sha256=hashlib.sha256(data).hexdigest(),architecture='ARM64',
    subsystem='EFI application',imports=[],probe_version=1,
    log='timelm-touch-gpio.txt',restores_windows_first=True,windows_chainload=True,
    smmu_access=False,iort_installed=False,usb_requests=False,clock_requests=False,persistent_acpi=False,
    requires_no_matching_drivers=False,gpio_touch_trial=True,bbtrial=True,
    ssdt_sha256=hashlib.sha256((out/'TouchGpio.aml').read_bytes()).hexdigest(),
    windows_reference=json.load(open('Platforms/LG/timelmPkg/Applications/I2cClockDiag/WindowsBootReference.json')))
meta['source']=json.loads((out/'source-inputs.json').read_text())
meta['dsdt_sha256']='b759e921e4224158834b5867a456ab988a49d5f900ee90d2b77ed984d9a6c5fe'
meta['dsdt_mode']='live-snapshot-952'
(out/'touch-gpio.json').write_text(json.dumps(meta,indent=2)+'\n')
print(json.dumps(meta,indent=2))
PY
