# claude-tools

Herramientas que se repiten en cada proyecto: los scripts de release y
changelog contra YouTrack, el loop de construcción con agentes (`ralph`), y los
docs que le enseñan las convenciones del tracker a las sesiones futuras.

Existen aquí y no en cada repo por una razón concreta: **`/.ralph` está en el
`.gitignore` de los proyectos**, así que el loop no está versionado en ninguno
de ellos. Sin este repo, ese código no tiene historia en ningún lado.

## Instalar en un proyecto nuevo

Desde la raíz del proyecto, ya con `git init` hecho:

```powershell
iwr https://raw.githubusercontent.com/UranoDev/claude-tools/main/install.ps1 -OutFile install.ps1
./install.ps1 -ProjectKey ACME -ProjectName "Acme Portal"
Remove-Item install.ps1
```

Sin parámetros los pregunta por consola:

```powershell
./install.ps1
```

Para ver qué haría sin escribir nada, `-DryRun`.

Si ya tienes el repo clonado, `bootstrap.ps1` hace lo mismo sin descargar:

```powershell
C:\ruta\a\claude-tools\bootstrap.ps1 -ProjectKey ACME -ProjectName "Acme Portal"
```

## Qué instala

| Destino | Qué es |
| --- | --- |
| `scripts/release.ps1` | Corta una versión CalVer: refresca issues → regenera CHANGELOG → commit → tag |
| `scripts/changelog.ps1` | Genera `CHANGELOG.md` desde los issues resueltos en YouTrack |
| `scripts/refresh-issues-resolved.ps1` | Refresca el caché `issues-resolved.json` |
| `scripts/youtrack-credentials.ps1` | Resuelve URL + token + proyecto por cascada |
| `.ralph/ralph.ps1` | El loop: invoca `claude` una vez por issue hasta agotar el backlog |
| `.ralph/prompt.md` | El protocolo de una vuelta del loop, con la clave del proyecto sustituida |
| `.ralph/log.md` | Bitácora y métricas de costo (se crea vacío) |
| `AGENTS.md` | Convenciones del tracker, resumidas |
| `docs/agents/issue-tracker.md` | Cómo se usa YouTrack en este proyecto |
| `docs/agents/triage-labels.md` | Los cinco roles de triage |
| `.tooling-version` | Qué versión de estas herramientas quedó instalada |

Además agrega `/.ralph` al `.gitignore` del proyecto.

## Idempotencia

`bootstrap.ps1` se puede volver a correr para actualizar herramientas en un
proyecto que ya lleva trabajo encima. Cada archivo informa:

- `+` escrito
- `=` ya estaba idéntico
- `~` existe y difiere — **se respeta**, `-Force` para sobreescribir

`.ralph/log.md` nunca se toca si ya tiene contenido.

## Esto es una copia, no un enlace

La instalación **vendoriza**: el proyecto se queda con una foto de las
herramientas. Un arreglo aquí **no se propaga solo** a los proyectos ya
creados — hay que volver a correr `install.ps1` en cada uno.

Es deliberado. Un submódulo de git propagaría los cambios, pero a cambio de
que cada clon, cada despliegue y cada agente tengan que entender submódulos.
Para cinco scripts no vale la pena.

Por eso existe `.tooling-version`: dice qué commit quedó instalado, que es lo
que se necesita para saber qué proyectos están atrasados.

## Cambiar una herramienta

**El arreglo va aquí, nunca en la copia del proyecto.** Un arreglo hecho en el
proyecto sobrevive hasta el primer `install.ps1 -Force` y después desaparece sin
dejar rastro.

El procedimiento completo —cómo probarlo, por qué la segunda corrida importa,
cómo propagarlo y qué archivos no se deben forzar— está en
**[docs/flujo-de-cambios.md](docs/flujo-de-cambios.md)**.

## Credenciales

Los scripts resuelven URL y token de YouTrack por cascada, del más específico
al más general:

1. `.ralph/youtrack.config.ps1` del repo (gitignoreado)
2. `.youtrack-project.ps1` del repo (commiteado, **sin secretos**)
3. `$HOME\.youtrack.config.ps1`
4. `YOUTRACK_BASE_URL` / `YOUTRACK_TOKEN` / `YOUTRACK_PROJECT`

**El token vive solo en `$HOME\.youtrack.config.ps1`.** Nunca en un repo.
La capa 2 está versionada precisamente para que el proyecto y la URL de la
instancia —que no es secreto— viajen con el código, y el token no.

## Orden al arrancar un proyecto

1. `laravel new <proyecto>` (o el stack que sea) → `git init` → primer commit

   El framework primero: `composer create-project` exige un directorio vacío,
   así que instalar herramientas antes rompe la instalación.

2. Skill `youtrack-new-project` en una sesión de Claude → crea el proyecto en
   YouTrack, los campos `Triage`/`Cost` y `.youtrack-project.ps1`

3. `install.ps1` → lo que documenta este README

4. `CONTEXT.md` a mano — el glosario del dominio

5. La épica (`Type: Epic`) y los issues colgados de ella

   La épica va primero: la convención es que todo issue nazca con
   `parentIssue`, así que tiene que existir antes del primero.

6. `.ralph/ralph.ps1` para arrancar el loop

## Correr el loop por grupos

Por defecto `ralph.ps1` toma cualquier candidata del backlog. Para acotar la corrida
a un grupo concreto —y poder revisar y commitear ese grupo junto— se le pasa la lista:

```powershell
.ralph/ralph.ps1 -Issues ACME-20,ACME-21
```

Dos cosas que el parámetro **no** hace, y son deliberadas:

- **No reemplaza el filtro de `Triage`, se suma a él.** Un issue de la lista que no esté
  en `ready-for-agent` se salta y se menciona. Si estaba en `ready-for-human` era porque
  tenía decisiones sin resolver, y ejecutarlo significaría que el agente las invente.
- **No salta las dependencias.** Un issue de la lista bloqueado por otro que no está en
  la lista se descarta igual. Enumerar IDs no vuelve seguro ignorar el grafo.

**El loop sigue sin commitear.** Qué y cuándo se commitea lo decide una persona, después
de revisar lo que la corrida produjo.

Sin `-Issues`, el comportamiento es exactamente el de siempre.

## Sobre `.git`

Ni `install.ps1` ni `bootstrap.ps1` tocan `.git`, ni el propio ni el del
destino. `install.ps1` baja un ZIP en vez de clonar justamente para que no
exista un `.git` que haya que borrar después: ese borrado correría dentro de
la carpeta del proyecto, que para entonces ya tiene su propia historia.
