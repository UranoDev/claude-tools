<#
.SYNOPSIS
    Shared YouTrack credential resolver for this repo's PowerShell scripts.

.DESCRIPTION
    Dot-source this file and call Resolve-YouTrackCredentials. It looks for a
    base URL + permanent token + project in four places, most specific first:

      1. <RepoRoot>\.ralph\youtrack.config.ps1        per-repo, gitignored
      2. <RepoRoot>\.youtrack-project.ps1            per-repo, COMMITTED
      3. $HOME\.youtrack.config.ps1                   per-user, any repo
      4. $env:YOUTRACK_BASE_URL / $env:YOUTRACK_TOKEN CI, one-off runs

    Layer 2 is version-controlled, so it must never hold a token -- it exists
    so the project (and the instance URL, which is not a secret) travel with
    the repo. Layer 1 stays first as the untracked local override.

    Config files are plain PowerShell that assign $YouTrackBaseUrl and
    $YouTrackToken; $YouTrackUrl is also accepted for the URL, since that is
    the name changelog.ps1 has always used in .changelogrc.ps1. So a single
    $HOME\.youtrack.config.ps1 serves every script here.

    They may also assign $YouTrackProject to name the project(s) the repo
    tracks -- one instance now hosts several. Accepted shapes:
    'FRAC', 'FRAC, COBR', @('FRAC','COBR'), or YOUTRACK_PROJECT=FRAC,COBR.
    Its natural home is the committed .youtrack-project.ps1: credentials live
    once in $HOME while each repo declares, in version control, which project
    is its own.

    Each field resolves on its own, so partial sources compose: a user-level
    file can hold the URL and token while the repo file names only the
    project, or CI injects only the token as a secret.

    Config files are dot-sourced INSIDE Read-YouTrackConfigFile, so their
    variables stay in that function's scope -- the token never leaks into the
    caller's scope, only the returned object crosses the boundary.

.EXAMPLE
    . (Join-Path $PSScriptRoot 'youtrack-credentials.ps1')
    $cred = Resolve-YouTrackCredentials -RepoRoot $RepoRoot -Require
    $headers = @{ Authorization = "Bearer $($cred.Token)" }
    Invoke-RestMethod -Uri "$($cred.BaseUrl)/api/issues" -Headers $headers
#>

# Normalizes every accepted $YouTrackProject shape ('FRAC', 'FRAC, COBR',
# @('FRAC','COBR'), 'FRAC COBR') into a plain string array.
function ConvertTo-YouTrackProjectList {
    param([object]$Value)

    if (-not $Value) { return @() }
    $items = @()
    foreach ($entry in @($Value)) {
        if (-not $entry) { continue }
        $items += (([string]$entry) -split '[,;\s]+' | Where-Object { $_ })
    }
    return @($items)
}

# Reads $YouTrackBaseUrl/$YouTrackUrl + $YouTrackToken + $YouTrackProject out of
# a config file. Returns $null when the file does not exist; a field the file
# leaves unset comes back empty so the caller can keep walking the cascade.
function Read-YouTrackConfigFile {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) { return $null }

    # Cleared up front: without this, a file that sets only the token would
    # appear to also carry the URL of whichever file we dot-sourced before it.
    $YouTrackBaseUrl = $null
    $YouTrackUrl     = $null
    $YouTrackToken   = $null
    $YouTrackProject = $null

    . $Path

    [PSCustomObject]@{
        BaseUrl = if ($YouTrackBaseUrl) { $YouTrackBaseUrl } else { $YouTrackUrl }
        Token   = $YouTrackToken
        Project = ConvertTo-YouTrackProjectList $YouTrackProject
    }
}

function Get-YouTrackHomeDirectory {
    if ($HOME)             { return $HOME }
    if ($env:USERPROFILE)  { return $env:USERPROFILE }
    return [Environment]::GetFolderPath('UserProfile')
}

<#
.SYNOPSIS
    Resolves YouTrack credentials through the repo -> user -> env cascade.

.PARAMETER RepoRoot
    Repo whose .ralph\youtrack.config.ps1 should be checked first. Omit to
    skip the per-repo step (e.g. when running outside a git repo).

.PARAMETER UserConfigPath
    Overrides the per-user config location (default $HOME\.youtrack.config.ps1).
    Exists because $HOME is read-only in PowerShell 5.1, so this is the only
    seam that lets the cascade be tested against a throwaway home directory.

.PARAMETER Require
    Throw a message listing every location checked when either credential
    field is still missing. Without it, an incomplete resolution returns $null
    so the caller can degrade gracefully.

.PARAMETER RequireProject
    Same, for $YouTrackProject. Separate switch because only the scripts that
    query issues need a project -- ralph.ps1 (per-issue Cost) and changelog.ps1
    (per-ticket title) work on IDs they already have.

.OUTPUTS
    PSCustomObject with BaseUrl, Token, Project (string[]) and a *Source field
    per value naming where it came from (handy for -Verbose), or $null when
    credentials are incomplete and -Require was not passed.
#>
function Resolve-YouTrackCredentials {
    [CmdletBinding()]
    param(
        [string]$RepoRoot,
        [string]$UserConfigPath,
        [switch]$Require,
        [switch]$RequireProject
    )

    $candidates = New-Object System.Collections.Generic.List[object]

    if ($RepoRoot) {
        # Untracked local override first, then the committed declaration.
        foreach ($rel in @('.ralph/youtrack.config.ps1', '.youtrack-project.ps1')) {
            $repoFile = Join-Path $RepoRoot $rel
            $candidates.Add([PSCustomObject]@{
                Label  = $repoFile
                Values = (Read-YouTrackConfigFile -Path $repoFile)
            })
        }
    }

    $userFile = if ($UserConfigPath) { $UserConfigPath }
                else { Join-Path (Get-YouTrackHomeDirectory) '.youtrack.config.ps1' }
    $candidates.Add([PSCustomObject]@{
        Label  = $userFile
        Values = (Read-YouTrackConfigFile -Path $userFile)
    })

    $candidates.Add([PSCustomObject]@{
        Label  = 'variables de entorno YOUTRACK_BASE_URL / YOUTRACK_TOKEN / YOUTRACK_PROJECT'
        Values = [PSCustomObject]@{
            BaseUrl = $env:YOUTRACK_BASE_URL
            Token   = $env:YOUTRACK_TOKEN
            Project = ConvertTo-YouTrackProjectList $env:YOUTRACK_PROJECT
        }
    })

    $baseUrl = $null; $baseUrlSource = $null
    $token   = $null; $tokenSource   = $null
    $project = @();   $projectSource = $null

    foreach ($candidate in $candidates) {
        if (-not $candidate.Values) { continue }   # file not present
        if (-not $baseUrl -and $candidate.Values.BaseUrl) {
            # TrimEnd('/') so callers can always concatenate "$BaseUrl/api/..."
            $baseUrl       = ([string]$candidate.Values.BaseUrl).Trim().TrimEnd('/')
            $baseUrlSource = $candidate.Label
        }
        if (-not $token -and $candidate.Values.Token) {
            $token       = ([string]$candidate.Values.Token).Trim()
            $tokenSource = $candidate.Label
        }
        if (-not $project -and $candidate.Values.Project) {
            $project       = @($candidate.Values.Project)
            $projectSource = $candidate.Label
        }
    }

    $missing = @()
    if ($Require) {
        if (-not $baseUrl) { $missing += 'la URL base' }
        if (-not $token)   { $missing += 'el token' }
    }
    if ($RequireProject -and -not $project) { $missing += 'el proyecto' }

    if ($missing) {
        $lines = @("No pude resolver $($missing -join ' ni ') de YouTrack. Busque, en este orden:")
        foreach ($candidate in $candidates) { $lines += "  - $($candidate.Label)" }
        $lines += 'Los archivos de config son PowerShell y deben asignar $YouTrackBaseUrl, $YouTrackToken y (para consultar issues) $YouTrackProject.'
        throw ($lines -join [Environment]::NewLine)
    }

    if (-not $baseUrl -or -not $token) { return $null }

    return [PSCustomObject]@{
        BaseUrl       = $baseUrl
        Token         = $token
        Project       = $project
        BaseUrlSource = $baseUrlSource
        TokenSource   = $tokenSource
        ProjectSource = $projectSource
    }
}
