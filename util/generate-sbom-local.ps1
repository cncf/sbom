<#
.SYNOPSIS
    Local SBOM Generation Script for Windows

.DESCRIPTION
    Thin wrapper around util/generate-sbom-local.sh so Windows and CI share one
    implementation. Needs bash (Git for Windows or WSL) plus the tools the shell
    script lists: git, gh, jq, yq, curl.

.PARAMETER ProjectFilter
    Filter by owner/repo (e.g., "kubernetes/kubernetes"). Leave empty for all.

.PARAMETER Force
    Force regenerate existing SBOMs

.PARAMETER MaxReleases
    Maximum releases to process per repo (default: 3)

.EXAMPLE
    .\generate-sbom-local.ps1 -Force -ProjectFilter "coredns/coredns"
#>

param(
    [Parameter(Position = 0)]
    [string]$ProjectFilter = "",

    [switch]$Force,

    [int]$MaxReleases = 3
)

$ErrorActionPreference = "Stop"

if (-not (Get-Command bash -ErrorAction SilentlyContinue)) {
    Write-Error "bash not found. Install Git for Windows (ships bash) or WSL."
}

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Script = (Join-Path $ScriptDir "generate-sbom-local.sh") -replace '\\', '/'
$BashArgs = @()
if ($Force) { $BashArgs += "--force" }
if ($ProjectFilter) { $BashArgs += $ProjectFilter }

$env:MAX_RELEASES = "$MaxReleases"
& bash $Script @BashArgs
exit $LASTEXITCODE
