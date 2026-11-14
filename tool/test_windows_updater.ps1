$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/../assets/update/windows-update.ps1"
$root = Join-Path $env:RUNNER_TEMP ('kmreader-update-test-' + [guid]::NewGuid().ToString('N'))
try {
    $install = Join-Path $root 'installed'
    $payload = Join-Path $root 'payload/KMReader'
    foreach ($folder in @($install,$payload,(Join-Path $payload 'data/flutter_assets/assets/build'),(Join-Path $payload 'kindle'))) { [IO.Directory]::CreateDirectory($folder) | Out-Null }
    [IO.File]::WriteAllText((Join-Path $install 'kmreader.exe'),'old-app')
    [IO.File]::WriteAllText((Join-Path $install 'user-data.txt'),'keep-me')
    [IO.File]::WriteAllText((Join-Path $payload 'kmreader.exe'),'new-app')
    [IO.File]::WriteAllText((Join-Path $payload 'data/app.so'),'binary')
    [IO.File]::WriteAllText((Join-Path $payload 'kindle/KMReader-Kindle.exe'),'worker')
    @{source=('a'*40);version='1.0.0';build=99} | ConvertTo-Json | Set-Content -Encoding UTF8 (Join-Path $payload 'data/flutter_assets/assets/build/source.json')
    $zip = Join-Path $root 'update.zip'
    [IO.Compression.ZipFile]::CreateFromDirectory((Join-Path $root 'payload'),$zip)
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
    [IO.Compression.ZipFile]::CreateFromDirectory((Join-Path $root 'payload'),$zip)
    $job.source = 'a'*40
    $job.sha256 = (Get-FileHash $zip -Algorithm SHA256).Hash.ToLowerInvariant()
    $locked = [IO.File]::Open((Join-Path $install 'data/locked.bin'),[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
    try {
        $rejected = $false
        try { Apply-KMReaderUpdate $job | Out-Null } catch { $rejected = $true }
        if (!$rejected -or (Get-Content (Join-Path $install 'kmreader.exe') -Raw) -ne 'rollback-app') { throw 'Partial replacement did not roll back' }
    } finally { $locked.Dispose() }
    Write-Output 'Windows updater: replacement, backup, user-data preservation and integrity/source rejection passed.'
} finally { if (Test-Path $root) { Remove-Item $root -Recurse -Force } }
