# Locate only the requested book in KMReader's normal downloaded-book storage.
# No database, account, vault, or unrelated user directories are opened.
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression.FileSystem
$appRoot = Join-Path ([Environment]::GetFolderPath('ApplicationData')) 'dev.levalue/KMReader'
if (-not (Test-Path -LiteralPath $appRoot)) {
    throw 'KMReader download storage was not found at its standard location. An explicit EPUB path is needed.'
}

function Read-ZipXml($zip, [string]$name) {
    $entry = $zip.GetEntry($name)
    if (-not $entry -or $entry.Length -gt 2MB) { throw 'Missing or oversized EPUB metadata.' }
    $stream = $entry.Open()
    $settings = New-Object System.Xml.XmlReaderSettings
    $settings.DtdProcessing = [System.Xml.DtdProcessing]::Prohibit
    $settings.XmlResolver = $null
    $settings.MaxCharactersInDocument = 2MB
    $reader = [System.Xml.XmlReader]::Create($stream, $settings)
    try {
        $document = New-Object System.Xml.XmlDocument
        $document.XmlResolver = $null
        $document.Load($reader)
        return ,$document
    } finally { $reader.Dispose(); $stream.Dispose() }
}

$aliceCandidates = @()
$examined = 0
foreach ($profile in Get-ChildItem -LiteralPath $appRoot -Directory) {
    if ($profile.Attributes -band [System.IO.FileAttributes]::ReparsePoint) { continue }
    $books = Join-Path $profile.FullName 'books'
    if (-not (Test-Path -LiteralPath $books)) { continue }
    foreach ($book in Get-ChildItem -LiteralPath $books -Directory) {
        if ($book.Attributes -band [System.IO.FileAttributes]::ReparsePoint) { continue }
        $source = Join-Path $book.FullName 'source.epub'
        if (-not (Test-Path -LiteralPath $source)) { continue }
        $examined++
        if ($examined -gt 1000) { throw 'Bounded KMReader download search reached its limit; an explicit EPUB path is needed.' }
        $zip = $null
        try {
            $zip = [System.IO.Compression.ZipFile]::OpenRead($source)
            $container = Read-ZipXml $zip 'META-INF/container.xml'
            $rootfile = $container.SelectSingleNode('//*[local-name()="rootfile"]')
            if (-not $rootfile) { continue }
            $package = Read-ZipXml $zip $rootfile.GetAttribute('full-path')
            $title = $package.SelectSingleNode('//*[local-name()="metadata"]/*[local-name()="title"]')
            if (-not $title) { continue }
            $normalized = [regex]::Replace($title.InnerText.ToLowerInvariant(), '[^\p{L}\p{N}]+', ' ').Trim()
            if ($normalized -match '^alice ?s adventures in wonderland(?: |$)') {
                $aliceCandidates += $source
            }
        } catch {
            Write-Host 'Skipped unreadable EPUB metadata in KMReader download storage.'
        } finally { if ($zip) { $zip.Dispose() } }
    }
}
if ($aliceCandidates.Count -ne 1) {
    throw "Expected one cached Alice EPUB, found $($aliceCandidates.Count). An explicit EPUB path is needed."
}
Write-Host 'Located the requested Alice EPUB in KMReader download storage.'
Write-Output $aliceCandidates[0]
