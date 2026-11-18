param([switch]$TestHandoff)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/../assets/update/windows-update.ps1"
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
# Windows PowerShell's .NET ZIP helper can emit backslashes. Match the public
# delivery script's forward-slash ZIP entries explicitly, without relaxing the
# production updater's traversal/path checks.
function New-TestPackage($directory, $destination) {
    $archive = [IO.Compression.ZipFile]::Open($destination,[IO.Compression.ZipArchiveMode]::Create)
    try {
        foreach ($file in Get-ChildItem -LiteralPath $directory -Recurse -File) {
            $relative = $file.FullName.Substring($directory.Length).TrimStart([char[]]'\/').Replace('\','/')
            [IO.Compression.ZipFileExtensions]::CreateEntryFromFile($archive,$file.FullName,$relative) | Out-Null
        }
    } finally { $archive.Dispose() }
}
$root = Join-Path $env:RUNNER_TEMP ('kmreader-update-test-' + [guid]::NewGuid().ToString('N'))
try {
    $install = Join-Path $root ('installed with space ' + [char]0x00E8)
    $payload = Join-Path $root 'payload/KMReader'
    foreach ($folder in @($install,$payload,(Join-Path $payload 'data/flutter_assets/assets/build'),(Join-Path $payload 'kindle'))) { [IO.Directory]::CreateDirectory($folder) | Out-Null }
    [IO.File]::WriteAllText((Join-Path $install 'kmreader.exe'),'old-app')
    [IO.File]::WriteAllText((Join-Path $install 'user-data.txt'),'keep-me')
    [IO.File]::WriteAllText((Join-Path $payload 'kmreader.exe'),'new-app')
    [IO.File]::WriteAllText((Join-Path $payload 'data/app.so'),'binary')
    [IO.File]::WriteAllText((Join-Path $payload 'kindle/KMReader-Kindle.exe'),'worker')
    @{source=('a'*40);version='1.0.0';build=99} | ConvertTo-Json | Set-Content -Encoding UTF8 (Join-Path $payload 'data/flutter_assets/assets/build/source.json')
    $zip = Join-Path $root 'update.zip'
    New-TestPackage (Join-Path $root 'payload') $zip
    $job = @{archive=$zip;sha256=(Get-FileHash $zip -Algorithm SHA256).Hash.ToLowerInvariant();install=$install;source=('a'*40);version='1.0.0';build=99}
    $backup = Apply-KMReaderUpdate $job
    if ((Get-Content (Join-Path $install 'kmreader.exe') -Raw) -ne 'new-app' -or
        (Get-Content (Join-Path $install 'user-data.txt') -Raw) -ne 'keep-me' -or
        (Get-Content (Join-Path $backup 'kmreader.exe') -Raw) -ne 'old-app') { throw 'Update did not retain application backup/user data' }
    $job.sha256 = '0'*64
    $rejected = $false
    try { Apply-KMReaderUpdate $job | Out-Null } catch { $rejected = $true }
    if (!$rejected) { throw 'Corrupt package was accepted' }
    $job.sha256 = (Get-FileHash $zip -Algorithm SHA256).Hash.ToLowerInvariant()
    $job.source = 'b'*40
    $rejected = $false
    try { Apply-KMReaderUpdate $job | Out-Null } catch { $rejected = $true }
    if (!$rejected -or (Get-Content (Join-Path $install 'kmreader.exe') -Raw) -ne 'new-app') { throw 'Wrong source changed installed app' }
    # Fail after at least the root executable was replaced: it must roll back.
    [IO.File]::WriteAllText((Join-Path $install 'kmreader.exe'),'rollback-app')
    [IO.File]::WriteAllText((Join-Path $payload 'data/locked.bin'),'new-locked')
    [IO.File]::WriteAllText((Join-Path $install 'data/locked.bin'),'old-locked')
    Remove-Item -LiteralPath $zip
    New-TestPackage (Join-Path $root 'payload') $zip
    $job.source = 'a'*40
    $job.sha256 = (Get-FileHash $zip -Algorithm SHA256).Hash.ToLowerInvariant()
    $locked = [IO.File]::Open((Join-Path $install 'data/locked.bin'),[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
    try {
        $rejected = $false
        try { Apply-KMReaderUpdate $job | Out-Null } catch { $rejected = $true }
        if (!$rejected -or (Get-Content (Join-Path $install 'kmreader.exe') -Raw) -ne 'rollback-app') { throw 'Partial replacement did not roll back' }
    } finally { $locked.Dispose() }
    Write-Output 'Windows updater: replacement, backup, user-data preservation and integrity/source rejection passed.'

    if ($TestHandoff) {
        $jobFile = Join-Path $root 'handoff job.json'
        $script = Join-Path $root 'update helper.ps1'
        Copy-Item -LiteralPath "$PSScriptRoot/../assets/update/windows-update.ps1" -Destination $script
        $program = @'
using System;
using System.IO;
public static class Replacement {
    public static void Main() {
        File.WriteAllText(Path.Combine(Environment.CurrentDirectory, "restart.marker"), "updated");
    }
}
'@
        Remove-Item -LiteralPath (Join-Path $payload 'kmreader.exe'),$zip
        Add-Type -TypeDefinition $program -OutputAssembly (Join-Path $payload 'kmreader.exe') -OutputType ConsoleApplication
        New-TestPackage (Join-Path $root 'payload') $zip
        $job.sha256 = (Get-FileHash $zip -Algorithm SHA256).Hash.ToLowerInvariant()
        # Emit Unicode paths as UTF-8 without a BOM for the Dart test parent.
        [IO.File]::WriteAllText($jobFile, ($job | ConvertTo-Json), (New-Object Text.UTF8Encoding($false)))
        $cancelJob = Join-Path $root 'cancelled job.json'
        Copy-Item -LiteralPath $jobFile -Destination $cancelJob
        & dart "$PSScriptRoot/windows_update_test_parent.dart" $script $cancelJob --cancel
        if ($LASTEXITCODE -ne 0 -or !(Test-Path -LiteralPath ($cancelJob + '.ready'))) { throw 'Helper was not ready before cancellation' }
        Start-Sleep -Milliseconds 500
        if ((Get-Content (Join-Path $install 'kmreader.exe') -Raw) -ne 'rollback-app') { throw 'Uncommitted update changed the install' }

        & dart "$PSScriptRoot/windows_update_test_parent.dart" $script $jobFile
        if ($LASTEXITCODE -ne 0 -or !(Test-Path -LiteralPath ($jobFile + '.commit'))) { throw 'Update launch did not complete handoff' }
        $marker = Join-Path $install 'restart.marker'
        $result = $jobFile + '.result'
        $deadline = [DateTime]::UtcNow.AddSeconds(30)
        while (!(Test-Path -LiteralPath $marker) -or !(Test-Path -LiteralPath $result)) {
            if ([DateTime]::UtcNow -ge $deadline) { throw 'Replacement did not restart in its installation directory' }
            Start-Sleep -Milliseconds 100
        }
        $report = Get-Content -LiteralPath $result -Encoding UTF8 -Raw | ConvertFrom-Json
        if ($report.state -ne 'installed' -or
            (Get-Content -LiteralPath $marker -Raw) -ne 'updated' -or
            (Get-Content (Join-Path $install 'user-data.txt') -Raw) -ne 'keep-me' -or
            (Get-Content (Join-Path $report.backup 'kmreader.exe') -Raw) -ne 'rollback-app') { throw 'Handoff did not retain app backup or user data' }
        Write-Output 'Windows updater: Dart launched the helper, the parent exited and the replacement process started.'
    }
} finally { if (Test-Path $root) { Remove-Item $root -Recurse -Force } }
