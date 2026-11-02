param([string]$Version = '3.47.8')
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$ProgressPreference = 'SilentlyContinue'
$root = Join-Path $env:RUNNER_TOOL_CACHE "kmreader-flutter/$Version"
$ready = Join-Path $root '.kmreader-sdk-ready'
$flutter = Join-Path $root 'flutter/bin/flutter.bat'
if (-not (Test-Path $ready) -or -not (Test-Path $flutter)) {
    $metadata = Invoke-RestMethod -Uri 'https://storage.googleapis.com/flutter_infra_release/flutter/releases/releases_windows.json'
    $release = @($metadata.releases | Where-Object {
        $_.version -eq $Version -and $_.channel -eq 'stable' -and $_.dart_sdk_arch -eq 'x64'
    }) | Select-Object -First 1
    if (-not $release) { throw "Official Windows x64 Flutter $Version release not found." }
    New-Item -ItemType Directory -Force -Path $root | Out-Null
    $archive = Join-Path $root 'sdk.zip'
    Write-Host "Downloading official Flutter $Version Windows x64 SDK into the runner tool cache."
    Invoke-WebRequest -UseBasicParsing -Uri "$($metadata.base_url)/$($release.archive)" -OutFile $archive
    if ((Get-FileHash $archive -Algorithm SHA256).Hash.ToLowerInvariant() -ne $release.sha256) {
        throw 'Flutter archive SHA256 does not match the official release manifest.'
    }
    & tar.exe -xf $archive -C $root
    if ($LASTEXITCODE -ne 0) { throw 'Cannot extract the verified Flutter SDK.' }
    if (-not (Test-Path $flutter)) { throw 'Flutter executable missing after extraction.' }
    $release.sha256 | Set-Content -Path $ready
    Remove-Item $archive
}
(Split-Path $flutter) | Out-File -FilePath $env:GITHUB_PATH -Encoding utf8 -Append
$pubCache = Join-Path $env:RUNNER_TOOL_CACHE 'kmreader-pub-cache'
"PUB_CACHE=$pubCache" | Out-File -FilePath $env:GITHUB_ENV -Encoding utf8 -Append
'FLUTTER_SUPPRESS_ANALYTICS=true' | Out-File -FilePath $env:GITHUB_ENV -Encoding utf8 -Append
Write-Host "Flutter $Version is available for subsequent job steps."
