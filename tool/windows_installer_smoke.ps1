param([Parameter(Mandatory=$true)][string]$Installer)
$ErrorActionPreference = 'Stop'
$package = (Resolve-Path -LiteralPath $Installer).Path
$root = Join-Path ([IO.Path]::GetTempPath()) ('kmreader-installer-' + [guid]::NewGuid().ToString('N'))
$app = Join-Path $root 'app'
$menu = Join-Path ([Environment]::GetFolderPath('Programs')) 'KMReader\KMReader.lnk'
$desktop = Join-Path ([Environment]::GetFolderPath('DesktopDirectory')) 'KMReader.lnk'
if ((Test-Path -LiteralPath $menu) -or (Test-Path -LiteralPath $desktop)) {
  throw 'Run the installer test under an isolated user.'
}
New-Item -ItemType Directory -Path $root | Out-Null
$profile = Join-Path $root 'profile'
New-Item -ItemType Directory -Path $profile | Out-Null
$env:KMREADER_DATA_DIR = $profile
$marker = Join-Path $profile 'keep.txt'
'Preserve this profile' | Set-Content -LiteralPath $marker
try {
  $flags = '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /CURRENTUSER'
  $installed = Start-Process -FilePath $package -ArgumentList "$flags /DIR=`"$app`" /TASKS=startmenu,desktopicon" -PassThru -Wait
  if ($installed.ExitCode -ne 0) { throw "The installer exited with code $($installed.ExitCode)." }
  foreach ($path in @((Join-Path $app 'kmreader.exe'), (Join-Path $app 'kindle/KMReader-Kindle.exe'), $menu, $desktop)) {
    if (!(Test-Path -LiteralPath $path)) { throw "Missing installed file: $path" }
  }
  $uninstaller = @(Get-ChildItem -LiteralPath $app -Filter 'unins*.exe')
  if ($uninstaller.Count -ne 1) { throw 'Expected one uninstaller.' }
  $removed = Start-Process -FilePath $uninstaller[0].FullName -ArgumentList '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART' -PassThru -Wait
  if ($removed.ExitCode -ne 0) { throw "The uninstaller exited with code $($removed.ExitCode)." }
  if ((Test-Path (Join-Path $app 'kmreader.exe')) -or (Test-Path $menu) -or (Test-Path $desktop) -or
      !(Test-Path $marker)) { throw 'Unexpected uninstall result.' }
} finally {
  Remove-Item -LiteralPath $root -Force -Recurse
}
