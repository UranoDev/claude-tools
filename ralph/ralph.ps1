param(
    [int]$Iterations = 10,
    [string]$Model = "claude-opus-5",

    [Alias("v")]
    [switch]$Version
)
# Otro modelo más económico: claude-sonnet-5
# Version del script (bump manual cuando haya cambios relevantes en la logica del loop).
$ScriptVersion = "1.0.0"

if ($Version) {
    Write-Host "ralph.ps1 v$ScriptVersion - loop de construccion (patron Ralph Wiggum)"
    Write-Host ""
    Write-Host "Uso:"
    Write-Host "  ralph.ps1 [-Iterations <int>] [-Model <string>] [-Version | -v]"
    Write-Host ""
    Write-Host "Parametros:"
    Write-Host "  -Iterations <int>   Numero maximo de iteraciones del loop (default: 10)"
    Write-Host "  -Model <string>     Modelo a invocar con 'claude -p' (default: claude-opus-5)"
    Write-Host "  -Version, -v        Muestra esta informacion y termina sin ejecutar el loop"
    exit 0
}

$ErrorActionPreference = "Stop"

# La CLI de claude emite UTF-8. Forzamos la consola a UTF-8 para que los acentos
# y emojis no se decodifiquen con la pagina de codigos OEM (Aqui -> Aqui, etc.).
$OutputEncoding = [System.Text.UTF8Encoding]::new($false)
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)

# Evitar advertencias de soporte de color en la consola de Windows forzando soporte de 256 colores.
$env:TERM = "xterm-256color"
$env:COLORTERM = "truecolor"

# Render minimalista de markdown para la consola: separadores, encabezados y
# vinetas con color, y limpieza de marcadores inline (**negrita**, `codigo`).
function Write-Markdown {
    param([string]$Text)

    foreach ($line in ($Text -split "`r?`n")) {
        $trimmed = $line.TrimEnd()

        if ($trimmed -match '^\s*(-{3,}|\*{3,}|_{3,})\s*$') {
            Write-Host ("-" * 60) -ForegroundColor DarkGray
            continue
        }

        if ($trimmed -match '^\s*(#{1,6})\s+(.*)$') {
            Write-Host $matches[2] -ForegroundColor Cyan
            continue
        }

        $clean = $trimmed -replace '\*\*([^*]+)\*\*', '$1' -replace '`([^`]+)`', '$1'

        if ($clean -match '^\s*[-*]\s+') {
            Write-Host $clean -ForegroundColor Gray
            continue
        }

        Write-Host $clean
    }
}

# Notificacion por SMS (Twilio) al terminar el loop, sin importar el motivo.
# Credenciales en notify.config.ps1 (gitignored via .ralph/); si no existe o
# esta incompleto, Send-RalphSms simplemente no hace nada.
# PENDIENTE: falta llamar Send-RalphSms en los puntos de salida (COMPLETE,
# BLOCKED, error, iteraciones agotadas). En pausa hasta tener credenciales
# reales de Twilio en notify.config.ps1.
$notifyConfigPath = Join-Path $PSScriptRoot "notify.config.ps1"
if (Test-Path $notifyConfigPath) {
    . $notifyConfigPath
}

# Config de YouTrack (URL base + token permanente) para acumular el campo Cost
# y comentar el costo de cada ciclo en el issue trabajado. A diferencia de
# notify.config.ps1, esta NO es opcional: sin ella el loop no puede registrar
# costos, asi que el script aborta antes de arrancar el loop en vez de
# degradar en silencio.
#
# Las credenciales se resuelven con la cascada compartida
# (.ralph/youtrack.config.ps1 -> .youtrack-project.ps1 -> $HOME\.youtrack.config.ps1
# -> variables de entorno); ver scripts/youtrack-credentials.ps1. El token vive
# en el archivo del usuario, no en el repo.
$RalphRepoRoot = Split-Path $PSScriptRoot -Parent
. (Join-Path $RalphRepoRoot "scripts/youtrack-credentials.ps1")
try {
    $cred = Resolve-YouTrackCredentials -RepoRoot $RalphRepoRoot -Require
} catch {
    Write-Error "$($_.Exception.Message)$([Environment]::NewLine)El loop no puede registrar costos en YouTrack sin credenciales; configuralas antes de correr ralph.ps1."
    exit 1
}
$YouTrackBaseUrl = $cred.BaseUrl
$YouTrackToken   = $cred.Token

function Send-RalphSms {
    param([string]$Message)

    if (-not $TwilioAccountSid -or -not $TwilioAuthToken -or -not $TwilioFromNumber -or -not $TwilioToNumber) {
        return
    }

    try {
        $uri = "https://api.twilio.com/2010-04-01/Accounts/$TwilioAccountSid/Messages.json"
        $pair = "$TwilioAccountSid`:$TwilioAuthToken"
        $basicAuth = [Convert]::ToBase64String([System.Text.Encoding]::ASCII.GetBytes($pair))
        $headers = @{ Authorization = "Basic $basicAuth" }
        $body = @{
            To   = $TwilioToNumber
            From = $TwilioFromNumber
            Body = $Message
        }
        Invoke-RestMethod -Uri $uri -Method Post -Headers $headers -Body $body | Out-Null
    }
    catch {
        Write-Warning "No se pudo enviar el SMS de notificacion: $_"
    }
}
# Anclar al proyecto sin importar desde donde se invoque el script.
$projectRoot = Split-Path -Parent $PSScriptRoot
Set-Location $projectRoot
$promptPath = Join-Path $PSScriptRoot "prompt.md"
$logPath = Join-Path $PSScriptRoot "log.md"

# Inserta una linea de metricas (tiempo + tokens + costo) dentro de la tabla especial
# de costos al inicio de log.md en orden cronologico inverso (mas reciente primero).
function Add-MetricsToLog {
    param(
        [string]$LogPath,
        [string]$MetricLine
    )

    if (-not (Test-Path $LogPath)) {
        $initialContent = @(
            "# Log de cambios",
            "",
            "## Tabla de Metricas y Costos de Ejecucion",
            "",
            "| Fecha / Hora | Iteracion | Tarea | Modelo | Duracion | Tokens (In / Out / Cache) | Costo (USD) |",
            "| :--- | :--- | :--- | :--- | :--- | :--- | :--- |",
            $MetricLine,
            "",
            "---",
            ""
        )
        Set-Content -Path $LogPath -Value $initialContent -Encoding utf8
        return
    }

    $lines = @(Get-Content -Path $LogPath -Encoding utf8)

    $hasMetricsSection = $false
    for ($j = 0; $j -lt $lines.Count; $j++) {
        if ($lines[$j] -match '## Tabla de Metricas y Costos de Ejecucion') {
            $hasMetricsSection = $true
            break
        }
    }

    if (-not $hasMetricsSection) {
        $newLines = @()
        $titleIndex = -1

        for ($j = 0; $j -lt $lines.Count; $j++) {
            if ($lines[$j] -match '^# ') {
                $titleIndex = $j
                break
            }
        }

        if ($titleIndex -ge 0) {
            $newLines += $lines[0..$titleIndex]
            $newLines += ""
            $newLines += "## Tabla de Metricas y Costos de Ejecucion"
            $newLines += ""
            $newLines += "| Fecha / Hora | Iteracion | Tarea | Modelo | Duracion | Tokens (In / Out / Cache) | Costo (USD) |"
            $newLines += "| :--- | :--- | :--- | :--- | :--- | :--- | :--- |"
            $newLines += $MetricLine
            $newLines += ""
            $newLines += "---"
            if (($titleIndex + 1) -lt $lines.Count) {
                $newLines += $lines[($titleIndex + 1)..($lines.Count - 1)]
            }
        }
        else {
            $newLines += "# Log de cambios"
            $newLines += ""
            $newLines += "## Tabla de Metricas y Costos de Ejecucion"
            $newLines += ""
            $newLines += "| Fecha / Hora | Iteracion | Tarea | Modelo | Duracion | Tokens (In / Out / Cache) | Costo (USD) |"
            $newLines += "| :--- | :--- | :--- | :--- | :--- | :--- | :--- |"
            $newLines += $MetricLine
            $newLines += ""
            $newLines += "---"
            $newLines += $lines
        }
        Set-Content -Path $LogPath -Value $newLines -Encoding utf8
    }
    else {
        $headerLineIndex = -1
        for ($j = 0; $j -lt $lines.Count; $j++) {
            if ($lines[$j] -match '\| :--- \| :--- \| :--- \| :--- \| :--- \| :--- \| :--- \|') {
                $headerLineIndex = $j
                break
            }
        }

        if ($headerLineIndex -ge 0) {
            $newLines = @()
            $newLines += $lines[0..$headerLineIndex]
            $newLines += $MetricLine
            if (($headerLineIndex + 1) -lt $lines.Count) {
                $newLines += $lines[($headerLineIndex + 1)..($lines.Count - 1)]
            }
            Set-Content -Path $LogPath -Value $newLines -Encoding utf8
        }
        else {
            Write-Warning "No se encontro el separador de tabla en log.md; agregando metrica al inicio."
            $newLines = @($MetricLine) + $lines
            Set-Content -Path $LogPath -Value $newLines -Encoding utf8
        }
    }
}

# Acumula el costo del ciclo en el custom field "Cost" del issue de YouTrack
# (lectura del valor actual + suma, no un reemplazo) y deja un comentario en
# el issue con el costo de este ciclo puntual. A diferencia de Send-RalphSms,
# esta funcion asume que $YouTrackBaseUrl/$YouTrackToken ya fueron validados
# al arrancar el script (ver chequeo de youtrack.config.ps1 mas arriba); si
# la llamada HTTP falla en una iteracion puntual (ej. YouTrack caido), se
# avisa con Write-Warning y el loop continua igual, sin abortar.
function Update-YouTrackCost {
    param(
        [string]$IssueId,
        [double]$CostUsd
    )

    $headers = @{ Authorization = "Bearer $YouTrackToken" }
    $issueUri = "$YouTrackBaseUrl/api/issues/$IssueId"

    try {
        $current = Invoke-RestMethod -Uri "$issueUri`?fields=customFields(name,value,`$type)" -Method Get -Headers $headers
        $costField = $current.customFields | Where-Object { $_.name -eq "Cost" } | Select-Object -First 1

        if (-not $costField) {
            Write-Warning "El issue $IssueId no tiene un custom field 'Cost'; no se registra el costo de este ciclo."
            return
        }

        $previousCost = if ($null -eq $costField.value) { 0 } else { [double]$costField.value }
        # $CostUsd ya viene redondeado a 2 decimales desde el loop principal;
        # redondeamos tambien la suma para que el acumulado en YouTrack no
        # arrastre mas precision de la que el campo deberia mostrar.
        $newCost = [math]::Round($previousCost + $CostUsd, 2)

        $updateBody = @{
            customFields = @(
                @{
                    name   = "Cost"
                    '$type' = $costField.'$type'
                    value  = $newCost
                }
            )
        } | ConvertTo-Json -Depth 5

        Invoke-RestMethod -Uri $issueUri -Method Post -Headers $headers -ContentType "application/json" -Body $updateBody | Out-Null

        $commentBody = @{
            text = "Costo de este ciclo: USD {0:N2} (acumulado: USD {1:N2})" -f $CostUsd, $newCost
        } | ConvertTo-Json

        Invoke-RestMethod -Uri "$issueUri/comments" -Method Post -Headers $headers -ContentType "application/json" -Body $commentBody | Out-Null
    }
    catch {
        Write-Warning "No se pudo registrar el costo en YouTrack para $IssueId`: $_"
    }
}

for ($i = 1; $i -le $Iterations; $i++) {
    Write-Host ""
    Write-Host "=== Iteracion $i de $Iterations [Modelo: $Model] ===" -ForegroundColor Cyan

    $prompt = Get-Content -Path $promptPath -Raw -Encoding utf8
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

    # Invocar la CLI de claude saltando los permisos para la ejecucion automatizada.
    $raw = claude -p $prompt --model $Model --output-format json --dangerously-skip-permissions

    $stopwatch.Stop()

    if ($LASTEXITCODE -ne 0) {
        Write-Warning "claude salio con codigo $LASTEXITCODE en la iteracion $i. Abortando."
        Write-Host $raw
        exit $LASTEXITCODE
    }

    # La CLI con --output-format json devuelve un objeto con el texto en .result,
    # el uso de tokens en .usage y el costo total en .total_cost_usd.
    try {
        $payload = ($raw -join "`n") | ConvertFrom-Json
    }
    catch {
        Write-Warning "No se pudo parsear la salida JSON de claude en la iteracion $i."
        Write-Host $raw
        exit 1
    }

    $result = $payload.result
    $usage = $payload.usage
    $inputTokens = [int]$usage.input_tokens
    $outputTokens = [int]$usage.output_tokens
    $cacheCreate = [int]$usage.cache_creation_input_tokens
    $cacheRead = [int]$usage.cache_read_input_tokens
    $cacheTokens = $cacheCreate + $cacheRead
    $totalTokens = $inputTokens + $outputTokens + $cacheTokens
    # Redondeado a 2 decimales antes de tocar log.md o YouTrack -- el valor
    # crudo de la CLI trae hasta 6 decimales, mas precision de la que necesitamos.
    $costUsd = [math]::Round([double]$payload.total_cost_usd, 2)

    Write-Markdown $result

    # La invocacion ya escribio su propia entrada narrativa en log.md (protocolo
    # en prompt.md), con un encabezado "## FRAC-N - ...". La tomamos para cruzar
    # costo/tokens con la tarea (issue de YouTrack), sin depender de que el
    # modelo lo reporte por separado.
    $taskId = ""
    if (Test-Path $logPath) {
        $taskMatch = Select-String -Path $logPath -Pattern '^## ([A-Z]+-\d+)' | Select-Object -Last 1
        if ($taskMatch) {
            $taskId = $taskMatch.Matches[0].Groups[1].Value
        }
    }
    if (-not $taskId) { $taskId = "(sin tarea)" }

    $elapsedText = "{0:hh\:mm\:ss}" -f $stopwatch.Elapsed
    $now = Get-Date -Format "yyyy-MM-dd HH:mm"
    $tokensDisplay = "{0:N0} (in {1:N0} / out {2:N0} / cache {3:N0})" -f $totalTokens, $inputTokens, $outputTokens, $cacheTokens
    $costDisplay = "USD {0:N2}" -f $costUsd
    $metricLine = "| {0} | {1} | {2} | {3} | {4} | {5} | {6} |" -f `
        $now, "Iteracion $i", $taskId, $Model, $elapsedText, $tokensDisplay, $costDisplay

    Write-Host ""
    Write-Host ("Iteracion {0} ({1}) completada en {2} (hh:mm:ss) - {3:N0} tokens, USD {4:N2}." -f `
            $i, $taskId, $elapsedText, $totalTokens, $costUsd) -ForegroundColor Yellow

    Add-MetricsToLog -LogPath $logPath -MetricLine $metricLine

    if ($taskId -ne "(sin tarea)") {
        Update-YouTrackCost -IssueId $taskId -CostUsd $costUsd
    }

    # Si la iteracion toco codigo (mas alla de log.md/tasks.md, que se actualizan en
    # cada iteracion sin importar el resultado), reinicia los workers de queue:work
    # para que recojan el codigo nuevo en el siguiente job. queue:work cachea las
    # clases PHP en memoria y no se entera de cambios en disco por si solo --
    # confirmado en nvavista que sin esto un worker corriendo de una sesion
    # anterior puede ejecutar codigo viejo contra tareas ya "completadas".
    #
    # El Test-Path de 'artisan' no es decorativo: hasta que URVA-2 bootstrapee
    # Laravel, 'php artisan' arranca igual (php esta en el PATH) y falla adentro
    # con "Could not open input file: artisan". Eso sale por stderr con exit code
    # 1, y un ejecutable nativo que devuelve != 0 NO lanza excepcion en
    # PowerShell: el catch de abajo no se dispara y el error crudo se imprime en
    # cada vuelta. Ademas $changedFiles no filtra nada mientras el repo no tenga
    # commits -- todo esta sin trackear, asi que da verdadero siempre.
    $changedFiles = git status --porcelain=v1 -- . ":(exclude).ralph/log.md" ":(exclude).ralph/tasks.md" 2>$null
    if ($changedFiles -and (Test-Path (Join-Path $RalphRepoRoot 'artisan'))) {
        try {
            php artisan queue:restart | Out-Null
            Write-Host "queue:restart disparado (codigo modificado en esta iteracion)." -ForegroundColor DarkGray
        }
        catch {
            Write-Warning "No se pudo ejecutar 'php artisan queue:restart': $_"
        }
    }

    # Las senales de fin (<promise>COMPLETE|BLOCKED</promise>) solo cuentan si son
    # la ultima linea no vacia de la respuesta (protocolo en prompt.md). Si el
    # modelo menciona el tag en medio del texto (p.ej. para corregirse a si mismo
    # tras emitirlo por error) no debe confundirse con una senal real.
    $nonEmptyLines = @($result -split "`r?`n" | Where-Object { $_.Trim() -ne "" })
    $lastLine = if ($nonEmptyLines.Count -gt 0) { $nonEmptyLines[-1].Trim() } else { "" }

    if ($lastLine -eq '<promise>COMPLETE</promise>') {
        Write-Host ""
        Write-Host "Todas las tareas completadas tras $i iteraciones." -ForegroundColor Green
        exit 0
    }

    if ($lastLine -eq '<promise>BLOCKED</promise>') {
        Write-Host ""
        Write-Host "Tarea $taskId bloqueada en la iteracion $i. Revisar log.md antes de continuar el loop." -ForegroundColor Red
        exit 1
    }
}

Write-Host ""
Write-Host "Se agotaron las $Iterations iteraciones sin COMPLETE ni BLOCKED." -ForegroundColor DarkYellow
