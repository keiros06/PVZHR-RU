[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$GameSource,

    [string]$OutputDirectory,

    [switch]$Force,

    [switch]$ValidateOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$releaseName = 'PvZ-Hybrid-Remake-RU-v0.6'
$exeName = '植物大战僵尸杂交版发布版0.26.1.Csharp.exe'
$pckName = '植物大战僵尸杂交版发布版0.26.1.Csharp.pck'
$runtimeDirectoryName = 'data_PlantsVsZombies_windows_x86_64'

$repositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$readmePath = Join-Path $repositoryRoot 'README.md'
$logoPath = Join-Path $repositoryRoot 'assets\logo.png'

if (-not (Test-Path -LiteralPath $GameSource -PathType Container)) {
    throw "Game source folder not found: $GameSource"
}

$gameRoot = (Resolve-Path -LiteralPath $GameSource).Path.TrimEnd('\')
$exePath = Join-Path $gameRoot $exeName
$pckPath = Join-Path $gameRoot $pckName
$runtimeDirectory = Join-Path $gameRoot $runtimeDirectoryName

$requiredFiles = @(
    $exePath,
    $pckPath,
    (Join-Path $runtimeDirectory 'PlantsVsZombies.dll'),
    (Join-Path $runtimeDirectory 'PlantsVsZombies.deps.json'),
    (Join-Path $runtimeDirectory 'PlantsVsZombies.runtimeconfig.json'),
    (Join-Path $runtimeDirectory 'GodotSharp.dll'),
    (Join-Path $runtimeDirectory 'coreclr.dll'),
    (Join-Path $runtimeDirectory 'hostfxr.dll'),
    (Join-Path $runtimeDirectory 'hostpolicy.dll'),
    $readmePath,
    $logoPath
)

foreach ($requiredFile in $requiredFiles) {
    if (-not (Test-Path -LiteralPath $requiredFile -PathType Leaf)) {
        throw "Required release file is missing: $requiredFile"
    }
}

if (-not (Test-Path -LiteralPath $runtimeDirectory -PathType Container)) {
    throw "Required runtime directory is missing: $runtimeDirectory"
}

$rootPcks = @(Get-ChildItem -LiteralPath $gameRoot -File -Filter '*.pck')
if ($rootPcks.Count -ne 1 -or $rootPcks[0].Name -cne $pckName) {
    $found = ($rootPcks | ForEach-Object Name) -join ', '
    throw "Expected exactly one active root PCK named '$pckName'. Found: $found"
}

$runtimeSourceFiles = @(
    Get-Item -LiteralPath $exePath
    Get-Item -LiteralPath $pckPath
    Get-ChildItem -LiteralPath $runtimeDirectory -File -Recurse -Force
)

$runtimeBytes = [int64](($runtimeSourceFiles | Measure-Object Length -Sum).Sum)
Write-Host "Validated runtime source: $gameRoot"
Write-Host "  Files: $($runtimeSourceFiles.Count)"
Write-Host "  Bytes: $runtimeBytes"
Write-Host "  Active PCK: $pckName"

if ($ValidateOnly) {
    Write-Host 'Validation completed. No staging folder or archive was created.'
    return
}

if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    $OutputDirectory = Join-Path $repositoryRoot 'dist'
} elseif (-not [IO.Path]::IsPathRooted($OutputDirectory)) {
    $OutputDirectory = Join-Path $repositoryRoot $OutputDirectory
}

$outputRoot = [IO.Path]::GetFullPath($OutputDirectory)
New-Item -ItemType Directory -Path $outputRoot -Force | Out-Null

$archivePath = Join-Path $outputRoot ($releaseName + '.zip')
$partialArchivePath = $archivePath + '.partial'
if ((Test-Path -LiteralPath $archivePath) -and -not $Force) {
    throw "Archive already exists. Use -Force to replace it after a successful rebuild: $archivePath"
}

$temporaryBase = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
$temporaryRoot = Join-Path $temporaryBase ('pvz-hybrid-release-' + [Guid]::NewGuid().ToString('N'))
$stagingParent = Join-Path $temporaryRoot 'payload'
$releaseRoot = Join-Path $stagingParent $releaseName

function Get-FileSha256([string]$Path) {
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
}

function Get-StreamSha256([IO.Stream]$Stream) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $bytes = $sha.ComputeHash($Stream)
        return ([BitConverter]::ToString($bytes)).Replace('-', '')
    } finally {
        $sha.Dispose()
    }
}

try {
    if (Test-Path -LiteralPath $partialArchivePath) {
        [IO.File]::Delete($partialArchivePath)
    }

    New-Item -ItemType Directory -Path $releaseRoot -Force | Out-Null

    $sourceStateBefore = @{}
    foreach ($sourceFile in $runtimeSourceFiles) {
        $sourceStateBefore[$sourceFile.FullName] = "$($sourceFile.Length)|$($sourceFile.LastWriteTimeUtc.Ticks)"
    }

    Copy-Item -LiteralPath $exePath -Destination (Join-Path $releaseRoot $exeName)
    Copy-Item -LiteralPath $pckPath -Destination (Join-Path $releaseRoot $pckName)
    Copy-Item -LiteralPath $runtimeDirectory -Destination (Join-Path $releaseRoot $runtimeDirectoryName) -Recurse

    $publicAssets = Join-Path $releaseRoot 'docs\assets'
    New-Item -ItemType Directory -Path $publicAssets -Force | Out-Null
    Copy-Item -LiteralPath $logoPath -Destination (Join-Path $publicAssets 'logo.png')

    $readmeText = [IO.File]::ReadAllText($readmePath, [Text.Encoding]::UTF8)
    $readmeText = $readmeText.Replace('src="assets/logo.png"', 'src="docs/assets/logo.png"')
    [IO.File]::WriteAllText((Join-Path $releaseRoot 'README.md'), $readmeText, (New-Object Text.UTF8Encoding($false)))

    foreach ($sourceFile in $runtimeSourceFiles) {
        $relativePath = $sourceFile.FullName.Substring($gameRoot.Length).TrimStart('\')
        $stagedPath = Join-Path $releaseRoot $relativePath
        if (-not (Test-Path -LiteralPath $stagedPath -PathType Leaf)) {
            throw "Runtime file was not staged: $relativePath"
        }
        if ($sourceFile.Length -ne (Get-Item -LiteralPath $stagedPath).Length) {
            throw "Size mismatch after staging: $relativePath"
        }
        if ((Get-FileSha256 $sourceFile.FullName) -ne (Get-FileSha256 $stagedPath)) {
            throw "SHA-256 mismatch after staging: $relativePath"
        }
    }

    foreach ($sourceFile in $runtimeSourceFiles) {
        $current = Get-Item -LiteralPath $sourceFile.FullName
        $currentState = "$($current.Length)|$($current.LastWriteTimeUtc.Ticks)"
        if ($sourceStateBefore[$sourceFile.FullName] -ne $currentState) {
            throw "Source changed during release staging: $($sourceFile.FullName)"
        }
    }

    $forbiddenNames = @('backups', '_QUARANTINE_UNUSED', 'QUARANTINE_MANIFEST.json', 'RESTORE_QUARANTINE.ps1', '杂交版启动补丁.cs.hta')
    foreach ($forbiddenName in $forbiddenNames) {
        if (Get-ChildItem -LiteralPath $releaseRoot -Recurse -Force | Where-Object Name -CEQ $forbiddenName) {
            throw "Forbidden internal file entered the release staging folder: $forbiddenName"
        }
    }

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [IO.Compression.ZipFile]::CreateFromDirectory(
        $stagingParent,
        $partialArchivePath,
        [IO.Compression.CompressionLevel]::Optimal,
        $false
    )

    $stagedFiles = @(Get-ChildItem -LiteralPath $stagingParent -File -Recurse -Force)
    $zip = [IO.Compression.ZipFile]::OpenRead($partialArchivePath)
    try {
        $entries = @($zip.Entries | Where-Object { -not $_.FullName.EndsWith('/') })
        if ($entries.Count -ne $stagedFiles.Count) {
            throw "Archive file count mismatch: $($entries.Count) != $($stagedFiles.Count)"
        }

        foreach ($entry in $entries) {
            $entryName = $entry.FullName.Replace('\', '/')
            if (-not $entryName.StartsWith($releaseName + '/')) {
                throw "Unexpected archive root: $($entry.FullName)"
            }
            $stagedPath = Join-Path $stagingParent ($entryName.Replace('/', '\'))
            if (-not (Test-Path -LiteralPath $stagedPath -PathType Leaf)) {
                throw "Archive entry has no staged source: $($entry.FullName)"
            }
            if ($entry.Length -ne (Get-Item -LiteralPath $stagedPath).Length) {
                throw "Archive entry size mismatch: $($entry.FullName)"
            }
            $stream = $entry.Open()
            try {
                $entryHash = Get-StreamSha256 $stream
            } finally {
                $stream.Dispose()
            }
            if ($entryHash -ne (Get-FileSha256 $stagedPath)) {
                throw "Archive entry SHA-256 mismatch: $($entry.FullName)"
            }
        }
    } finally {
        $zip.Dispose()
    }

    Move-Item -LiteralPath $partialArchivePath -Destination $archivePath -Force
    $archive = Get-Item -LiteralPath $archivePath
    $archiveHash = Get-FileSha256 $archivePath

    Write-Host ''
    Write-Host 'Release archive created and fully verified.'
    Write-Host "Path: $($archive.FullName)"
    Write-Host "Size: $($archive.Length) bytes"
    Write-Host "SHA-256: $archiveHash"
} finally {
    if (Test-Path -LiteralPath $temporaryRoot) {
        $resolvedTemporaryRoot = [IO.Path]::GetFullPath($temporaryRoot)
        if (-not $resolvedTemporaryRoot.StartsWith($temporaryBase + '\', [StringComparison]::OrdinalIgnoreCase)) {
            throw "Refusing to remove an unsafe temporary path: $resolvedTemporaryRoot"
        }
        [IO.Directory]::Delete($resolvedTemporaryRoot, $true)
    }
    if (Test-Path -LiteralPath $partialArchivePath) {
        [IO.File]::Delete($partialArchivePath)
    }
}
