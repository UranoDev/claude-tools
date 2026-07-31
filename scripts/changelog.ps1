<#
.SYNOPSIS
    Generic changelog generator with three mutually exclusive modes: Regex
    (ticket ID pattern in the commit subject), DateWindow (issue closing date
    falls within the window between two consecutive commits), or TagWindow
    (same idea but the windows are bounded by git tags = versions).

.DESCRIPTION
    No language/framework dependencies beyond git being on PATH (DateWindow
    mode additionally needs a resolved-issues cache file — see below). Copy
    this file into any git repo and run it as-is with PowerShell.

    Per-repo overrides: create a `.changelogrc.ps1` file at the repo root
    (it is dot-sourced) to set any of:
        $TicketRegex        = '[A-Z]+-[0-9]+'   # Regex mode: pattern to pull ticket IDs from the subject line
        $OutputFile         = 'CHANGELOG.md'
        $TitleCacheFile     = 'changelog-titles.json'   # Regex mode: ticket ID -> title map, no secrets, safe to commit
        $ResolvedIssuesFile = 'issues-resolved.json'    # DateWindow mode: [{Id, ResolvedAt, Summary}, ...], no secrets, safe to commit
        $YouTrackUrl        = ''    # e.g. https://yourorg.youtrack.cloud -- enables live title enrichment (Regex mode only)
        $YouTrackToken      = ''    # permanent token -- only needed for enrichment

    If .changelogrc.ps1 leaves $YouTrackUrl/$YouTrackToken empty and a sibling
    `youtrack-credentials.ps1` is present, credentials are resolved from
    .ralph/youtrack.config.ps1, then .youtrack-project.ps1, then
    $HOME\.youtrack.config.ps1, then the YOUTRACK_BASE_URL / YOUTRACK_TOKEN
    environment variables. Without that helper the script still runs -- it just
    skips enrichment as it always did.

    -- Regex mode (default) --
    Scans each commit's subject line for a ticket ID via $TicketRegex. Title
    lookup order per ticket: local cache file ($TitleCacheFile) first, then
    the YouTrack REST API if $YouTrackUrl + $YouTrackToken are set, otherwise
    just the bare ticket ID. Commits with no ticket ID in the subject are
    marked "_Sin issue asociado_" rather than guessed at.

    -- DateWindow mode --
    Ignores commit message text entirely. Instead: sort commits oldest to
    newest; for each commit, its window is (previous commit's timestamp,
    this commit's timestamp] -- every resolved issue whose ResolvedAt falls
    in that window is attributed to this commit. The very first commit's
    window is (-infinity, its own timestamp]. Issues resolved after the
    newest commit are listed separately as not yet released.

    This mode requires $ResolvedIssuesFile at the repo root: a JSON array of
    objects with Id, ResolvedAt (parseable datetime, e.g. "2026-07-19 15:08:30"),
    and Summary. Populate/refresh it from your issue tracker (e.g. by asking
    the assistant to pull all resolved issues for the project, or writing your
    own export) -- this is the manual step this mode trades for precision.

    Caveat: ResolvedAt and commit timestamps are compared as naive datetimes
    (no timezone conversion). This is fine as long as both come from the same
    timezone context; if your tracker and git commits use different timezones,
    issues near a window boundary could be bucketed into the wrong commit.

    -- TagWindow mode (version-based) --
    Same resolved-issues cache as DateWindow, but the window boundaries are git
    TAGS (ordered by creatordate) instead of commits. Each version heading is the
    tag name (e.g. a CalVer tag `2026.07.24`); the issues resolved in
    (previous tag, this tag] are listed under it, newest version first. Issues
    resolved after the newest tag go under a `## [Unreleased]` block at the top.
    With no tags yet, everything lands in `[Unreleased]` -- a safe preview of the
    first release before you actually cut the tag. $Range is ignored in this mode.

.PARAMETER OutputFile
    File to write the changelog to. Default: CHANGELOG.md

.PARAMETER Range
    Any `git log` revision range, e.g. "v1.2.0..HEAD" or "main..feature/x".
    Default: full history.

.PARAMETER Mode
    'Regex' (default), 'DateWindow', or 'TagWindow'. See .DESCRIPTION.

.EXAMPLE
    ./changelog.ps1
    ./changelog.ps1 -Mode DateWindow
    ./changelog.ps1 -Mode TagWindow
    ./changelog.ps1 -Mode TagWindow -OutputFile CHANGELOG.preview.md
    ./changelog.ps1 -OutputFile CHANGELOG.md -Range "v1.2.0..HEAD"
#>
param(
    [string]$OutputFile,
    [string]$Range = '',
    [ValidateSet('Regex', 'DateWindow', 'TagWindow')]
    [string]$Mode = 'Regex',
    # TagWindow only: render the post-last-tag bucket as this version heading
    # (e.g. '2026.07.24') instead of '[Unreleased]'. Lets you write the version
    # block BEFORE creating the tag, so the release commit can contain the
    # changelog without any tag-before-generate juggling.
    [string]$AsVersion = '',
    # TagWindow only: date shown next to each version heading. The default
    # 'yyyy mmm dd' renders a lowercase Spanish month ("2026 jul 24"); any other
    # value is used as a .NET date format string (e.g. 'yyyy-MM-dd').
    [string]$DateFormat = 'yyyy mmm dd'
)

$ErrorActionPreference = 'Stop'

try {
    $RepoRoot = (git rev-parse --show-toplevel 2>$null)
    if (-not $?) { throw }
} catch {
    Write-Error "Not inside a git repository."
    exit 1
}

$TicketRegex        = '[A-Z]+-[0-9]+'
$OutputFileDefault  = 'CHANGELOG.md'
$TitleCacheFile     = 'changelog-titles.json'
$ResolvedIssuesFile = 'issues-resolved.json'
$YouTrackUrl        = ''
$YouTrackToken      = ''
# DateWindow/TagWindow: issue Types that count as "Fix / Bugs" -- everything else goes under "Features"
$BugTypes           = @('Bug', 'Exception', 'Performance Problem')
# Issue Types excluded from the changelog entirely (umbrella issues -- their subtasks carry the detail)
$ExcludeTypes       = @('Epic')

# TagWindow: version-heading date rendered as "yyyy mmm dd" with a lowercase
# Spanish month abbreviation (culture-independent, so it is always "jul" etc).
$MonthAbbrEs = @('ene', 'feb', 'mar', 'abr', 'may', 'jun', 'jul', 'ago', 'sep', 'oct', 'nov', 'dic')
function Format-VersionDate {
    param([datetime]$Date, [string]$Format)
    # The default sentinel 'yyyy mmm dd' renders a lowercase Spanish month abbrev
    # (culture-independent). Any other value is treated as a .NET format string.
    if ($Format -eq 'yyyy mmm dd') {
        return '{0} {1} {2:00}' -f $Date.Year, $MonthAbbrEs[$Date.Month - 1], $Date.Day
    }
    return $Date.ToString($Format)
}

# Write the changelog with LF line endings and no BOM, matching the repo's
# .gitattributes (eol=lf) so `git add` never warns about CRLF -> LF conversion.
function Set-FileLf {
    param($Lines, [string]$Path)
    $full = if ([System.IO.Path]::IsPathRooted($Path)) { $Path } else { Join-Path (Get-Location).Path $Path }
    $text = ($Lines -join "`n") + "`n"
    [System.IO.File]::WriteAllText($full, $text, (New-Object System.Text.UTF8Encoding($false)))
}

$rcPath = Join-Path $RepoRoot '.changelogrc.ps1'
if (Test-Path $rcPath) {
    . $rcPath
}

# Regex-mode enrichment credentials: whatever .changelogrc.ps1 did not set
# falls back to the shared cascade (repo .ralph config -> $HOME\.youtrack.config.ps1
# -> YOUTRACK_BASE_URL/YOUTRACK_TOKEN). Optional on purpose -- this script is
# meant to be copied standalone into any repo, so a missing helper just means
# no enrichment, same as before.
if (-not $YouTrackUrl -or -not $YouTrackToken) {
    $credHelper = Join-Path $PSScriptRoot 'youtrack-credentials.ps1'
    if (Test-Path $credHelper) {
        . $credHelper
        $cred = Resolve-YouTrackCredentials -RepoRoot $RepoRoot
        if ($cred) {
            if (-not $YouTrackUrl)   { $YouTrackUrl   = $cred.BaseUrl }
            if (-not $YouTrackToken) { $YouTrackToken = $cred.Token }
        }
    }
}

if (-not $OutputFile) { $OutputFile = if ($OutputFileDefault) { $OutputFileDefault } else { 'CHANGELOG.md' } }

if ($Mode -in @('DateWindow', 'TagWindow')) {
    $issuesPath = Join-Path $RepoRoot $ResolvedIssuesFile
    if (-not (Test-Path $issuesPath)) {
        Write-Error "$Mode mode requires $ResolvedIssuesFile at the repo root (array of {Id, ResolvedAt, Type, Summary} for resolved issues). See script header for details."
        exit 1
    }

    $issues = @((Get-Content $issuesPath -Raw -Encoding UTF8 | ConvertFrom-Json) |
        ForEach-Object {
            [PSCustomObject]@{
                Id         = $_.Id
                ResolvedAt = [datetime]$_.ResolvedAt
                Type       = $_.Type
                Summary    = $_.Summary
            }
        } | Where-Object { $_.Type -notin $ExcludeTypes } | Sort-Object ResolvedAt)

    function Write-IssueGroup {
        param(
            [System.Collections.Generic.List[string]]$Output,
            [array]$Bucket,
            [string[]]$BugTypes,
            [switch]$ShowResolvedDate
        )

        $fixes = @($Bucket | Where-Object { $_.Type -in $BugTypes } | Sort-Object ResolvedAt -Descending)
        $features = @($Bucket | Where-Object { $_.Type -notin $BugTypes } | Sort-Object ResolvedAt -Descending)

        if ($fixes.Count -eq 0 -and $features.Count -eq 0) {
            $Output.Add('_Sin issues cerrados en esta ventana_')
            return
        }

        if ($fixes.Count -gt 0) {
            $Output.Add('### Fix / Bugs')
            foreach ($iss in $fixes) {
                $suffix = if ($ShowResolvedDate) { " _(cerrado $($iss.ResolvedAt.ToString('yyyy-MM-dd HH:mm')))_" } else { '' }
                $Output.Add("- **$($iss.Id)**: $($iss.Summary)$suffix")
            }
        }

        if ($features.Count -gt 0) {
            $Output.Add('### Features')
            foreach ($iss in $features) {
                $suffix = if ($ShowResolvedDate) { " _(cerrado $($iss.ResolvedAt.ToString('yyyy-MM-dd HH:mm')))_" } else { '' }
                $Output.Add("- **$($iss.Id)**: $($iss.Summary)$suffix")
            }
        }
    }

    if ($Mode -eq 'DateWindow') {
        $gitArgs = @('-C', $RepoRoot, 'log', '--pretty=format:%H%x1f%cI%x1f%s')
        if ($Range) { $gitArgs += $Range }
        $rawLines = & git @gitArgs

        $commits = @($rawLines | Where-Object { $_ } | ForEach-Object {
            $p = $_ -split [char]0x1F
            [PSCustomObject]@{
                Hash      = $p[0]
                ShortHash = $p[0].Substring(0, 7)
                Date      = [datetime]$p[1]
                Subject   = $p[2]
            }
        } | Sort-Object Date)

        $boundary = [datetime]::MinValue
        $assigned = @{}

        foreach ($commit in $commits) {
            $assigned[$commit.Hash] = @($issues | Where-Object { $_.ResolvedAt -gt $boundary -and $_.ResolvedAt -le $commit.Date })
            $boundary = $commit.Date
        }

        $leftover = @($issues | Where-Object { $_.ResolvedAt -gt $boundary })

        $output = New-Object System.Collections.Generic.List[string]
        $output.Add('# Changelog')
        $output.Add('')

        if ($leftover.Count -gt 0) {
            $output.Add('## Cerrados, sin commit posterior todavia')
            Write-IssueGroup -Output $output -Bucket $leftover -BugTypes $BugTypes -ShowResolvedDate
            $output.Add('')
        }

        foreach ($commit in ($commits | Sort-Object Date -Descending)) {
            $output.Add("## $($commit.Date.ToString('yyyy-MM-dd HH:mm')) -- ``$($commit.ShortHash)`` $($commit.Subject)")

            $bucket = $assigned[$commit.Hash]
            Write-IssueGroup -Output $output -Bucket $bucket -BugTypes $BugTypes

            $output.Add('')
        }

        Set-FileLf -Lines $output -Path $OutputFile
        Write-Host "Changelog (DateWindow) written to $OutputFile"
        exit 0
    }

    # -- TagWindow mode --
    # Version-based changelog: the window boundaries are git TAGS (by creatordate)
    # instead of commits. An issue resolved in (previous tag, this tag] belongs to
    # that version; issues resolved after the newest tag go under "[Unreleased]".
    # With zero tags, everything is "[Unreleased]" -- exactly the preview you want
    # before cutting the first version. $Range is ignored here (tags define windows).
    $sep = [char]0x1F
    $tagFmt = "%(refname:short)$sep%(creatordate:iso-strict)"
    $tagLines = & git -C $RepoRoot for-each-ref --sort=creatordate --format=$tagFmt refs/tags

    $tags = @($tagLines | Where-Object { $_ } | ForEach-Object {
        $p = $_ -split [char]0x1F
        [PSCustomObject]@{
            Name = $p[0]
            Date = [datetime]$p[1]
        }
    } | Sort-Object Date)

    $boundary = [datetime]::MinValue
    $assigned = @{}

    foreach ($tag in $tags) {
        $assigned[$tag.Name] = @($issues | Where-Object { $_.ResolvedAt -gt $boundary -and $_.ResolvedAt -le $tag.Date })
        $boundary = $tag.Date
    }

    $unreleased = @($issues | Where-Object { $_.ResolvedAt -gt $boundary })

    $output = New-Object System.Collections.Generic.List[string]
    $output.Add('# Changelog')
    $output.Add('')

    if ($unreleased.Count -gt 0) {
        if ($AsVersion) {
            # If a tag with this exact CalVer already exists (same-day re-cut),
            # bump with .1, .2, ... so each version stays unique.
            $existingTagNames = @($tags | ForEach-Object { $_.Name })
            $effVersion = $AsVersion
            $n = 1
            while ($existingTagNames -contains $effVersion) {
                $effVersion = "$AsVersion.$n"
                $n++
            }
            $output.Add("## [$effVersion] - $(Format-VersionDate (Get-Date) $DateFormat)")
            Write-IssueGroup -Output $output -Bucket $unreleased -BugTypes $BugTypes
        } else {
            $output.Add('## [Unreleased]')
            Write-IssueGroup -Output $output -Bucket $unreleased -BugTypes $BugTypes -ShowResolvedDate
        }
        $output.Add('')
    }

    foreach ($tag in ($tags | Sort-Object Date -Descending)) {
        $output.Add("## [$($tag.Name)] - $(Format-VersionDate $tag.Date $DateFormat)")
        Write-IssueGroup -Output $output -Bucket $assigned[$tag.Name] -BugTypes $BugTypes
        $output.Add('')
    }

    Set-FileLf -Lines $output -Path $OutputFile
    Write-Host "Changelog (TagWindow) written to $OutputFile"
    exit 0
}

# -- Regex mode --

$canEnrich = $false
if ($YouTrackUrl -and $YouTrackToken) {
    $canEnrich = $true
}

$titleCache = @{}
$titleCachePath = Join-Path $RepoRoot $TitleCacheFile
if (Test-Path $titleCachePath) {
    (Get-Content $titleCachePath -Raw -Encoding UTF8 | ConvertFrom-Json).psobject.Properties |
        ForEach-Object { $titleCache[$_.Name] = $_.Value }
}

function Get-IssueSummary {
    param([string]$Ticket)

    if ($titleCache.ContainsKey($Ticket)) {
        return $titleCache[$Ticket]
    }

    if (-not $canEnrich) { return $null }

    try {
        $headers = @{
            Authorization = "Bearer $YouTrackToken"
            Accept        = 'application/json'
        }
        $uri = "$YouTrackUrl/api/issues/$Ticket`?fields=summary"
        $response = Invoke-RestMethod -Uri $uri -Headers $headers -Method Get
        return $response.summary
    } catch {
        return $null
    }
}

$gitArgs = @('-C', $RepoRoot, 'log', '--date=short', '--pretty=format:%H%x1f%ad%x1f%s')
if ($Range) { $gitArgs += $Range }

$lines = & git @gitArgs

$output = New-Object System.Collections.Generic.List[string]
$output.Add('# Changelog')
$output.Add('')

foreach ($line in $lines) {
    if (-not $line) { continue }

    $parts = $line -split [char]0x1F
    $hash = $parts[0]
    $date = $parts[1]
    $subject = $parts[2]
    $shortHash = $hash.Substring(0, 7)

    $tickets = @([regex]::Matches($subject, $TicketRegex) |
        ForEach-Object { $_.Value } |
        Select-Object -Unique)

    $output.Add("## $date -- ``$shortHash`` $subject")

    if ($tickets.Count -eq 0) {
        $output.Add('_Sin issue asociado_')
    }

    foreach ($ticket in $tickets) {
        $summary = Get-IssueSummary -Ticket $ticket
        if ($summary) {
            $output.Add("- **$ticket**: $summary")
        } else {
            $output.Add("- **$ticket**")
        }
    }

    $output.Add('')
}

Set-FileLf -Lines $output -Path $OutputFile

Write-Host "Changelog written to $OutputFile"
