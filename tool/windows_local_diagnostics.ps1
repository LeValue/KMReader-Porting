# Read-only prerequisites for an interactive, self-hosted Windows runner.
# Intentionally omit account names, host names, network details and serials.
$ErrorActionPreference = 'Stop'
$outputDirectory = Join-Path $PSScriptRoot '../artifacts/local-windows'
New-Item -ItemType Directory -Force -Path $outputDirectory | Out-Null

$os = Get-CimInstance Win32_OperatingSystem
$system = Get-CimInstance Win32_ComputerSystem
$sessionId = (Get-Process -Id $PID).SessionId
$graphics = @(Get-CimInstance Win32_VideoController | ForEach-Object {
    [ordered]@{
        name = $_.Name
        driver = $_.DriverVersion
        refreshHz = $_.CurrentRefreshRate
        width = $_.CurrentHorizontalResolution
        height = $_.CurrentVerticalResolution
        status = $_.Status
    }
})
$tools = [ordered]@{}
foreach ($name in @('git', 'flutter', 'dart', 'python', 'cmake', 'pwsh', 'adb')) {
    $tools[$name] = $null -ne (Get-Command $name -ErrorAction SilentlyContinue)
}
$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio/Installer/vswhere.exe'
$visualStudio = @()
if (Test-Path $vswhere) {
    $installations = & $vswhere -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -format json | ConvertFrom-Json
    $visualStudio = @($installations | ForEach-Object {
        [ordered]@{ version = $_.installationVersion; name = $_.displayName }
    })
}
$webViewVersions = @()
foreach ($root in @('HKLM:\SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate\Clients', 'HKLM:\SOFTWARE\Microsoft\EdgeUpdate\Clients', 'HKCU:\SOFTWARE\Microsoft\EdgeUpdate\Clients')) {
    if (Test-Path $root) {
        $webViewVersions += @(Get-ChildItem $root | ForEach-Object {
            $entry = Get-ItemProperty $_.PSPath
            if ($entry.name -match 'WebView2') { $entry.pv }
        })
    }
}
$drive = Get-PSDrive -Name (Split-Path -Qualifier $PSScriptRoot).TrimEnd(':')
$report = [ordered]@{
    schema = 1
    os = $os.Caption
    osVersion = $os.Version
    logicalProcessors = $system.NumberOfLogicalProcessors
    memoryGB = [math]::Round($system.TotalPhysicalMemory / 1GB, 1)
    workspaceFreeGB = [math]::Round($drive.Free / 1GB, 1)
    interactive = [Environment]::UserInteractive
    sessionId = $sessionId
    powershell = $PSVersionTable.PSVersion.ToString()
    graphics = $graphics
    tools = $tools
    visualStudioCpp = $visualStudio
    webView2 = @($webViewVersions | Sort-Object -Unique)
}
$json = $report | ConvertTo-Json -Depth 6
[System.IO.File]::WriteAllText((Join-Path $outputDirectory 'environment.json'), $json)
Write-Output $json
if ($sessionId -eq 0 -or -not [Environment]::UserInteractive) {
    throw 'Run the runner with .\run.cmd in an unlocked desktop session, rather than as a service.'
}
