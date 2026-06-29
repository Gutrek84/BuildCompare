[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, HelpMessage = "Your CurseForge API Key / Token")]
    [string]$ApiKey,

    [Parameter(Mandatory = $false, HelpMessage = "Release type: release, beta, or alpha")]
    [ValidateSet("release", "beta", "alpha")]
    [string]$ReleaseType = "release",

    [Parameter(Mandatory = $false, HelpMessage = "Changelog for this release")]
    [string]$Changelog = "",

    [Parameter(Mandatory = $false, HelpMessage = "Custom game version IDs (comma-separated list of integers). Overrides auto-detection.")]
    [int[]]$GameVersionIds
)

$ErrorActionPreference = "Stop"

# 1. Paths Setup
$projectRoot = $PSScriptRoot
$addonDir = Join-Path $projectRoot "BuildCompare"
$tocPath = Join-Path $addonDir "BuildCompare.toc"
$zipPath = Join-Path $projectRoot "BuildCompare-release.zip"

Write-Host "--- BuildCompare CurseForge Publisher ---" -ForegroundColor Cyan

# Verify files exist
if (-not (Test-Path $tocPath)) {
    Write-Error "Could not find BuildCompare.toc at $tocPath. Make sure this script is run from the workspace root."
    exit 1
}

# 2. Retrieve version and interface version from TOC
Write-Host "Parsing version and interface version from BuildCompare.toc..."
$tocContent = Get-Content $tocPath
$versionLine = $tocContent | Select-String -Pattern "## Version:\s*(.+)"
$interfaceLine = $tocContent | Select-String -Pattern "## Interface:\s*(\d+)"

if (-not $versionLine) {
    Write-Error "Could not find '## Version' line in BuildCompare.toc"
    exit 1
}
if (-not $interfaceLine) {
    Write-Error "Could not find '## Interface' line in BuildCompare.toc"
    exit 1
}

$addonVersion = $versionLine.Matches.Groups[1].Value.Trim()
$interfaceVersion = $interfaceLine.Matches.Groups[1].Value.Trim()

Write-Host "Addon Version: $addonVersion" -ForegroundColor Green
Write-Host "TOC Interface: $interfaceVersion" -ForegroundColor Green

# Define display name
$displayName = "BuildCompare v$addonVersion"

# 3. Determine Compatible Game Version IDs
$targetVersionIds = @()

if ($GameVersionIds -and $GameVersionIds.Count -gt 0) {
    Write-Host "Using user-specified Game Version IDs: $($GameVersionIds -join ', ')"
    $targetVersionIds = $GameVersionIds
} else {
    Write-Host "Fetching compatible game versions from CurseForge API..."
    $headers = @{ "X-Api-Token" = $ApiKey }
    try {
        $versions = Invoke-RestMethod -Uri "https://wow.curseforge.com/api/game/versions" -Headers $headers -Method Get
    } catch {
        Write-Error "Failed to fetch game versions from CurseForge: $_"
        exit 1
    }

    # Parse interface version to major.minor
    # 120000 -> major: 12, minor: 0
    # 110007 -> major: 11, minor: 0
    $interfaceNum = [int]$interfaceVersion
    $major = [Math]::Floor($interfaceNum / 10000)
    $minor = [Math]::Floor(($interfaceNum % 10000) / 100)

    $searchPrefix = "$major.$minor"
    Write-Host "Searching for game versions matching prefix: '$searchPrefix'"
    $matched = $versions | Where-Object { $_.name -like "$searchPrefix*" }
    
    if ($null -eq $matched -or $matched.Count -eq 0) {
        Write-Host "No versions found matching '$searchPrefix', trying fallback to major version '$major.*'"
        $matched = $versions | Where-Object { $_.name -like "$major.*" }
    }

    if ($null -ne $matched) {
        # Filter for standard numerical versions (avoiding things like "-classic", beta, etc., unless they are standard)
        foreach ($v in $matched) {
            if ($v.name -match "^\d+\.\d+(\.\d+)?$") {
                $targetVersionIds += $v.id
                Write-Host "  Found compatible game version: $($v.name) (ID: $($v.id))"
            }
        }
    }

    if ($targetVersionIds.Count -eq 0) {
        Write-Warning "Could not automatically resolve compatible game version IDs from CurseForge API."
        Write-Warning "Defaulting to all game versions matching major WoW version $major."
        # Select all versions matching major version as fallback
        $fallbackVersions = $versions | Where-Object { $_.name -like "$major.*" }
        foreach ($v in $fallbackVersions) {
            $targetVersionIds += $v.id
            Write-Host "  Fallback compatible game version: $($v.name) (ID: $($v.id))"
        }
    }

    if ($targetVersionIds.Count -eq 0) {
        Write-Error "No compatible game versions could be found or resolved."
        exit 1
    }
}

# 4. Prepare Staging Directory
$tempDir = Join-Path $env:TEMP "BuildCompare_Release_Staging"
if (Test-Path $tempDir) {
    Remove-Item -Recurse -Force $tempDir
}
$addonStageDir = Join-Path $tempDir "BuildCompare"
New-Item -ItemType Directory -Path $addonStageDir -Force | Out-Null

# Files to package
$filesToStage = @(
    "Core.lua",
    "UI.lua",
    "Utils.lua",
    "BuildCompare.toc",
    "README.md"
)

Write-Host "Staging files to temporary directory..."
foreach ($file in $filesToStage) {
    $src = Join-Path $addonDir $file
    if (-not (Test-Path $src)) {
        Write-Error "Required file not found: $src"
        exit 1
    }
    Copy-Item $src $addonStageDir -Force
    Write-Host "  Staged $file"
}

# 5. Compress into Zip
Write-Host "Compressing addon into release zip..."
if (Test-Path $zipPath) {
    Remove-Item $zipPath -Force
}
Compress-Archive -Path $addonStageDir -DestinationPath $zipPath -Force
Write-Host "Created Zip: $zipPath" -ForegroundColor Green

# 6. Create Metadata JSON
$metadataObj = @{
    changelog = if ([string]::IsNullOrEmpty($Changelog)) { "Release v$addonVersion" } else { $Changelog }
    changelogType = "text"
    displayName = $displayName
    gameVersions = $targetVersionIds
    releaseType = $ReleaseType
}

$metadataPath = Join-Path $tempDir "metadata.json"
$metadataJson = $metadataObj | ConvertTo-Json -Compress
[System.IO.File]::WriteAllText($metadataPath, $metadataJson)

# 7. Upload to CurseForge using curl.exe
Write-Host "Uploading to CurseForge..."
$uploadUrl = "https://wow.curseforge.com/api/projects/1591622/upload-file"

$curlCmd = "curl.exe"
$curlArgs = @(
    "-s", "-w", "\nHTTP_STATUS:%{http_code}\n",
    "-X", "POST",
    $uploadUrl,
    "-H", "X-Api-Token: $ApiKey",
    "-F", "metadata=<$metadataPath",
    "-F", "file=@$zipPath"
)

Write-Host "Executing curl command..."
$curlOutput = & $curlCmd $curlArgs

# Check curl output and status code
$httpStatus = 0
$responseBody = ""

foreach ($line in $curlOutput) {
    if ($line -match "HTTP_STATUS:(\d+)") {
        $httpStatus = [int]$Matches[1]
    } else {
        $responseBody += $line + "`n"
    }
}

# 8. Clean up Staging
Write-Host "Cleaning up staging directory..."
if (Test-Path $tempDir) {
    Remove-Item -Recurse -Force $tempDir
}

# 9. Verify Success
if ($httpStatus -eq 200 -or $httpStatus -eq 201) {
    Write-Host "Successfully published BuildCompare v$addonVersion to CurseForge!" -ForegroundColor Green
    Write-Host "Response: $responseBody"
} else {
    Write-Error "Failed to publish addon. HTTP Status: $httpStatus"
    Write-Error "Response details: $responseBody"
    exit 1
}
