<#
.SYNOPSIS
    Refresh issues-resolved.json from YouTrack -- the cache consumed by
    changelog.ps1 in DateWindow/TagWindow mode.

.DESCRIPTION
    Reads YouTrack settings from, in order: .ralph/youtrack.config.ps1 (local
    override, gitignored), .youtrack-project.ps1 (committed, no secrets),
    $HOME\.youtrack.config.ps1 (per-user credentials), or the YOUTRACK_BASE_URL
    / YOUTRACK_TOKEN / YOUTRACK_PROJECT environment variables -- see
    scripts/youtrack-credentials.ps1. The split is what makes this portable: the
    token lives once per machine, the project travels with the repo.
    Queries every RESOLVED
    issue of the project and writes them as a JSON array of
    { Id, ResolvedAt, Type, Summary }, sorted oldest-first, one object per line
    (diff-friendly), with LF line endings and no BOM.

    ResolvedAt is the issue's `resolved` timestamp converted to LOCAL time, so it
    lines up with local git commit timestamps (see the timezone caveat in
    changelog.ps1).

.PARAMETER Project
    YouTrack project short name(s), e.g. -Project FRAC or -Project FRAC,COBR
    (issue IDs carry their own prefix, so several projects can share one cache).
    When omitted it comes from $YouTrackProject in the same config cascade, so
    each repo declares its own project instead of the script hardcoding one.

.PARAMETER OutputFile
    Where to write the cache. Default: issues-resolved.json at the repo root.
    Point it elsewhere (e.g. issues-resolved.preview.json) to review before
    overwriting the real cache.

.EXAMPLE
    ./scripts/refresh-issues-resolved.ps1
    ./scripts/refresh-issues-resolved.ps1 -OutputFile issues-resolved.preview.json
#>
[CmdletBinding()]
param(
    [string[]]$Project,
    [string]$OutputFile
)

$ErrorActionPreference = 'Stop'

$RepoRoot = (git rev-parse --show-toplevel 2>$null)
if (-not $RepoRoot) { Write-Error 'Not inside a git repository.'; exit 1 }

if (-not $OutputFile) {
    $OutputFile = Join-Path $RepoRoot 'issues-resolved.json'
} elseif (-not [System.IO.Path]::IsPathRooted($OutputFile)) {
    $OutputFile = Join-Path (Get-Location).Path $OutputFile
}

# Credentials: repo -> user -> env cascade (see scripts/youtrack-credentials.ps1).
# The first link is still the same .ralph/youtrack.config.ps1 ralph.ps1 uses, so
# nothing changes for a repo that already had it; -Require aborts with the list
# of every location checked.
. (Join-Path $PSScriptRoot 'youtrack-credentials.ps1')
# -RequireProject only when -Project was not passed: an explicit flag always
# wins over whatever the config says.
$cred = Resolve-YouTrackCredentials -RepoRoot $RepoRoot -Require -RequireProject:(-not $Project)
$YouTrackBaseUrl = $cred.BaseUrl
$YouTrackToken   = $cred.Token
if (-not $Project) { $Project = $cred.Project }
Write-Verbose "Credenciales: URL desde $($cred.BaseUrlSource); token desde $($cred.TokenSource)"
Write-Verbose "Proyecto(s): $($Project -join ', ')"

$headers = @{ Authorization = "Bearer $YouTrackToken"; Accept = 'application/json' }
$fields  = 'idReadable,summary,resolved,customFields(name,value(name))'
# "project: A, B" is YouTrack's OR within a field, so one query covers them all.
$query   = "project: $($Project -join ', ') #Resolved"
$uri     = "$YouTrackBaseUrl/api/issues?fields=$fields&`$top=1000&query=$([uri]::EscapeDataString($query))"

$raw = Invoke-RestMethod -Uri $uri -Headers $headers -Method Get

$issues = foreach ($i in $raw) {
    if (-not $i.resolved) { continue }   # skip anything without a resolved date
    $typeField = $i.customFields | Where-Object { $_.name -eq 'Type' } | Select-Object -First 1
    $type = if ($typeField -and $typeField.value) { $typeField.value.name } else { '' }
    $resolvedLocal = [DateTimeOffset]::FromUnixTimeMilliseconds([long]$i.resolved).LocalDateTime
    [PSCustomObject]@{
        Id         = $i.idReadable
        ResolvedAt = $resolvedLocal.ToString('yyyy-MM-dd HH:mm:ss')
        Type       = $type
        Summary    = $i.summary
    }
}

$issues = @($issues | Sort-Object { [datetime]$_.ResolvedAt })

# Minimal JSON string escaper (backslash, quote, control chars).
function ConvertTo-JsonString([string]$s) {
    if ($null -eq $s) { return '""' }
    $e = $s -replace '\\', '\\' -replace '"', '\"' -replace "`r", '' -replace "`n", '\n' -replace "`t", '\t'
    '"' + $e + '"'
}

$lines = foreach ($it in $issues) {
    '    { "Id": '        + (ConvertTo-JsonString $it.Id) +
    ', "ResolvedAt": '    + (ConvertTo-JsonString $it.ResolvedAt) +
    ', "Type": '          + (ConvertTo-JsonString $it.Type) +
    ', "Summary": '       + (ConvertTo-JsonString $it.Summary) + ' }'
}

$text = "[`n" + ($lines -join ",`n") + "`n]`n"
[System.IO.File]::WriteAllText($OutputFile, $text, (New-Object System.Text.UTF8Encoding($false)))

Write-Host "issues-resolved: $($issues.Count) resueltos de $($Project -join ', ') escritos en $OutputFile"
