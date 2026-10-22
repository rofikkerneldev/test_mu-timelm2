<#
.SYNOPSIS
  Checks the syntax of the scripts of the button path.

.DESCRIPTION
  PC side helper only.  The script parses every script of this folder with
  the parser of PowerShell and prints the errors of the ones that do not
  parse.  The scripts of the phone run with the Windows PowerShell of the
  phone, the parse of this check is the one of the build PC.

.EXAMPLE
  pwsh -NoProfile -File Check-TimelmScriptSyntax.ps1
#>
[CmdletBinding()]
param(
    [string]$Path = $PSScriptRoot
)

$ErrorActionPreference = 'Stop'

$failed = 0
foreach ($file in Get-ChildItem -LiteralPath $Path -Filter '*.ps1' -File | Sort-Object Name) {
    $errors = $null
    $null = [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$null, [ref]$errors)
    if ($errors -and $errors.Count -gt 0) {
        $failed++
        Write-Host ("FAIL {0}" -f $file.Name)
        foreach ($error in $errors) {
            Write-Host ("     line {0}: {1}" -f $error.Extent.StartLineNumber, $error.Message)
        }
    } else {
        Write-Host ("ok   {0}" -f $file.Name)
    }
}

if ($failed -gt 0) { throw ("{0} script(s) do not parse" -f $failed) }
Write-Host 'all scripts parse'
