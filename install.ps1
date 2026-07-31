<#
.SYNOPSIS
    Baja la ultima version de claude-tools y la instala en un repo.

.DESCRIPTION
    Descarga el ZIP de la rama `main` a una carpeta temporal y corre
    `bootstrap.ps1` desde ahi. Es el atajo para un proyecto nuevo: no hace
    falta clonar nada ni tener el repo a mano.

    Descarga ZIP y NO clona, a proposito. Un `git clone` seguido de borrar
    `.git` deja un paso destructivo en el procedimiento, y ese paso corre en
    la carpeta del proyecto -- que para entonces ya tiene su propio `.git`
    con toda la historia. Bajando el ZIP nunca existe un `.git` que borrar.

    La carpeta temporal se limpia sola al terminar, incluso si algo falla.

.PARAMETER ProjectKey
    Clave del proyecto en YouTrack (p. ej. `ACME`). Si falta, se pide.

.PARAMETER ProjectName
    Nombre completo del proyecto. Si falta, se pide.

.PARAMETER RepoRoot
    Repo destino. Por defecto, la raiz del repo git del directorio actual.

.PARAMETER Ref
    Rama o etiqueta a instalar. Por defecto `main`.

.EXAMPLE
    ./install.ps1 -ProjectKey ACME -ProjectName "Acme Portal"
    ./install.ps1 -ProjectKey ACME -ProjectName "Acme Portal" -DryRun
#>
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[A-Z][A-Z0-9]{1,9}$')]
    [string]$ProjectKey,

    [Parameter(Mandatory = $true)]
    [string]$ProjectName,

    [string]$RepoRoot,
    [string]$Ref = 'main',
    [switch]$DryRun,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

$url = "https://github.com/UranoDev/claude-tools/archive/refs/heads/$Ref.zip"
$tmp = Join-Path ([System.IO.Path]::GetTempPath()) "claude-tools-$(New-Guid)"
$zip = "$tmp.zip"

try {
    Write-Host "Bajando claude-tools ($Ref)..." -ForegroundColor DarkGray
    # ProgressPreference apagado: la barra de Invoke-WebRequest hace la descarga
    # varias veces mas lenta en Windows PowerShell 5.1.
    $anterior = $ProgressPreference
    $ProgressPreference = 'SilentlyContinue'
    Invoke-WebRequest -Uri $url -OutFile $zip -UseBasicParsing
    $ProgressPreference = $anterior

    Expand-Archive -Path $zip -DestinationPath $tmp -Force

    # El ZIP de GitHub envuelve todo en `<repo>-<ref>/`.
    $raiz = Get-ChildItem $tmp -Directory | Select-Object -First 1
    if (-not $raiz) { Write-Error 'El ZIP llego vacio o con una forma inesperada.'; exit 1 }

    $bootstrap = Join-Path $raiz.FullName 'bootstrap.ps1'
    if (-not (Test-Path $bootstrap)) { Write-Error "No se encontro bootstrap.ps1 dentro del ZIP."; exit 1 }

    $args = @{ ProjectKey = $ProjectKey; ProjectName = $ProjectName }
    if ($RepoRoot) { $args.RepoRoot = $RepoRoot }
    if ($DryRun)   { $args.DryRun   = $true }
    if ($Force)    { $args.Force    = $true }

    & $bootstrap @args
}
finally {
    # Sin esto, cada instalacion deja ~100 KB en %TEMP% para siempre.
    Remove-Item $zip -Force -ErrorAction SilentlyContinue
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
}
