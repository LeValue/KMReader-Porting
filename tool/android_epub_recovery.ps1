param([string]$Apk = '.dart_tool/android-epub-recovery/app-debug.apk', [switch]$DisableImpeller, [ValidateSet('auto', 'hybrid', 'texture')][string]$Composition = 'auto')
$ErrorActionPreference = 'Stop'
if (-not (Test-Path $Apk)) { throw "Diagnostic APK missing: $Apk" }
$analyzerCommand = Get-Command apkanalyzer.bat -ErrorAction SilentlyContinue
if (-not $analyzerCommand) { throw 'Android command-line tools (apkanalyzer) are required on PATH.' }
$analyzer = $analyzerCommand.Source
$package = 'dev.levalue.kmreader.epubdiagnostic'
$actualPackage = (& $analyzer manifest application-id $Apk | Out-String).Trim()
if ($LASTEXITCODE -ne 0 -or $actualPackage -ne $package) {
    throw 'Refusing to install an APK without the isolated EPUB diagnostic package identity.'
}
$deviceDeadline = [DateTime]::UtcNow.AddSeconds(90)
$previousState = ''
do {
    $deviceRows = @(& adb devices)
    if ($LASTEXITCODE -ne 0) { throw 'ADB could not query connected devices.' }
    $state = $deviceRows -join "`n"
    if ($state -ne $previousState) { Write-Output $state; $previousState = $state }
    $devices = @($deviceRows | Select-String '^([^\s]+)\s+device$' | ForEach-Object { $_.Matches[0].Groups[1].Value })
    if ($devices.Count -eq 1) { break }
    if ($devices.Count -gt 1) { throw 'More than one Android device is connected; select only the requested test phone.' }
    Write-Output 'Waiting for the unlocked USB phone and its debugging authorization...'
    Start-Sleep -Seconds 5
} while ([DateTime]::UtcNow -lt $deviceDeadline)
if ($devices.Count -ne 1) { throw 'No authorized Android phone appeared within 90 seconds; check the phone prompt, USB transfer mode and driver.' }
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
    $driveArguments = @('drive', "--use-application-binary=$Apk", '--driver=test_driver/native_reader_driver.dart', '--target=integration_test/epub_recovery_test.dart', '-d', $device, '--no-pub', '--no-dds')
    if ($DisableImpeller) { $driveArguments += '--no-enable-impeller' }
    if ($Composition -ne 'auto') { $driveArguments += "--route=/kmreader-epub-diagnostic/$Composition" }
    Write-Output "Diagnostic Flutter renderer: $(if ($DisableImpeller) { 'Skia' } else { 'default' })"
    & flutter @driveArguments 2>&1 |
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
        if ($LASTEXITCODE -ne 0) {
            # Some Huawei builds reject global deletion but permit removing
            # the test package from the primary Android user.
            & adb -s $device shell pm uninstall --user 0 $package | Out-File "$output/cleanup.txt" -Append
            if ($LASTEXITCODE -ne 0) {
                $remaining = @(& adb -s $device shell pm list packages --user 0 $package)
                if ($LASTEXITCODE -eq 0 -and -not ($remaining -match "^package:$([Regex]::Escape($package))$")) {
                    'Diagnostic package is no longer installed for the primary user.' | Out-File "$output/cleanup.txt" -Append
                } else { Write-Warning 'The phone refused diagnostic app removal; it can be removed manually. See cleanup.txt.' }
            }
        }
    }
}
# Cleanup is recorded separately; its exit status must not turn a successful
# reader regression into a false test failure. Exceptions above still fail.
exit 0
