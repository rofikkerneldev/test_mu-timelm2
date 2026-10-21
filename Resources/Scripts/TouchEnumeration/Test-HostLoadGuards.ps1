# Safe on a PC: static/manifest checks and the actual runner's first machine gate.
param([Parameter(Mandatory=$true)][string]$HostPackage)
$ErrorActionPreference='Stop'
if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') {throw 'Run this host-side test on the x64 build PC'}
foreach ($path in (Get-ChildItem -LiteralPath $PSScriptRoot -Filter '*.ps1' -File)) {
    $tokens=$null;$errors=$null
    [System.Management.Automation.Language.Parser]::ParseFile($path.FullName,[ref]$tokens,[ref]$errors) | Out-Null
    if ($errors) {throw ($errors | Out-String)}
}
$manifest=Get-Content (Join-Path $PSScriptRoot 'HostLoadPackage.json') -Raw | ConvertFrom-Json
foreach ($file in $manifest.files) {
    if ((Get-FileHash -LiteralPath (Join-Path $HostPackage $file.name)).Hash -ne $file.sha256) {throw 'Package mismatch'}
}
$inf=Get-Content -LiteralPath (Join-Path $HostPackage 'kona_geni.inf') -Raw
foreach ($name in @('NativeBoardInitEnabled','NativeGpiEnabled','WindowsIommuEnabled','FirmwareHandoffVerified','SourceClockHz')) {
    if ($inf -notmatch ('(?m)^HKR,,'+$name+',0x00010001,0\s*$')) {throw "Activation gate not zero: $name"}
}
if ($inf -notmatch '(?m)^StartType=3\s*$') {throw 'Host must not be a boot-start service'}
$certPath=Join-Path $HostPackage 'kona_geni.cer'
$cert=New-Object Security.Cryptography.X509Certificates.X509Certificate2($certPath)
if ($cert.Thumbprint -ne $manifest.certificate_thumbprint) {throw 'Certificate mismatch'}
$rejected=$false
try { & (Join-Path $PSScriptRoot 'Run-HostLoadProbe.ps1') }
catch {if ($_.Exception.Message -ne 'Wrong machine') {throw}; $rejected=$true}
if (!$rejected) {throw 'Host runner machine guard did not reject x64 PC'}
'PASS: PowerShell parser, pinned package, zero activation gates, demand-start service, certificate and PC rejection. No certificate import, clock change, install or shutdown executed.'
