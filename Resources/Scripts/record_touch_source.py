#!/usr/bin/env python3
"""Record exact component inputs, including a dirty-tree digest when applicable."""
from pathlib import Path
from datetime import datetime, timezone
import argparse, hashlib, json, platform, subprocess

p=argparse.ArgumentParser()
p.add_argument('--component',choices=['host','touch','gpio','launcher','helpers'],required=True)
p.add_argument('--output',type=Path,required=True)
p.add_argument('--upstream-root',type=Path)
a=p.parse_args(); repo=Path(__file__).resolve().parents[2]
def git(*args, cwd=repo): return subprocess.check_output(['git',*args],cwd=cwd)
paths={
 'host':['GPLDrivers/Windows/KonaGeniI2c','Resources/DeviceOverlays/timelm/Drivers/KonaGPIO/TouchBus.h','Resources/Scripts/build_geni_i2c.ps1'],
 'touch':['GPLDrivers/Windows/Sw42902Touch','Resources/Scripts/build_sw42902_touch.ps1'],
 'gpio':['Resources/DeviceOverlays/timelm/Drivers/KonaGPIO','Resources/Scripts/build_kona_drivers.ps1'],
 'launcher':['Platforms/LG/timelmPkg/Applications/TouchEnumeration','Platforms/LG/timelmPkg/Applications/I2cClockDiag','Resources/Scripts/build_touch_gpio_trial.sh','Resources/Scripts/generate_touch_enumeration.py','Resources/Tests/TouchGpio'],
 'helpers':['Resources/Scripts/TouchGpio','Resources/Scripts/Collect-TimelmDiagnostics.ps1','Resources/Scripts/Invoke-ProbeProcess.ps1'],
}[a.component]+['Resources/Scripts/record_touch_source.py']
names=sorted(set(git('ls-files','-z','--',*paths).decode().strip('\0').split('\0'))-{''})
files=[dict(path=n,sha256=hashlib.sha256((repo/n).read_bytes()).hexdigest()) for n in names if (repo/n).is_file()]
diff=git('diff','--binary','HEAD','--',*paths)
record=dict(schema=2,component=a.component,commit=git('rev-parse','HEAD').decode().strip(),
    tree=git('rev-parse','HEAD^{tree}').decode().strip(),input_files=files,
    input_digest=hashlib.sha256(json.dumps(files,sort_keys=True,separators=(',',':')).encode()).hexdigest(),
    dirty_inputs=bool(diff),source_diff_sha256=hashlib.sha256(diff).hexdigest(),
    built_utc=datetime.now(timezone.utc).isoformat(),host_platform=platform.platform(),
    ci_run_id=__import__('os').environ.get('GITHUB_RUN_ID'),
    diagnostic_build_id=0x20261024,diagnostic_schema=2)
if a.upstream_root:
    record['upstream_commit']=git('rev-parse','HEAD',cwd=a.upstream_root).decode().strip()
    record['upstream_diff_sha256']=hashlib.sha256(git('diff','--binary','HEAD','--','src/GPIO',cwd=a.upstream_root)).hexdigest()
a.output.parent.mkdir(parents=True,exist_ok=True)
a.output.write_text(json.dumps(record,indent=2)+'\n',encoding='utf-8')
print(f"{a.component}: {record['commit']} inputs={len(files)} digest={record['input_digest']} dirty={bool(diff)}")
