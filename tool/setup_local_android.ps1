$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$ProgressPreference = 'SilentlyContinue'
$sdkRoot = Join-Path $env:RUNNER_TOOL_CACHE 'kmreader-android-sdk'
$tools = Join-Path $sdkRoot 'cmdline-tools/16.0'
$manager = Join-Path $tools 'bin/sdkmanager.bat'
if (-not (Test-Path $manager)) {
    $archive = Join-Path $env:RUNNER_TEMP 'kmreader-android-commandline.zip'
    $staging = Join-Path $env:RUNNER_TEMP 'kmreader-android-commandline'
    Invoke-WebRequest -UseBasicParsing -Uri 'https://dl.google.com/android/repository/commandlinetools-win-12266719_latest.zip' -OutFile $archive
    # Pinned official SDK command-line tools 16.0; the downloaded archive also
    # matches SHA1 32787c10f55911fd109848906b1275723e79f659 in Google's SDK index.
    $expected = 'f9088c04a44f1f37a8a3a228a7663e11ae9445fa07529c96cef38acb985a88f3'
    if ((Get-FileHash $archive -Algorithm SHA256).Hash.ToLowerInvariant() -ne $expected) {
        throw 'Android command-line tools SHA256 mismatch.'
    }
    if (Test-Path $staging) { Remove-Item -Recurse -Force $staging }
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    # ZipFile accepts the actual archive format; PS5 Expand-Archive rejects
    # extensionless tool-cache downloads used by setup-android's extractor.
    [IO.Compression.ZipFile]::ExtractToDirectory($archive, $staging)
    New-Item -ItemType Directory -Force -Path (Split-Path $tools) | Out-Null
    if (Test-Path $tools) { Remove-Item -Recurse -Force $tools }
    Move-Item (Join-Path $staging 'cmdline-tools') $tools
    Remove-Item -Force $archive
}
$ErrorActionPreference = 'Continue'
1..100 | ForEach-Object { 'y' } | & $manager "--sdk_root=$sdkRoot" --licenses
$licenseExit = $LASTEXITCODE
$ErrorActionPreference = 'Stop'
if ($licenseExit -ne 0) { throw 'Could not accept Android driver SDK licenses.' }
$ErrorActionPreference = 'Continue'
& $manager "--sdk_root=$sdkRoot" 'platform-tools' 'platforms;android-36' 'build-tools;36.0.0'
$installExit = $LASTEXITCODE
$ErrorActionPreference = 'Stop'
if ($installExit -ne 0) { throw 'Could not install Android driver SDK packages.' }
foreach ($relative in @('platform-tools/adb.exe', 'build-tools/36.0.0/aapt.exe', 'platforms/android-36/android.jar')) {
    if (-not (Test-Path (Join-Path $sdkRoot $relative))) { throw "Android driver SDK file missing: $relative" }
}
"ANDROID_HOME=$sdkRoot" | Out-File $env:GITHUB_ENV -Encoding utf8 -Append
"ANDROID_SDK_ROOT=$sdkRoot" | Out-File $env:GITHUB_ENV -Encoding utf8 -Append
(Join-Path $tools 'bin') | Out-File $env:GITHUB_PATH -Encoding utf8 -Append
(Join-Path $sdkRoot 'platform-tools') | Out-File $env:GITHUB_PATH -Encoding utf8 -Append
Write-Output "Android driver SDK ready in runner cache: $sdkRoot"
