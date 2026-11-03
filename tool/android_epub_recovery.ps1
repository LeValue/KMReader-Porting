param([string]$Apk = '.dart_tool/android-epub-recovery/app-debug.apk')
$ErrorActionPreference = 'Stop'
if (-not (Test-Path $Apk)) { throw "Diagnostic APK missing: $Apk" }
$analyzer = Join-Path $env:ANDROID_HOME 'cmdline-tools/latest/bin/apkanalyzer.bat'
if (-not (Test-Path $analyzer)) { throw 'Android command-line tools (apkanalyzer) are required.' }
$package = 'dev.levalue.kmreader.epubdiagnostic'
$actualPackage = (& $analyzer manifest application-id $Apk | Out-String).Trim()
if ($LASTEXITCODE -ne 0 -or $actualPackage -ne $package) {
    throw 'Refusing to install an APK without the isolated EPUB diagnostic package identity.'
}
$devices = @(& adb devices | Select-String '^([^\s]+)\s+device$' | ForEach-Object { $_.Matches[0].Groups[1].Value })
if ($LASTEXITCODE -ne 0 -or $devices.Count -ne 1) {
    throw 'Connect exactly one unlocked Android phone and authorize USB debugging; adb devices must show device.'
}
$device = $devices[0]
$abi = (& adb -s $device shell getprop ro.product.cpu.abi | Out-String).Trim()
if ($LASTEXITCODE -ne 0 -or $abi -ne 'arm64-v8a') { throw "This diagnostic APK requires ARM64; device ABI: $abi" }
$output = 'artifacts/android-epub-recovery'
New-Item -ItemType Directory -Force -Path $output | Out-Null
$installed = $false
try {
    @('ro.product.model', 'ro.build.version.release', 'ro.build.version.sdk') | ForEach-Object {
        "$($_): $(& adb -s $device shell getprop $_)"
    } | Set-Content "$output/device.txt"
    Get-FileHash $Apk -Algorithm SHA256 | Format-List | Out-File "$output/apk-sha256.txt"
    # Only the separate diagnostic package is installed/cleared. The regular
    # app and Preview retain their library, accounts, books and preferences.
    & adb -s $device install -r $Apk
    if ($LASTEXITCODE -ne 0) { throw 'Diagnostic APK installation failed.' }
    $installed = $true
    & adb -s $device shell pm clear $package
    if ($LASTEXITCODE -ne 0) { throw 'Could not reset the diagnostic package.' }
    $ErrorActionPreference = 'Continue'
    & flutter drive --use-application-binary=$Apk --driver=test_driver/native_reader_driver.dart --target=integration_test/epub_recovery_test.dart -d $device --no-pub --no-dds 2>&1 |
        Tee-Object "$output/test.log"
    $driveExit = $LASTEXITCODE
    $ErrorActionPreference = 'Stop'
    if ($driveExit -ne 0) { throw 'Android EPUB recovery regression failed; inspect test.log.' }
} finally {
    if ($installed) {
        # Keep diagnostics scoped to this test process; do not export the
        # phone's global logcat (it can contain unrelated app/user data).
        & adb -s $device shell am force-stop $package | Out-Null
        & adb -s $device uninstall $package | Out-File "$output/cleanup.txt"
    }
}
