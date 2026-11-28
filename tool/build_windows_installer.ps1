param(
  [Parameter(Mandatory=$true)][string]$Bundle,
  [Parameter(Mandatory=$true)][string]$OutputDirectory
)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$bundlePath = (Resolve-Path -LiteralPath $Bundle).Path
$outputPath = (New-Item -ItemType Directory -Force $OutputDirectory).FullName
$versionLine = Select-String -LiteralPath (Join-Path $root 'pubspec.yaml') -Pattern '^version: (\d+\.\d+\.\d+)\+(\d+)$'
if (!$versionLine) { throw 'Missing application version.' }
$version = $versionLine.Matches[0].Groups[1].Value
$build = [int]$versionLine.Matches[0].Groups[2].Value
$sourcePath = Join-Path $bundlePath 'data/flutter_assets/assets/build/source.json'
$source = Get-Content -LiteralPath $sourcePath -Raw | ConvertFrom-Json
if (!(Test-Path (Join-Path $bundlePath 'kmreader.exe')) -or
    $source.version -ne $version -or $source.build -ne $build -or
    ($env:GITHUB_SHA -and $source.source -ne $env:GITHUB_SHA)) {
  throw 'The Windows bundle does not match this checkout.'
}
$compiler = (Get-Command ISCC.exe -ErrorAction SilentlyContinue).Source
if (!$compiler) {
  $compiler = Join-Path ${env:ProgramFiles(x86)} 'Inno Setup 6\ISCC.exe'
}
if (!(Test-Path -LiteralPath $compiler)) { throw 'Inno Setup 6 is required.' }
& $compiler "/DAppVersion=$version" "/DBundleDir=$bundlePath" "/DOutputDir=$outputPath" (Join-Path $root 'windows/installer/kmreader.iss')
if ($LASTEXITCODE -ne 0) { throw "Inno Setup exited with code $LASTEXITCODE." }
$setup = Join-Path $outputPath "KMReader-$version-windows-x64-setup.exe"
if (!(Test-Path -LiteralPath $setup)) { throw 'Missing Windows installer output.' }
