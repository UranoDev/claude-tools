<#
.SYNOPSIS
    Cut a CalVer release in one shot: (optionally refresh the issue cache) ->
    regenerate CHANGELOG.md -> stage everything -> commit -> tag.

.DESCRIPTION
    The key ordering: CHANGELOG.md is regenerated BEFORE `git add`/`git commit`,
    so the changelog rides INSIDE the release commit -- no separate "docs" commit.

    Normal usage: make your code changes, leave them UNCOMMITTED, then run this.
    It stages the code + the freshly generated CHANGELOG.md into a single commit
    and tags it. If you already committed the code, it still works: the changelog
    change becomes its own commit before the tag.

.PARAMETER Version
    CalVer version. Default: today's date as yyyy.MM.dd. If a tag with that name
    already exists (same-day re-cut) it is bumped to .1, .2, ... -- and the same
    bumped value is used for both the CHANGELOG heading and the git tag.

.PARAMETER Message
    Commit message. Default: "Release <version>".

.PARAMETER NoRefresh
    Skip refreshing issues-resolved.json from YouTrack. By DEFAULT the release
    refreshes the cache first (via refresh-issues-resolved.ps1) so the changelog
    never ships stale; pass -NoRefresh to reuse the current cache (e.g. offline
    or when you have already refreshed and reviewed it).

.PARAMETER DryRun
    Regenerate CHANGELOG.md but DO NOT touch git -- just print the git steps it
    would run. Safe way to preview a release.

.EXAMPLE
    ./scripts/release.ps1
    ./scripts/release.ps1 -NoRefresh
    ./scripts/release.ps1 -Version 2026.08.01 -Message "Release agosto"
    ./scripts/release.ps1 -DryRun
#>
param(
    [string]$Version,
    [string]$Message,
    [switch]$NoRefresh,
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'

$RepoRoot = (git rev-parse --show-toplevel 2>$null)
if (-not $RepoRoot) { Write-Error 'Not inside a git repository.'; exit 1 }
Set-Location $RepoRoot

$scriptDir   = Join-Path $RepoRoot 'scripts'
$changelogPs = Join-Path $scriptDir 'changelog.ps1'
$refreshPs   = Join-Path $scriptDir 'refresh-issues-resolved.ps1'
$changelogMd = Join-Path $RepoRoot 'CHANGELOG.md'

if (-not $Version) { $Version = Get-Date -Format 'yyyy.MM.dd' }

# Same-day re-cut: bump .1, .2, ... if the base version tag already exists.
$existingTags = @(git tag)
$effVersion = $Version
$n = 1
while ($existingTags -contains $effVersion) { $effVersion = "$Version.$n"; $n++ }

if (-not $Message) { $Message = "Release $effVersion" }

Write-Host "== Release $effVersion ==" -ForegroundColor Cyan

# 0. Refresh the resolved-issues cache from YouTrack (default; -NoRefresh to skip).
if (-not $NoRefresh) {
    if ($DryRun) {
        Write-Host "(dry-run) & scripts/refresh-issues-resolved.ps1"
    } else {
        Write-Host "Refrescando issues-resolved.json desde YouTrack..." -ForegroundColor DarkGray
        & $refreshPs
    }
} else {
    Write-Host "Refresh omitido (-NoRefresh); usando issues-resolved.json actual." -ForegroundColor DarkGray
}

# 1. Regenerate CHANGELOG.md with the version heading BEFORE committing.
Write-Host "Generando CHANGELOG.md (version $effVersion)..." -ForegroundColor DarkGray
& $changelogPs -Mode TagWindow -AsVersion $effVersion -OutputFile $changelogMd

if ($DryRun) {
    Write-Host "(dry-run) git add -A"
    Write-Host "(dry-run) git commit -m `"$Message`""
    Write-Host "(dry-run) git tag $effVersion"
    Write-Host "Dry-run: git intacto. CHANGELOG.md si se regenero (revisalo)." -ForegroundColor Yellow
    exit 0
}

# 2. Stage everything (code + CHANGELOG.md) into one commit.
git add -A

# 3. Commit if there is anything staged; otherwise just tag the current HEAD.
git diff --cached --quiet
if ($LASTEXITCODE -eq 0) {
    Write-Warning "No hay cambios staged; se taggeara el HEAD actual sin crear commit."
} else {
    git commit -m $Message
    if ($LASTEXITCODE -ne 0) { Write-Error "git commit fallo."; exit 1 }
}

# 4. Tag the release.
git tag $effVersion
if ($LASTEXITCODE -ne 0) { Write-Error "git tag $effVersion fallo (ya existe?)."; exit 1 }

$short = git rev-parse --short HEAD
Write-Host "Listo: version $effVersion taggeada en $short." -ForegroundColor Green
# Dos renglones y no `git push && ...`: en Windows PowerShell 5.1 el `&&` no es
# un separador valido y el comando truena antes de ejecutar nada.
Write-Host "Publicar (si hay remoto):" -ForegroundColor DarkGray
Write-Host "  git push" -ForegroundColor DarkGray
Write-Host "  git push origin $effVersion" -ForegroundColor DarkGray
