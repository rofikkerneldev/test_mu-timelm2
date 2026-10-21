# Safe parser/machine-guard checks on the build PC. Does not stage or install.
param([string]$Artifact)
$ErrorActionPreference = 'Stop'
if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') {throw 'Run this check on the x64 PC'}
foreach ($file in (Get-ChildItem -LiteralPath $PSScriptRoot -Filter '*.ps1' -File)) {
    $tokens = $null; $errors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($file.FullName,[ref]$tokens,[ref]$errors) | Out-Null
    if ($errors) {throw ($errors | Out-String)}
}
foreach ($runner in @('Launch-TouchGpioTrial.ps1','Run-TouchGpioTrial.ps1')) {
    $rejected = $false
    try {& (Join-Path $PSScriptRoot $runner)}
    catch {if ($_.Exception.Message -ne 'Wrong machine') {throw}; $rejected = $true}
    if (!$rejected) {throw "Runner did not reject the PC: $runner"}
}
# Exercise the actual gate writer against in-memory cmdlets only. Recreating an
# existing Device Parameters key could remove other values, so forbid it here.
$runnerPath = Join-Path $PSScriptRoot 'Run-TouchGpioTrial.ps1'
$tokens = $null; $errors = $null
$runnerAst = [System.Management.Automation.Language.Parser]::ParseFile($runnerPath,[ref]$tokens,[ref]$errors)
$writers = @($runnerAst.FindAll({param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Set-Gate'
},$true))
if ($writers.Count -ne 1) {throw 'Expected one production gate writer'}
& {
    param([string]$Definition)
    $state = @{exists=$true;created=0;values=@{ExistingProviderValue=17};badReadback=$false}
    function Test-Path {param([string]$LiteralPath) return $state.exists}
    function New-Item {
        param([string]$Path,[switch]$Force)
        if ($state.exists -or $Force) {throw 'Existing device key must not be recreated'}
        $state.exists = $true; $state.created++
    }
    function New-ItemProperty {
        param([string]$LiteralPath,[string]$Name,[int]$Value,[string]$PropertyType,[switch]$Force)
        if (!$state.exists -or $PropertyType -ne 'DWord' -or !$Force) {throw 'Invalid gate write'}
        $state.values[$Name] = $Value
    }
    function Get-ItemPropertyValue {
        param([string]$LiteralPath,[string]$Name)
        if ($state.badReadback) {return -1}
        return $state.values[$Name]
    }
    Invoke-Expression $Definition
    Set-Gate 'HKLM:\InMemoryOnly' 'FirstGate' 0
    Set-Gate 'HKLM:\InMemoryOnly' 'SecondGate' 1
    if ($state.created -ne 0 -or $state.values.ExistingProviderValue -ne 17 -or
        $state.values.FirstGate -ne 0 -or $state.values.SecondGate -ne 1) {throw 'Gate writer replaced other device parameters'}
    $state.exists = $false
    Set-Gate 'HKLM:\InMemoryOnly' 'ThirdGate' 1
    if ($state.created -ne 1) {throw 'Missing device key was not created once'}
    $state.badReadback = $true; $rejected = $false
    try {Set-Gate 'HKLM:\InMemoryOnly' 'FailedGate' 1}
    catch {if ($_.Exception.Message -ne 'Gate readback failed: FailedGate') {throw};$rejected = $true}
    if (!$rejected) {throw 'Gate readback failure was ignored'}
} $writers[0].Extent.Text
$launch = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'Launch-TouchGpioTrial.ps1') -Raw
if ($launch -notmatch 'New-TimeSpan\s+-Minutes\s+30\b' -or $launch -notmatch 'execution_limit_minutes=30\b') {throw 'Task timeout and receipt must cover the bounded trial'}
if ($Artifact) {
    . (Join-Path $PSScriptRoot 'TouchGpioCommon.ps1')
    $null = Get-TouchGpioManifest $Artifact
}
'PASS: all GPIO trial scripts parse and the actual runtime runner rejects this PC before clock, certificate, registry, installation or shutdown operations.'
