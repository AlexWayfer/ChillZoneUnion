[CmdletBinding()]
param(
    [string]$Version = $env:RELEASE_VERSION,
    [string]$Tag = $env:RELEASE_TAG,
    [string]$Archive = $env:RELEASE_ARCHIVE,
    [string]$SHA256 = $env:RELEASE_SHA256
)
$ErrorActionPreference = 'Stop'
$repo = $env:GITHUB_REPOSITORY
$head = $env:GITHUB_SHA
$api = $env:GITHUB_API_URL
if (-not $api) { $api = 'https://api.github.com' }
$api = $api.TrimEnd('/')
if ($api -cne 'https://api.github.com' -or -not $env:GH_TOKEN) { throw 'An authenticated github.com Actions context is required.' }
if ($repo -cnotmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$' -or $head -cnotmatch '^[0-9a-f]{40}$') { throw 'Invalid repository or triggering commit.' }
if ($Version -cnotmatch '^[0-9]+\.[0-9]+\.[0-9]+(?:-[A-Za-z0-9][A-Za-z0-9.-]*)?$' -or $Tag -cne "v$Version") { throw 'Invalid release version or tag.' }
if ($SHA256 -cnotmatch '^[0-9a-f]{64}$' -or -not (Test-Path -LiteralPath $Archive -PathType Leaf)) { throw 'A verified ZIP and SHA256 are required.' }
if ((Get-FileHash -LiteralPath $Archive -Algorithm SHA256).Hash.ToLowerInvariant() -cne $SHA256) { throw 'The local package checksum changed.' }
$fileName = "ChillZoneUnion-$Version.zip"
if ((Split-Path -Leaf $Archive) -cne $fileName) { throw 'The ZIP filename does not match the release version.' }
$headers = @{ Authorization = "Bearer $env:GH_TOKEN"; Accept = 'application/vnd.github+json'; 'X-GitHub-Api-Version' = '2022-11-28' }

function Read-Api([string]$Path, [switch]$AllowMissing) {
    $response = Invoke-WebRequest -Uri "$api/repos/$repo/$Path" -Headers $headers -SkipHttpErrorCheck
    if ($response.StatusCode -eq 404 -and $AllowMissing) { return }
    if ($response.StatusCode -ne 200) { throw "GitHub GET failed with HTTP $($response.StatusCode): $Path" }
    return $response.Content | ConvertFrom-Json
}
function Write-Api([string]$Path, [string]$Method, [hashtable]$Body, [int]$ExpectedStatus) {
    $response = Invoke-WebRequest -Uri "$api/repos/$repo/$Path" -Method $Method -Headers $headers -ContentType 'application/json' -Body ($Body | ConvertTo-Json -Depth 10 -Compress) -SkipHttpErrorCheck
    if ($response.StatusCode -ne $ExpectedStatus) { throw "GitHub $Method failed with HTTP $($response.StatusCode): $Path" }
    return $response.Content | ConvertFrom-Json
}
function Read-Release([long]$Id) {
    for ($attempt = 0; $attempt -lt 4; $attempt++) {
        $release = Read-Api "releases/$Id" -AllowMissing
        if ($null -ne $release) { return $release }
        if ($attempt -lt 3) { Start-Sleep -Seconds 2 }
    }
    throw "Release $Id is not visible by its stable ID; nothing was published."
}
function Tag-Commit {
    $reference = Read-Api ('git/ref/tags/' + [Uri]::EscapeDataString($Tag)) -AllowMissing
    if ($null -eq $reference) { return }
    $object = $reference.object
    for ($depth = 0; $depth -lt 8; $depth++) {
        if ($object.type -eq 'commit') { return [string]$object.sha }
        if ($object.type -ne 'tag') { throw 'Release tag does not resolve to a commit.' }
        $object = (Read-Api ('git/tags/' + $object.sha)).object
    }
    throw 'Release tag nesting exceeds the safety limit.'
}
function Find-Release {
    $release = Read-Api ('releases/tags/' + [Uri]::EscapeDataString($Tag)) -AllowMissing
    if ($null -ne $release) { return $release }
    for ($page = 1; $page -le 100; $page++) {
        $items = @(Read-Api "releases?per_page=100&page=$page")
        foreach ($item in $items) { if ($item.tag_name -ceq $Tag) { return $item } }
        if ($items.Count -lt 100) { return }
    }
    throw 'Release discovery exceeded its pagination limit.'
}
function Zip-Blobs {
    $allowed = @('Bindings.xml','Chat.lua','ChillZoneUnion.toc','Core.lua','LICENSE.txt','Network.lua','Presence.lua','Protocol.lua','README.txt','Roster.lua','SECURITY.txt','Stats.lua','Transfers.lua','UI.lua','Union.lua',
        'Libs/LibDeflate.lua','Libs/LibStub.lua','Media/arrow-down.tga','Media/arrow-left.tga','Media/arrow-right.tga','Media/arrow-up.tga','Media/minimap.tga','Media/status-dot.tga','Tests/run-lua.ps1','Tests/security.lua','Tests/simulation.lua')
    $blobs = [Collections.Generic.Dictionary[string,string]]::new([StringComparer]::Ordinal)
    $zip = [IO.Compression.ZipFile]::OpenRead($Archive)
    $hasher = [Security.Cryptography.SHA1]::Create()
    try {
        if ($zip.Entries.Count -ne 26) { throw 'The ZIP must contain exactly 26 addon files.' }
        foreach ($entry in $zip.Entries) {
            if (-not $entry.FullName.StartsWith('ChillZoneUnion/', [StringComparison]::Ordinal)) { throw 'The ZIP has an unexpected top-level folder.' }
            $relative = $entry.FullName.Substring('ChillZoneUnion/'.Length)
            if ($allowed -cnotcontains $relative -or $blobs.ContainsKey($relative) -or $entry.Length -gt 2000000) { throw "Unexpected ZIP entry: $($entry.FullName)" }
            $memory = [IO.MemoryStream]::new()
            $stream = $entry.Open()
            try { $stream.CopyTo($memory); $bytes = $memory.ToArray() } finally { $stream.Dispose(); $memory.Dispose() }
            if ($relative -eq 'ChillZoneUnion.toc' -and [Text.Encoding]::UTF8.GetString($bytes) -cnotmatch ('(?m)^## Version:\s*' + [regex]::Escape($Version) + '\s*$')) { throw 'The ZIP TOC version does not match the release.' }
            $prefix = [Text.Encoding]::ASCII.GetBytes("blob $($bytes.Length)" + [char]0)
            $gitObject = [byte[]]::new($prefix.Length + $bytes.Length)
            [Buffer]::BlockCopy($prefix, 0, $gitObject, 0, $prefix.Length)
            [Buffer]::BlockCopy($bytes, 0, $gitObject, $prefix.Length, $bytes.Length)
            $blobs[$relative] = [Convert]::ToHexString($hasher.ComputeHash($gitObject)).ToLowerInvariant()
        }
    } finally { $hasher.Dispose(); $zip.Dispose() }
    return ,$blobs
}
function Verify-Tree([string]$Commit, $Blobs) {
    $commitObject = Read-Api "git/commits/$Commit"
    if ($commitObject.sha -cne $Commit -or $commitObject.tree.sha -cnotmatch '^[0-9a-f]{40}$') { throw 'Unexpected Git commit response.' }
    $tree = Read-Api ("git/trees/" + $commitObject.tree.sha + '?recursive=1')
    if ($tree.truncated) { throw 'The Git tree is truncated; addon identity cannot be verified.' }
    $files = @{}
    foreach ($entry in $tree.tree) { $files[$entry.path] = $entry }
    foreach ($relative in $Blobs.Keys) {
        $entry = $files[$relative]
        if ($null -eq $entry -or $entry.type -ne 'blob' -or $entry.mode -notin @('100644','100755') -or $entry.sha -cne $Blobs[$relative]) {
            throw "Addon file differs from commit ${Commit}: $relative"
        }
    }
}
function Verify-Release($Release, [long]$Id, [bool]$Prerelease) {
    if ($null -eq $Release -or $Release.id -ne $Id -or $Release.tag_name -cne $Tag -or [bool]$Release.prerelease -ne $Prerelease) { throw 'Unexpected release identity or prerelease status.' }
}
function Verify-Asset([long]$AssetId, $Release, [string]$ExpectedHash) {
    $matching = @($Release.assets | Where-Object { $_.id -eq $AssetId -and $_.name -ceq $fileName -and $_.state -eq 'uploaded' })
    if ($matching.Count -ne 1) { throw 'The release does not contain the expected uploaded ZIP asset.' }
    $asset = Read-Api "releases/assets/$AssetId"
    if ($asset.id -ne $AssetId -or $asset.name -cne $fileName -or $asset.state -ne 'uploaded' -or $asset.size -ne (Get-Item -LiteralPath $Archive).Length) { throw 'Unexpected asset identity, state or size.' }
    if ($asset.digest -and $asset.digest -cne "sha256:$ExpectedHash") { throw 'The server asset digest does not match the verified package.' }
    $temporary = $env:RUNNER_TEMP
    if (-not $temporary) { $temporary = [IO.Path]::GetTempPath() }
    $download = Join-Path $temporary ('cz-release-' + [Guid]::NewGuid().ToString('N') + '.zip')
    $downloadHeaders = $headers.Clone(); $downloadHeaders.Accept = 'application/octet-stream'
    $response = Invoke-WebRequest -Uri "$api/repos/$repo/releases/assets/$AssetId" -Headers $downloadHeaders -OutFile $download -PassThru -SkipHttpErrorCheck
    if ($response.StatusCode -ne 200 -or (Get-FileHash -LiteralPath $download -Algorithm SHA256).Hash.ToLowerInvariant() -cne $ExpectedHash) { throw 'Downloaded release asset checksum verification failed.' }
}

$isPrerelease = $Version.Contains('-')
$blobs = Zip-Blobs
Verify-Tree $head $blobs
$resume = $null
if ($Tag -ceq 'v0.5.0-beta') {
    $resume = @{ id = 436409326L; asset = 716900130L; commit = '38c3912e0210da035f89e157c232de02429f7772'; hash = 'ed863b30fa2638d4c0ce3622ce693aaa9adf3e3bd437d8d080ae7e7087c982b9' }
}
if ($resume) {
    if ($repo -cne 'Azired/ChillZoneUnion' -or $SHA256 -cne $resume.hash -or (Tag-Commit) -cne $resume.commit) { throw 'The explicitly approved recovery target or package does not match.' }
    Verify-Tree $resume.commit $blobs
    $releaseId = $resume.id
    $release = Read-Release $releaseId
    Verify-Release $release $releaseId $true
    Verify-Asset $resume.asset $release $resume.hash
    $expectedCommit = $resume.commit
} else {
    $existing = Find-Release
    if ($null -ne $existing) {
        if ($existing.draft) { throw 'An existing draft requires explicit reviewed recovery by ID.' }
        Write-Output "Release $Tag already exists and will remain unchanged."
        return
    }
    $expectedCommit = $head
    $tagCommit = Tag-Commit
    if ($tagCommit -and $tagCommit -cne $head) { throw 'The existing release tag points to a different commit.' }
    $notes = Join-Path (Split-Path -Parent $PSScriptRoot) ('.github/releases/' + $Version + '.md')
    if (-not (Test-Path -LiteralPath $notes -PathType Leaf)) { throw "Release notes are required: $notes" }
    if (-not $tagCommit) { Write-Api 'git/refs' 'POST' @{ ref = "refs/tags/$Tag"; sha = $head } 201 | Out-Null }
    if ((Tag-Commit) -cne $head) { throw 'The release tag does not match the tested commit.' }
    $created = Write-Api 'releases' 'POST' @{ tag_name = $Tag; target_commitish = $head; name = "ChillZoneUnion $Version"; body = [IO.File]::ReadAllText($notes); draft = $true; prerelease = $isPrerelease; make_latest = 'false' } 201
    if ($created.id -lt 1) { throw 'GitHub did not return the created draft ID.' }
    $releaseId = [long]$created.id
    Verify-Release $created $releaseId $isPrerelease
    if (-not $created.draft) { throw 'GitHub did not create the expected draft.' }
    $uploadBase = [string]$created.upload_url -replace '\{\?[^}]+\}$', ''
    $uploadUri = [Uri]$uploadBase
    $expectedPath = "/repos/$repo/releases/$releaseId/assets"
    if ($uploadUri.Scheme -ne 'https' -or $uploadUri.Host -ne 'uploads.github.com' -or $uploadUri.Port -ne 443 -or $uploadUri.AbsolutePath -cne $expectedPath -or $uploadUri.Query -or $uploadUri.Fragment -or $uploadUri.UserInfo) { throw 'GitHub returned an unexpected asset upload URL.' }
    $upload = Invoke-WebRequest -Uri ("${uploadBase}?name=" + [Uri]::EscapeDataString($fileName)) -Method POST -Headers $headers -ContentType 'application/zip' -InFile $Archive -SkipHttpErrorCheck
    if ($upload.StatusCode -ne 201) { throw "Asset upload failed with HTTP $($upload.StatusCode); draft $releaseId remains unpublished." }
    $asset = $upload.Content | ConvertFrom-Json
    if ($asset.id -lt 1) { throw 'GitHub did not return the uploaded asset ID.' }
    $release = Read-Release $releaseId
    Verify-Release $release $releaseId $isPrerelease
    Verify-Asset ([long]$asset.id) $release $SHA256
}
if ((Tag-Commit) -cne $expectedCommit) { throw 'The release tag changed before publication.' }
if (-not $release.draft) {
    Write-Output "Release $Tag is already published and its verified asset is unchanged."
    return
}
$published = Write-Api "releases/$releaseId" 'PATCH' @{ draft = $false; prerelease = $isPrerelease; make_latest = 'false' } 200
Verify-Release $published $releaseId $isPrerelease
$verified = Read-Release $releaseId
Verify-Release $verified $releaseId $isPrerelease
if ($verified.draft -or (Tag-Commit) -cne $expectedCommit) { throw 'The final published release state or tag could not be verified.' }
Write-Output "Published $($verified.html_url) from commit $expectedCommit; asset SHA256 $SHA256"
