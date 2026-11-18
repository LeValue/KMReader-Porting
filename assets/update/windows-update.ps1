param([string]$JobFile)
$ErrorActionPreference = 'Stop'

function Apply-KMReaderUpdate($job) {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    if ((Get-FileHash -LiteralPath $job.archive -Algorithm SHA256).Hash.ToLowerInvariant() -ne $job.sha256) { throw 'Package digest mismatch' }
    $install = [IO.Path]::GetFullPath($job.install)
    if ((Get-Item -LiteralPath $install).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Linked install directory' }
    $stage = Join-Path (Split-Path $job.archive) ('stage-' + [guid]::NewGuid().ToString('N'))
    $backup = Join-Path (Split-Path $job.archive) ('backup-' + [guid]::NewGuid().ToString('N'))
    [IO.Directory]::CreateDirectory($stage) | Out-Null
    [IO.Directory]::CreateDirectory($backup) | Out-Null
    $archive = [IO.Compression.ZipFile]::OpenRead($job.archive)
    $files = New-Object 'System.Collections.Generic.List[string]'
    $names = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $changed = New-Object 'System.Collections.Generic.List[string]'
    $existed = @{}
    try {
        $total = 0L
        foreach ($entry in $archive.Entries) {
            $name = $entry.FullName
            if (!$name.StartsWith('KMReader/') -or $name -match '\\|:|[<>"|?*\x00-\x1f]' -or $name -match '(^|/)\.{1,2}(/|$)' -or
                $name -match '(?i)(^|/)(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(\.|/|$)' -or
                (($entry.ExternalAttributes -shr 16) -band 61440) -eq 40960 -or !$names.Add($name)) { throw 'Unsafe archive path' }
            $total += $entry.Length
            if ($total -gt 1073741824) { throw 'Archive too large' }
            $relative = $name.Substring(9)
            if (!$relative -or $name.EndsWith('/')) { continue }
            if ($relative.Split('/') | Where-Object { !$_ -or $_.EndsWith('.') -or $_.EndsWith(' ') }) { throw 'Ambiguous archive path' }
            $destination = Join-Path $stage $relative
            [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($destination)) | Out-Null
            [IO.Compression.ZipFileExtensions]::ExtractToFile($entry,$destination,$false)
            $files.Add($relative)
        }
        $metadata = Get-Content -Encoding UTF8 -LiteralPath (Join-Path $stage 'data/flutter_assets/assets/build/source.json') -Raw | ConvertFrom-Json
        if ($metadata.source -ne $job.source -or $metadata.build -ne $job.build -or $metadata.version -ne $job.version -or
            !(Test-Path -LiteralPath (Join-Path $stage 'kmreader.exe')) -or !(Test-Path -LiteralPath (Join-Path $stage 'data/app.so')) -or
            !(Test-Path -LiteralPath (Join-Path $stage 'kindle/KMReader-Kindle.exe'))) { throw 'Wrong application source' }
        foreach ($relative in $files) {
            $target = Join-Path $install $relative
            $parent = [IO.Path]::GetDirectoryName($target)
            $check = $parent
            while ($check.Length -ge $install.Length) {
                if ((Test-Path -LiteralPath $check) -and ((Get-Item -LiteralPath $check).Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Linked application directory' }
                $next = [IO.Path]::GetDirectoryName($check)
                if (!$next -or $next -eq $check) { break }; $check = $next
            }
            $existed[$relative] = Test-Path -LiteralPath $target
            if ($existed[$relative]) {
                $saved = Join-Path $backup $relative
                [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($saved)) | Out-Null
                [IO.File]::Copy($target,$saved,$false)
            }
        }
        foreach ($relative in $files) {
            $target = Join-Path $install $relative
            [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($target)) | Out-Null
            $incoming = $target + '.update-' + [guid]::NewGuid().ToString('N')
            try {
                [IO.File]::Copy((Join-Path $stage $relative),$incoming,$false)
                for ($attempt = 0; ; $attempt++) {
                    try {
                        if ($existed[$relative]) { [IO.File]::Replace($incoming,$target,[NullString]::Value) }
                        else { [IO.File]::Move($incoming,$target) }
                        break
                    } catch [IO.IOException] {
                        if ($attempt -ge 20) { throw }
                        Start-Sleep -Milliseconds 250
                    }
                }
                $changed.Add($relative)
            } finally { if (Test-Path -LiteralPath $incoming) { Remove-Item -LiteralPath $incoming -Force } }
        }
    } catch {
        $failure = $_
        foreach ($relative in $changed) {
            if ($existed[$relative]) { [IO.File]::Copy((Join-Path $backup $relative),(Join-Path $install $relative),$true) }
            else { Remove-Item -LiteralPath (Join-Path $install $relative) -Force }
        }
        throw $failure
    } finally { $archive.Dispose(); Remove-Item -LiteralPath $stage -Recurse -Force }
    return $backup
}

function Write-KMReaderUpdateResult($state, $build, $backup = $null, $phase = $null) {
    @{state=$state;build=$build;backup=$backup;phase=$phase} | ConvertTo-Json |
        Set-Content -Encoding UTF8 -LiteralPath ($JobFile + '.result')
}

if ($JobFile -and $MyInvocation.InvocationName -ne '.') {
    $job = $null
    $parentExited = $false
    $phase = 'read_job'
    try {
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $job = Get-Content -Encoding UTF8 -LiteralPath $JobFile -Raw | ConvertFrom-Json
        $install = [IO.Path]::GetFullPath($job.install)
        $executable = Join-Path $install 'kmreader.exe'
        if (!(Test-Path -LiteralPath $executable -PathType Leaf) -or
            !(Test-Path -LiteralPath $job.archive -PathType Leaf)) { throw 'Update files unavailable' }
        $phase = 'attach'
        $process = Get-Process -Id $job.pid -ErrorAction Stop
        # Open the process handle before the app exits, so a recycled PID
        # cannot be mistaken for the application that started this job.
        $null = $process.Handle
        [IO.File]::WriteAllText(($JobFile + '.ready'),'')
        $deadline = [DateTime]::UtcNow.AddSeconds(45)
        while (!(Test-Path -LiteralPath ($JobFile + '.commit'))) {
            if ($process.HasExited -or [DateTime]::UtcNow -ge $deadline) { exit 1 }
            Start-Sleep -Milliseconds 100
        }
        # The helper never terminates the app: normal app shutdown saves its state.
        $phase = 'wait_for_exit'
        if (!$process.WaitForExit(120000)) { throw 'Application did not close' }
        $parentExited = $true
        $phase = 'replace_files'
        $saved = Apply-KMReaderUpdate $job
    } catch {
        try { Write-KMReaderUpdateResult 'failed' $job.build $null $phase }
        finally {
            if ($parentExited) { Start-Process -FilePath $executable -WorkingDirectory $install }
        }
        exit 1
    }
    try {
        Start-Process -FilePath $executable -WorkingDirectory $install
    } catch {
        Write-KMReaderUpdateResult 'restart_failed' $job.build $saved
        exit 1
    }
    Write-KMReaderUpdateResult 'installed' $job.build $saved
}
