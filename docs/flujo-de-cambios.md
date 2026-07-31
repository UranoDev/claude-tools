# Flujo para cambiar una herramienta

Cómo se modifica algo de este repo y cómo llega a los proyectos que ya lo tienen
instalado.

## La regla

**El arreglo va en `claude-tools`, nunca en la copia del proyecto.**

El error natural es arreglar la herramienta donde duele: en el proyecto donde
falló. Ahí el arreglo funciona, y por eso engaña. Pero `bootstrap.ps1` respeta lo
que ya existe y difiere —lo marca `~` y sigue—, así que ese arreglo sobrevive
hasta que alguien corra `install.ps1 -Force`, y entonces desaparece sin dejar
rastro de que existió.

Si algo urge, arréglalo en el proyecto para desbloquearte, pero **abre un issue en
AIT en el mismo momento**. Un arreglo local sin issue es deuda invisible: nadie
puede saber que está ahí, ni siquiera vos dentro de tres meses.

## El ciclo

### 1. Cambiar aquí

En `claude-tools`, no en un proyecto.

### 2. Probar contra un repo de juguete

Nunca contra un proyecto real: `-Force` sobre un repo con trabajo encima pisa
personalizaciones.

```powershell
$t = "$env:TEMP\prueba-tooling"
Remove-Item $t -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory $t | Out-Null
Push-Location $t; git init -q; Pop-Location

.\bootstrap.ps1 -ProjectKey ACME -ProjectName "Acme" -RepoRoot $t -DryRun
.\bootstrap.ps1 -ProjectKey ACME -ProjectName "Acme" -RepoRoot $t
.\bootstrap.ps1 -ProjectKey ACME -ProjectName "Acme" -RepoRoot $t   # 2a corrida
```

### 3. La segunda corrida tiene que dar todo `=`

Este paso no es ceremonia. Es el que encuentra los bugs de verdad, y los dos que
aparecieron al construir esto **solo se manifestaron aquí** — la primera corrida
se veía perfecta en ambos casos:

- **Viaje redondo de codificación.** `Get-Content -Raw` lee como ANSI en Windows
  PowerShell 5.1 cuando el archivo no trae BOM. Un `.ps1` en UTF-8 con un solo
  acento se corrompía al copiarse, y la corrida siguiente lo veía distinto y
  reportaba un cambio que nunca hubo. Por eso hoy los archivos que no llevan
  sustitución **se copian byte por byte**, y los que sí fijan UTF-8 explícito en
  los dos sentidos.
- **BOM en el `.gitignore`.** `Add-Content -Encoding utf8` se lo agrega al crear
  el archivo. Ahora se escribe con `.NET` y `UTF8Encoding($false)`.

Si la segunda corrida marca `~` en algo que el script acaba de escribir, hay un
viaje redondo de codificación. No lo ignores: significa que el archivo que quedó
en el proyecto no es el que está aquí.

### 4. Commit y push a `main`

`install.ps1` baja de esa rama. Mientras el cambio no esté en `main`, no existe
para los proyectos.

### 5. Propagar, proyecto por proyecto

```powershell
iwr https://raw.githubusercontent.com/UranoDev/claude-tools/main/install.ps1 -OutFile install.ps1
./install.ps1 -ProjectKey <CLAVE> -ProjectName "<Nombre>" -DryRun
```

**El `-DryRun` primero, siempre.** Lo que marque `~` está personalizado en ese
proyecto, y `-Force` se lo lleva.

### 6. Revisar los `~` a mano antes de forzar

Dos archivos casi siempre están personalizados y no se deben sobrescribir a
ciegas:

| Archivo | Qué lleva propio |
| --- | --- |
| `.ralph/prompt.md` | La lista de términos del glosario y los ADRs de ese proyecto |
| `AGENTS.md` | Secciones agregadas para ese repo |

Para esos, o aplicás el cambio a mano, o forzás y rehacés la personalización
después. No hay atajo.

## Cómo saber quién está atrasado

Cada proyecto tiene un `.tooling-version` con el commit que instaló:

```
origen:    https://github.com/UranoDev/claude-tools
version:   317eabd886540a213e16e39caa626e2a9fdb4071
instalado: 2026-07-31 02:03
```

Comparalo contra `git rev-parse HEAD` aquí. Si dice
`desconocida (instalado desde ZIP, sin git)`, se instaló desde un ZIP que no
traía `.git` y no hay forma de saber qué versión es: reinstalá para sellarlo.

Este archivo existe porque la instalación **vendoriza**. El proyecto se queda con
una foto, y un arreglo aquí no se propaga solo. Es deliberado —un submódulo de
git propagaría, pero obligaría a cada clon, cada despliegue y cada agente a
entender submódulos— y `.tooling-version` es lo que hace tolerable el costo:
responde la única pregunta que importa, que es a quién le falta.

## La trampa: `youtrack-credentials.ps1` existe dos veces

- `claude-tools/scripts/youtrack-credentials.ps1`
- `~/.claude/skills/youtrack-new-project/youtrack-credentials.ps1`

**No es un descuido.** `setup-youtrack-project.ps1` necesita resolver el token
*antes* de que las herramientas estén instaladas: en el orden de arranque, la
skill corre en el paso 2 y `install.ps1` en el paso 3. Si la skill dependiera de
la copia del proyecto, tendría que correr después de sí misma.

**Consecuencia: si tocás la cascada de credenciales, hay que actualizar los dos
lugares.** Es el único archivo con este problema, y no hay nada que lo detecte
automáticamente.
