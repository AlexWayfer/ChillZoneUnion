[CmdletBinding()]
param(
    [string]$OutputDirectory = 'build',
    [switch]$ValidateOnly
)

$ErrorActionPreference = 'Stop'
$repoRoot = [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
$manifest = @(
    'Bindings.xml',
    'Chat.lua',
    'ChillZoneUnion.toc',
    'Core.lua',
    'LICENSE.txt',
    'Network.lua',
    'Presence.lua',
    'Protocol.lua',
    'README.txt',
    'Roster.lua',
    'SECURITY.txt',
    'Stats.lua',
    'Transfers.lua',
    'UI.lua',
    'Union.lua',
    'Libs/LibDeflate.lua',
    'Libs/LibStub.lua',
    'Media/arrow-down.tga',
    'Media/arrow-left.tga',
    'Media/arrow-right.tga',
    'Media/arrow-up.tga',
    'Media/minimap.tga',
    'Media/status-dot.tga',
    'Tests/run-lua.ps1',
    'Tests/security.lua',
    'Tests/simulation.lua'
)
if ($manifest.Count -ne 26 -or @($manifest | Select-Object -Unique).Count -ne 26) {
    throw 'The addon package manifest must contain exactly 26 distinct files.'
}

foreach ($relative in $manifest) {
    $source = Join-Path $repoRoot $relative
    $item = Get-Item -LiteralPath $source -Force
    if ($item.PSIsContainer) { throw "Expected an addon file: $relative" }
    $cursor = $source
    while ($cursor -ne $repoRoot) {
        $component = Get-Item -LiteralPath $cursor -Force
        if (($component.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Symlinks and reparse points are not allowed in addon packages: $relative"
        }
        $cursor = Split-Path -Parent $cursor
        if (-not $cursor) { throw "Package path escaped the repository: $relative" }
    }
}

$core = [IO.File]::ReadAllText((Join-Path $repoRoot 'Core.lua'))
$toc = [IO.File]::ReadAllText((Join-Path $repoRoot 'ChillZoneUnion.toc'))
$coreVersions = [regex]::Matches($core, '(?m)^U\.VERSION,\s*U\.PREFIX\s*=\s*"([^"]+)"\s*,')
$tocVersions = [regex]::Matches($toc, '(?m)^## Version:\s*([^\s]+)\s*$')
if ($coreVersions.Count -ne 1 -or $tocVersions.Count -ne 1) {
    throw 'Core.lua and ChillZoneUnion.toc must each declare one unambiguous version.'
}
$version = $coreVersions[0].Groups[1].Value
if ($version -cne $tocVersions[0].Groups[1].Value -or $version -cnotmatch '^[0-9]+\.[0-9]+\.[0-9]+(?:-[A-Za-z0-9][A-Za-z0-9.-]*)?$') {
    throw 'Core.lua and TOC versions must match and use a safe semantic-version string.'
}
foreach ($line in ($toc -split '\r?\n')) {
    $line = $line.Trim()
    if ($line -eq '' -or $line.StartsWith('#')) { continue }
    $relative = $line.Replace('\', '/')
    if ($manifest -cnotcontains $relative) { throw "TOC dependency is absent from the package manifest: $relative" }
}

$tag = "v$version"
if ($env:GITHUB_OUTPUT) {
    Add-Content -LiteralPath $env:GITHUB_OUTPUT -Value "version=$version" -Encoding utf8
    Add-Content -LiteralPath $env:GITHUB_OUTPUT -Value "tag=$tag" -Encoding utf8
}
if ($ValidateOnly) {
    Write-Output "Validated ChillZoneUnion ${version}: 26 addon files."
    return
}

if (-not [IO.Path]::IsPathRooted($OutputDirectory)) { $OutputDirectory = Join-Path $repoRoot $OutputDirectory }
$OutputDirectory = [IO.Path]::GetFullPath($OutputDirectory)
[IO.Directory]::CreateDirectory($OutputDirectory) | Out-Null
$archive = Join-Path $OutputDirectory "ChillZoneUnion-$version.zip"
$fileStream = [IO.File]::Open($archive, [IO.FileMode]::Create, [IO.FileAccess]::Write, [IO.FileShare]::None)
try {
    $zip = [IO.Compression.ZipArchive]::new($fileStream, [IO.Compression.ZipArchiveMode]::Create, $true)
    try {
        foreach ($relative in ($manifest | Sort-Object -CaseSensitive)) {
            $entry = $zip.CreateEntry("ChillZoneUnion/$relative", [IO.Compression.CompressionLevel]::Optimal)
            $entry.LastWriteTime = [DateTimeOffset]::new(2000, 1, 1, 0, 0, 0, [TimeSpan]::Zero)
            $entry.ExternalAttributes = 0
            $entryStream = $entry.Open()
            try {
                $bytes = [IO.File]::ReadAllBytes((Join-Path $repoRoot $relative))
                $entryStream.Write($bytes, 0, $bytes.Length)
            } finally { $entryStream.Dispose() }
        }
    } finally { $zip.Dispose() }
} finally { $fileStream.Dispose() }

$check = [IO.Compression.ZipFile]::OpenRead($archive)
$hasher = [Security.Cryptography.SHA256]::Create()
try {
    if ($check.Entries.Count -ne 26) { throw 'The finished ZIP does not contain exactly 26 files.' }
    foreach ($relative in $manifest) {
        $entry = $check.GetEntry("ChillZoneUnion/$relative")
        if ($null -eq $entry) { throw "The finished ZIP is missing: $relative" }
        $sourceHash = [Convert]::ToHexString($hasher.ComputeHash([IO.File]::ReadAllBytes((Join-Path $repoRoot $relative))))
        $entryStream = $entry.Open()
        try { $entryHash = [Convert]::ToHexString($hasher.ComputeHash($entryStream)) }
        finally { $entryStream.Dispose() }
        if ($sourceHash -cne $entryHash) { throw "The ZIP content differs from the source: $relative" }
    }
} finally { $hasher.Dispose(); $check.Dispose() }
$sha256 = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant()
if ($env:GITHUB_OUTPUT) {
    Add-Content -LiteralPath $env:GITHUB_OUTPUT -Value "archive=$archive" -Encoding utf8
    Add-Content -LiteralPath $env:GITHUB_OUTPUT -Value "sha256=$sha256" -Encoding utf8
}
[pscustomobject]@{ Version = $version; Tag = $tag; Archive = $archive; SHA256 = $sha256; FileCount = 26 }
