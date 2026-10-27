param([Parameter(Mandatory=$true)][string]$Executable,
      [Parameter(Mandatory=$true)][string]$OutputDirectory)
$ErrorActionPreference = 'Stop'
New-Item -ItemType Directory -Force $OutputDirectory | Out-Null
$resolved = (Resolve-Path $Executable).Path
$isolated = Join-Path $OutputDirectory 'isolated-profile'
New-Item -ItemType Directory -Force $isolated | Out-Null
$start = [System.Diagnostics.ProcessStartInfo]::new($resolved)
$start.WorkingDirectory = Split-Path $resolved
$start.UseShellExecute = $false
$start.RedirectStandardError = $true
$start.RedirectStandardOutput = $true
$start.Environment['KMREADER_DATA_DIR'] = $isolated
$process = [System.Diagnostics.Process]::Start($start)
$errorOutput = $process.StandardError.ReadToEndAsync()
$standardOutput = $process.StandardOutput.ReadToEndAsync()
try {
  $deadline = [DateTime]::UtcNow.AddSeconds(45)
  do {
    Start-Sleep -Milliseconds 250
    $process.Refresh()
    if ($process.HasExited) { throw "KMReader exited before creating a window (code $($process.ExitCode))." }
  } until ($process.MainWindowHandle -ne [IntPtr]::Zero -or [DateTime]::UtcNow -ge $deadline)
  if ($process.MainWindowHandle -eq [IntPtr]::Zero) { throw 'KMReader did not create a native Windows window.' }
  if ($process.MainWindowTitle -notmatch 'KMReader') { throw "Unexpected window title: $($process.MainWindowTitle)" }
  Start-Sleep -Seconds 5
  $process.Refresh()
  if ($process.HasExited) { throw 'KMReader exited during its startup stability check.' }
  Add-Type -AssemblyName System.Drawing
  Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class KMReaderSmokeWindow {
  [StructLayout(LayoutKind.Sequential)] public struct Rect { public int Left, Top, Right, Bottom; }
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr handle, out Rect rect);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr handle);
}
'@
  $rect = [KMReaderSmokeWindow+Rect]::new()
  if (-not [KMReaderSmokeWindow]::GetWindowRect($process.MainWindowHandle, [ref]$rect)) { throw 'Cannot read the app window bounds.' }
  $width = $rect.Right - $rect.Left
  $height = $rect.Bottom - $rect.Top
  if ($width -lt 200 -or $height -lt 200) { throw 'The app window has invalid dimensions.' }
  [KMReaderSmokeWindow]::SetForegroundWindow($process.MainWindowHandle) | Out-Null
  $bitmap = [System.Drawing.Bitmap]::new($width, $height)
  $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
  try {
    $graphics.CopyFromScreen($rect.Left, $rect.Top, 0, 0, $bitmap.Size)
    $bitmap.Save((Join-Path $OutputDirectory 'windows-startup.png'), [System.Drawing.Imaging.ImageFormat]::Png)
  } finally { $graphics.Dispose(); $bitmap.Dispose() }
  Write-Host "Native Windows startup passed: $width x $height, window '$($process.MainWindowTitle)'."
} finally {
  if (-not $process.HasExited) { $process.Kill(); $process.WaitForExit() }
  $errorOutput.GetAwaiter().GetResult() | Set-Content (Join-Path $OutputDirectory 'stderr.txt')
  $standardOutput.GetAwaiter().GetResult() | Set-Content (Join-Path $OutputDirectory 'stdout.txt')
  $process.Dispose()
}
