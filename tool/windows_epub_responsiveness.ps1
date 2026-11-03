# Run only the standalone diagnostic bundle; never attach to the installed app.
param(
    [string]$Executable = '.dart_tool/native-prebuilt/kmreader.exe',
    [string]$OutputDirectory = 'artifacts/local-windows',
    [int]$TimeoutSeconds = 300
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'windows_interactive_desktop.ps1')
Assert-KmReaderInteractiveDesktop
New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null
$outputRoot = (Resolve-Path -LiteralPath $OutputDirectory).Path
$executablePath = (Resolve-Path -LiteralPath $Executable).Path
$env:KMREADER_RESPONSE_OUTPUT = Join-Path $outputRoot 'responsiveness.json'
$env:KMREADER_DATA_DIR = Join-Path ([System.IO.Path]::GetTempPath()) ('kmreader-response-' + [guid]::NewGuid().ToString('N'))
$samples = [System.Collections.Generic.List[object]]::new()
$known = [System.Collections.Generic.HashSet[int]]::new()
$root = $null
$completed = $false
$pinned = $false
$watch = [System.Diagnostics.Stopwatch]::StartNew()
try {
    $root = Start-Process -FilePath $executablePath -WorkingDirectory (Split-Path $executablePath) -PassThru -RedirectStandardOutput (Join-Path $outputRoot 'response-stdout.log') -RedirectStandardError (Join-Path $outputRoot 'response-stderr.log')
    [void]$known.Add($root.Id)
    while (-not $root.HasExited) {
        Assert-KmReaderInteractiveDesktop
        $root.Refresh()
        if (-not $pinned -and $root.MainWindowHandle -ne [IntPtr]::Zero) {
            $pinned = [KMReaderProbeDesktop]::Pin($root.MainWindowHandle, $true)
        }
        if ($watch.Elapsed.TotalSeconds -gt $TimeoutSeconds) { throw 'Standalone reader probe timed out.' }
        # Only PIDs descended from this exact diagnostic launch. Do not record
        # process command lines, account names, paths or other applications.
        $parentFilter = (@($known) | ForEach-Object { "ParentProcessId=$_" }) -join ' OR '
        foreach ($child in @(Get-CimInstance Win32_Process -Filter $parentFilter -Property Name,ProcessId,ParentProcessId)) {
            if ($child.Name -match '^(kmreader|msedgewebview2)\.exe$') { [void]$known.Add([int]$child.ProcessId) }
        }
        $processes = @()
        foreach ($processId in @($known)) {
            $process = Get-Process -Id $processId -ErrorAction SilentlyContinue
            if ($null -ne $process) {
                try {
                    $processes += [ordered]@{
                        pid = $processId
                        kind = $(if ($processId -eq $root.Id) { 'flutter' } else { 'webview' })
                        cpuSeconds = $process.TotalProcessorTime.TotalSeconds
                        workingBytes = $process.WorkingSet64
                        privateBytes = $process.PrivateMemorySize64
                    }
                } catch { # A child may exit during sampling.
                }
            } else {
                [void]$known.Remove($processId)
            }
        }
        $samples.Add([ordered]@{
            epochMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
            elapsedMs = $watch.Elapsed.TotalMilliseconds
            processes = $processes
        })
        if (Test-Path -LiteralPath $env:KMREADER_RESPONSE_OUTPUT) {
            # Partial reports are written between phases. Only the final
            # sealed report permits stopping this diagnostic application.
            try {
                $report = Get-Content -LiteralPath $env:KMREADER_RESPONSE_OUTPUT -Raw | ConvertFrom-Json
                if ($report.complete) { $completed = $true; break }
            } catch { # A write may be in progress; retry on the next sample.
            }
        }
        Start-Sleep -Milliseconds 1000
        $root.Refresh()
    }
    if (-not $completed) { throw "Reader probe exited before sealing its report (code $($root.ExitCode))." }
    if (-not $pinned) { throw 'The diagnostic window could not be made visible.' }
    if (-not $report.success) { throw 'Reader diagnostic report did not pass.' }
    foreach ($phaseName in @('slideFollowingTurns', 'curlFollowingTurns', 'verticalWheel')) {
        $phase = $report.phases.$phaseName
        if ($phase.captureAfter.gpuCopies -le $phase.captureBefore.gpuCopies) {
            throw "No native texture delivery during $phaseName; keep the diagnostic window visible."
        }
    }
    Write-Output 'Reader responsiveness probe completed.'
} finally {
    [System.IO.File]::WriteAllText((Join-Path $outputRoot 'process-samples.json'), (ConvertTo-Json -InputObject @($samples.ToArray()) -Depth 7))
    if ($null -ne $root -and -not $root.HasExited) {
        if ($pinned) { [void][KMReaderProbeDesktop]::Pin($root.MainWindowHandle, $false) }
        # Stop only the diagnostic process tree created above.
        & taskkill /PID $root.Id /T /F | Out-Null
    }
}
