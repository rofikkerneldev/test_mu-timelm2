param(
    [Parameter(Mandatory=$true)][string]$Source,
    [Parameter(Mandatory=$true)][string]$Destination
)
$ErrorActionPreference = 'Stop'
$Source = (Resolve-Path -LiteralPath $Source).Path
$null = New-Item -ItemType Directory -Force -Path $Destination
$Destination = (Resolve-Path -LiteralPath $Destination).Path
$expected = '3dcdec0bd59e3e77be92629b2ed9e095ae6e19e8'
$actual = (& git -C $Source rev-parse HEAD).Trim()
if ($LASTEXITCODE -ne 0 -or $actual -ne $expected) { throw "Unexpected driver source: $actual" }
$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
$msbuild = & $vswhere -latest -products '*' -requires Microsoft.Component.MSBuild -find 'MSBuild\**\Bin\MSBuild.exe' | Select-Object -First 1
if (-not $msbuild) { throw 'MSBuild not found' }
$solutionDir = Join-Path $Source 'build\'
$metadata = [ordered]@{
    repository = 'https://github.com/WOA-Kona/Drivers'
    commit = $actual
    configuration = 'Debug'
    architecture = 'ARM64'
    target_os = 'Windows 11 22H2 (22621); hardware validation pending'
    kmdf = '1.33'
    components = @('GPIO','SPMI','PMIC')
}
$metadata | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $Destination 'source.json')
foreach ($component in $metadata.components) {
    $project = Join-Path $Source "src\$component\$component.vcxproj"
    $log = Join-Path $Destination "$component-build.log"
    & $msbuild $project /m /t:Rebuild /nologo /v:minimal /p:Configuration=Debug /p:Platform=ARM64 "/p:SolutionDir=$solutionDir" /p:KmdfLibraryVersion=1.33 "/flp:logfile=$log;verbosity=normal"
    if ($LASTEXITCODE -ne 0) { throw "$component build failed: $LASTEXITCODE" }
}
$output = Join-Path $Source 'build\ARM64\Debug\Output'
foreach ($component in $metadata.components) {
    $package = Join-Path $output $component
    if (-not (Test-Path -LiteralPath $package)) { throw "Missing package: $package" }
    Copy-Item -LiteralPath $package -Destination $Destination -Recurse
    $pdb = Join-Path $output "$component.pdb"
    if (Test-Path -LiteralPath $pdb) { Copy-Item -LiteralPath $pdb -Destination (Join-Path $Destination $component) }
}
$hashes = foreach ($file in Get-ChildItem -LiteralPath $Destination -Recurse -File) {
    if ($file.Extension -eq '.sys') {
        $bytes = [IO.File]::ReadAllBytes($file.FullName)
        $pe = [BitConverter]::ToInt32($bytes, 0x3c)
        if ([BitConverter]::ToUInt32($bytes,$pe) -ne 0x4550 -or [BitConverter]::ToUInt16($bytes,$pe+4) -ne 0xAA64) {
            throw "Not an ARM64 PE driver: $($file.Name)"
        }
    }
    [ordered]@{path=[IO.Path]::GetRelativePath($Destination,$file.FullName);sha256=(Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant();size=$file.Length}
}
$hashes | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $Destination 'sha256.json')
Write-Host 'All three ARM64 DEBUG packages built. Installation and hardware validation remain required.'
