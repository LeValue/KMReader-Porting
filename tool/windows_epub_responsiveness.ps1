# Run only the standalone diagnostic bundle; never attach to the installed app.
param(
    [string]$Executable = '.dart_tool/native-prebuilt/kmreader.exe',
    [string]$OutputDirectory = 'artifacts/local-windows',
    [int]$TimeoutSeconds = 300
)
$ErrorActionPreference = 'Stop'
New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null
$outputRoot = (Resolve-Path -LiteralPath $OutputDirectory).Path
$executablePath = (Resolve-Path -LiteralPath $Executable).Path
$env:KMREADER_RESPONSE_OUTPUT = Join-Path $outputRoot 'responsiveness.json'
$env:KMREADER_DATA_DIR = Join-Path ([System.IO.Path]::GetTempPath()) ('kmreader-response-' + [guid]::NewGuid().ToString('N'))
$samples = [System.Collections.Generic.List[object]]::new()
$known = [System.Collections.Generic.HashSet[int]]::new()
$root = $null
$watch = [System.Diagnostics.Stopwatch]::StartNew()
try {
    $root = Start-Process -FilePath $executablePath -WorkingDirectory (Split-Path $executablePath) -PassThru -RedirectStandardOutput (Join-Path $outputRoot 'response-stdout.log') -RedirectStandardError (Join-Path $outputRoot 'response-stderr.log')
    [void]$known.Add($root.Id)
    while (-not $root.HasExited) {
        if ($watch.Elapsed.TotalSeconds -gt $TimeoutSeconds) { throw 'Standalone reader probe timed out.' }
        # Only PIDs descended from this exact diagnostic launch. Do not record
        # process command lines, account names, paths or other applications.
        foreach ($parent in @($known)) {
            foreach ($child in @(Get-CimInstance Win32_Process -Filter "ParentProcessId=$parent")) {
                if ($child.Name -match '^(kmreader|msedgewebview2)\.exe$') { [void]$known.Add([int]$child.ProcessId) }
            }
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
            }
        }
        $samples.Add([ordered]@{
            epochMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
            elapsedMs = $watch.Elapsed.TotalMilliseconds
            processes = $processes
        })
        Start-Sleep -Milliseconds 1000
        $root.Refresh()
    }
    $root.WaitForExit()
    if ($root.ExitCode -ne 0) { throw "Reader probe failed with exit code $($root.ExitCode)." }
    $report = Get-Content -LiteralPath $env:KMREADER_RESPONSE_OUTPUT -Raw | ConvertFrom-Json
    if (-not $report.success) { throw 'Reader diagnostic report did not pass.' }
    Write-Output 'Reader responsiveness probe completed.'
} finally {
    [System.IO.File]::WriteAllText((Join-Path $outputRoot 'process-samples.json'), (ConvertTo-Json -InputObject @($samples.ToArray()) -Depth 7))
    if ($null -ne $root -and -not $root.HasExited) {
        # Stop only the diagnostic process tree created above.
        & taskkill /PID $root.Id /T /F | Out-Null
    }
}
