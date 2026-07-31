<#
.SYNOPSIS
    Instala las herramientas de este repo en un proyecto: scripts de release,
    el loop de ralph y los docs de convenciones para agentes.

.DESCRIPTION
    Pensado para correrse UNA VEZ sobre un repo recien creado, despues de que
    la skill `youtrack-new-project` haya conectado el proyecto a YouTrack.

    Es idempotente: cada paso informa `+` (escrito), `=` (ya estaba igual) o
    `~` (existe y es distinto, se respeta). Nada se sobreescribe sin -Force,
    porque el caso normal de re-ejecucion es actualizar herramientas en un
    proyecto que ya lleva trabajo encima.

    NO toca `.git` en ningun momento, ni el suyo ni el del destino. Si bajaste
    este repo como ZIP no hay `.git` que borrar; si lo clonaste, borralo vos
    a mano y solo despues de verificar en que carpeta estas parado.

.PARAMETER ProjectKey
    Clave del proyecto en YouTrack (p. ej. `ACME`). Es el prefijo de los IDs.
    Si no se pasa, PowerShell la pide por consola.

.PARAMETER ProjectName
    Nombre completo del proyecto (p. ej. "Acme Portal"). Igual que arriba.

.PARAMETER RepoRoot
    Repo destino. Por defecto, la raiz del repo git del directorio actual.

.PARAMETER DryRun
    Enumera lo que haria sin escribir nada.

.PARAMETER Force
    Sobreescribe los archivos que ya existan y difieran.

.EXAMPLE
    ./bootstrap.ps1                                  # pregunta clave y nombre
    ./bootstrap.ps1 -ProjectKey ACME -ProjectName "Acme Portal" -DryRun
    ./bootstrap.ps1 -ProjectKey ACME -ProjectName "Acme Portal" -RepoRoot C:\www\acme
#>
param(
    # Mandatory sin valor = PowerShell los pide por consola. Es todo el
    # mecanismo "interactivo": no hace falta Read-Host ni un menu propio, y
    # pasandolos por parametro el script sigue siendo automatizable.
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[A-Z][A-Z0-9]{1,9}$')]
    [string]$ProjectKey,

    [Parameter(Mandatory = $true)]
    [string]$ProjectName,

    [string]$RepoRoot,
    [switch]$DryRun,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
$origen = $PSScriptRoot

# ---------------------------------------------------------------- destino ---

# En Windows PowerShell 5.1, redirigir el stderr de un ejecutable nativo genera
# un NativeCommandError terminante cuando $ErrorActionPreference es 'Stop', aun
# si el comando fallo de forma esperada. Por eso las llamadas a git que PUEDEN
# fallar se envuelven bajando la preferencia.
function Invoke-GitSilencioso([string[]]$argumentos) {
    $previo = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { $salida = & git @argumentos 2>$null } catch { $salida = $null }
    $ErrorActionPreference = $previo
    if ($LASTEXITCODE -ne 0) { return $null }
    return $salida
}

if (-not $RepoRoot) {
    $RepoRoot = Invoke-GitSilencioso @('rev-parse', '--show-toplevel')
    if (-not $RepoRoot) {
        Write-Error 'No estas dentro de un repo git y no pasaste -RepoRoot. Corre `git init` primero.'
        exit 1
    }
}

$RepoRoot = (Resolve-Path $RepoRoot).Path

if ($RepoRoot -eq (Resolve-Path $origen).Path) {
    Write-Error 'El destino es este mismo repo. Pasa -RepoRoot apuntando al proyecto.'
    exit 1
}

Write-Host "== Instalando herramientas en $RepoRoot ==" -ForegroundColor Cyan
Write-Host "   Proyecto: $ProjectName ($ProjectKey)" -ForegroundColor DarkGray
if ($DryRun) { Write-Host '   (dry-run: no se escribe nada)' -ForegroundColor Yellow }

# ---------------------------------------------------------------- helpers ---

$script:escritos = 0
$script:respetados = 0

function Expandir-Marcadores([string]$texto) {
    $texto -replace '\{\{PROJECT_KEY\}\}', $ProjectKey -replace '\{\{PROJECT_NAME\}\}', $ProjectName
}

function Ruta-Relativa([string]$destino) {
    return $destino.Substring($RepoRoot.Length).TrimStart('\', '/')
}

function Anunciar([string]$relativo, [string]$estado) {
    switch ($estado) {
        'nuevo'  { Write-Host "  + $relativo" -ForegroundColor Green;    $script:escritos++ }
        'igual'  { Write-Host "  = $relativo" -ForegroundColor DarkGray; $script:respetados++ }
        'difiere'{ Write-Host "  ~ $relativo  (existe y difiere; -Force para sobreescribir)" -ForegroundColor Yellow
                   $script:respetados++ }
    }
}

function Asegurar-Carpeta([string]$archivo) {
    $carpeta = Split-Path -Parent $archivo
    if (-not (Test-Path $carpeta)) { New-Item -ItemType Directory -Path $carpeta -Force | Out-Null }
}

# Copia byte por byte. Nada de Get-Content: en PowerShell 5.1 lee como ANSI
# cuando el archivo no trae BOM, asi que un .ps1 UTF-8 con un solo acento se
# corrompia al copiarlo, y la corrida siguiente lo veia distinto y reportaba
# un cambio que nunca hubo. Copiando bytes, la codificacion del origen llega
# intacta sea cual sea.
function Copiar([string]$desde, [string]$hasta) {
    $relativo = Ruta-Relativa $hasta
    $bytes = [System.IO.File]::ReadAllBytes($desde)

    if (Test-Path $hasta) {
        $actuales = [System.IO.File]::ReadAllBytes($hasta)
        if (@(Compare-Object $actuales $bytes -SyncWindow 0).Count -eq 0) { Anunciar $relativo 'igual'; return }
        if (-not $Force) { Anunciar $relativo 'difiere'; return }
    }

    if (-not $DryRun) {
        Asegurar-Carpeta $hasta
        [System.IO.File]::WriteAllBytes($hasta, $bytes)
    }
    Anunciar $relativo 'nuevo'
}

# Para los archivos que si llevan sustitucion hay que decodificar, y ahi la
# codificacion se fija explicitamente en UTF-8 en los dos sentidos. Sin BOM:
# los .md con BOM ensucian el primer encabezado.
$script:utf8 = New-Object System.Text.UTF8Encoding $false

function Poner-Texto([string]$destino, [string]$contenido) {
    $relativo = Ruta-Relativa $destino

    if (Test-Path $destino) {
        # Se normalizan los saltos de linea antes de comparar: git y los
        # editores los cambian solos, y un CRLF no es un cambio real.
        $actual = [System.IO.File]::ReadAllText($destino, $script:utf8) -replace "`r`n", "`n"
        if ($actual -eq ($contenido -replace "`r`n", "`n")) { Anunciar $relativo 'igual'; return }
        if (-not $Force) { Anunciar $relativo 'difiere'; return }
    }

    if (-not $DryRun) {
        Asegurar-Carpeta $destino
        [System.IO.File]::WriteAllText($destino, $contenido, $script:utf8)
    }
    Anunciar $relativo 'nuevo'
}

function Renderizar([string]$desde, [string]$hasta) {
    $crudo = [System.IO.File]::ReadAllText($desde, $script:utf8)
    Poner-Texto $hasta (Expandir-Marcadores $crudo)
}

# ----------------------------------------------------- scripts de release ---

Write-Host 'Scripts de release y changelog:' -ForegroundColor White
foreach ($s in @('changelog.ps1', 'refresh-issues-resolved.ps1', 'release.ps1', 'youtrack-credentials.ps1')) {
    Copiar (Join-Path $origen "scripts/$s") (Join-Path $RepoRoot "scripts/$s")
}

# ------------------------------------------------------------ loop ralph ---

Write-Host 'Loop de construccion (.ralph):' -ForegroundColor White
Copiar     (Join-Path $origen 'ralph/ralph.ps1')          (Join-Path $RepoRoot '.ralph/ralph.ps1')
Renderizar (Join-Path $origen 'ralph/prompt.md.template') (Join-Path $RepoRoot '.ralph/prompt.md')

# El log arranca solo con el encabezado de la tabla que administra ralph.ps1.
# Se crea aqui para que la primera iteracion no tenga que inventarse el formato.
$log = Join-Path $RepoRoot '.ralph/log.md'
if (-not (Test-Path $log)) {
    Poner-Texto $log @"
## Tabla de Metricas y Costos de Ejecucion

| Fecha / Hora | Iteracion | Tarea | Modelo | Duracion | Tokens (In / Out / Cache) | Costo (USD) |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- |

"@
} else {
    Write-Host '  = .ralph/log.md  (ya tiene historia, no se toca)' -ForegroundColor DarkGray
    $script:respetados++
}

# ---------------------------------------------------- docs de agentes -------

Write-Host 'Convenciones para agentes:' -ForegroundColor White
Renderizar (Join-Path $origen 'templates/AGENTS.md')        (Join-Path $RepoRoot 'AGENTS.md')
Renderizar (Join-Path $origen 'templates/issue-tracker.md') (Join-Path $RepoRoot 'docs/agents/issue-tracker.md')
Renderizar (Join-Path $origen 'templates/triage-labels.md') (Join-Path $RepoRoot 'docs/agents/triage-labels.md')

# ------------------------------------------------------------ .gitignore ---

$gitignore = Join-Path $RepoRoot '.gitignore'
$tieneRalph = (Test-Path $gitignore) -and
              (([System.IO.File]::ReadAllText($gitignore, $script:utf8) -split "`r?`n") -contains '/.ralph')

if (-not $tieneRalph) {
    if (-not $DryRun) {
        # Nada de Add-Content -Encoding utf8: en PowerShell 5.1 le pone BOM al
        # archivo cuando lo crea, y un .gitignore que empieza con BOM depende
        # de que la version de git lo tolere. Con .NET y UTF8Encoding($false)
        # no aparece nunca.
        $bloque = "# El loop de construccion: bitacora y prompt son locales.`n/.ralph`n"
        if (Test-Path $gitignore) {
            [System.IO.File]::AppendAllText($gitignore, "`n$bloque", $script:utf8)
        } else {
            [System.IO.File]::WriteAllText($gitignore, $bloque, $script:utf8)
        }
    }
    Write-Host '  + .gitignore  (agregado /.ralph)' -ForegroundColor Green
    $script:escritos++
} else {
    Write-Host '  = .gitignore  (/.ralph ya estaba)' -ForegroundColor DarkGray
    $script:respetados++
}

# -------------------------------------------------------- version instalada -

# Deja rastro de QUE version se instalo. Sin esto, la pregunta "arregle un bug
# en release.ps1, que proyectos traen el viejo?" no tiene respuesta.
$sha = $null
if (Test-Path (Join-Path $origen '.git')) {
    Push-Location $origen
    $sha = Invoke-GitSilencioso @('rev-parse', 'HEAD')
    Pop-Location
}

$version = if ($sha) { ([string]$sha).Trim() } else { 'desconocida (instalado desde ZIP, sin git)' }
$sello = @"
origen:    https://github.com/UranoDev/claude-tools
version:   $version
instalado: $(Get-Date -Format 'yyyy-MM-dd HH:mm')
"@
Poner-Texto (Join-Path $RepoRoot ".tooling-version") $sello

# ------------------------------------------------------------------ cierre --

Write-Host ''
Write-Host "Listo: $script:escritos escrito(s), $script:respetados sin cambios." -ForegroundColor Green

if (-not $DryRun) {
    Write-Host ''
    Write-Host 'Falta a mano:' -ForegroundColor DarkGray
    Write-Host '  1. CONTEXT.md - el glosario del dominio. Nadie puede generarlo por vos.' -ForegroundColor DarkGray
    Write-Host '  2. .ralph/prompt.md - enumerar los terminos del glosario y los ADRs (hay un comentario adentro que lo explica).' -ForegroundColor DarkGray
    Write-Host "  3. La epica en YouTrack: todo issue nace con parentIssue, asi que $ProjectKey-1 tiene que existir primero." -ForegroundColor DarkGray
}
