# Declaracion de YouTrack para este repo. ESTE ARCHIVO SE COMMITEA:
# nunca pongas un token aqui.
#
# Cascada que usan los scripts (ver scripts/youtrack-credentials.ps1):
#   1. .ralph/youtrack.config.ps1   override local, gitignoreado
#   2. este archivo                 commiteado, sin secretos
#   3. $HOME\.youtrack.config.ps1   credenciales del usuario
#   4. YOUTRACK_BASE_URL / YOUTRACK_TOKEN / YOUTRACK_PROJECT   entorno (CI)
#
# Asi un clon nuevo solo necesita un token: el proyecto y la instancia ya
# viajan con el repo.

$YouTrackBaseUrl = "https://uranodev.youtrack.cloud"
$YouTrackProject = "AIT"