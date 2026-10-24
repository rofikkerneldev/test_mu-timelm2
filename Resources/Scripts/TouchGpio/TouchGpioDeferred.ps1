# Pure package preparation and injectable API boundary; importing does not install.
function Invoke-TouchGpioDeferredInstall {
    param([string]$Root,[string]$Destination,[uint32]$AttemptId,[int]$OsBuild,
          [Parameter(Mandatory=$true)][scriptblock]$Install)
    if(!$AttemptId -or $OsBuild -lt 16299){throw 'Deferred install requires a fresh attempt and Windows 10 1709 or later'}
    $manifest=Get-TouchGpioManifest $Root
    if(Test-Path -LiteralPath $Destination){throw 'Deferred set already exists; never reuse a partial set'}
    $files=@($manifest.files | Where-Object {$_.path -match '^Drivers/(GPIO|Host)/[^/]+\.(inf|cat|sys)$'})
    if($files.Count -ne 6){throw 'Expected exactly the reviewed GPIO and host INF/CAT/SYS'}
    $names=@{}
    foreach($file in $files){
        $name=[IO.Path]::GetFileName($file.path)
        if($names.ContainsKey($name)){throw 'Colliding deferred package filenames'}
        $names[$name]=$true
        if((Get-FileHash -LiteralPath (Join-Path $Root $file.path)).Hash -ine $file.sha256){throw 'Deferred source hash mismatch'}
    }
    $null=New-Item -ItemType Directory -Path $Destination
    foreach($file in $files){
        $dest=Join-Path $Destination ([IO.Path]::GetFileName($file.path))
        Copy-Item -LiteralPath (Join-Path $Root $file.path) -Destination $dest
        if((Get-FileHash -LiteralPath $dest).Hash -ine $file.sha256){throw 'Deferred copy hash mismatch'}
    }
    # newdev.h: INSTALL_AS_SET=0x40. Never FORCE_INF (0x02) or NOBACKUP (0x10).
    # The API stages the set now and makes it eligible at normal shutdown.
    $answer=& $Install ([IO.Path]::GetFullPath($Destination)) ([uint32]0x40)
    if(!$answer -or $answer.success -ne $true){throw ('Deferred API failed: '+$answer.win32_error)}
    return [ordered]@{attempt_id=$AttemptId;method='DiInstallDriverW/INSTALL_AS_SET';flags=64;
        api_success=$true;need_reboot=[bool]$answer.need_reboot;activation='next-normal-shutdown-and-boot';
        selected_driver_proven=$false;packages=@('GPIO','Host');files=$files;utc=[DateTime]::UtcNow.ToString('o')}
}
