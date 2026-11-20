# Cómo funciona Cuadrilla

## Qué es
Claude dirige; codex (`codex exec`), agy (`agy -p`), devin (`devin -p`) y claude (`claude -p`) hacen lo mecánico. Claude escribe el encargo en un .md y lo lanza con su Bash o su PowerShell en segundo plano (`run_in_background`), y Claude Code le avisa al terminar: no hay sondeo, hook, cola ni panel residente. Cada encargo deja `datos\trabajos\<id>\` con encargo.md, prompt.txt, log.jsonl, final.txt y `resultado.json`, este escrito de forma atómica. En reposo no queda ningún proceso: 0 % de CPU.

Sustituye a una primera versión con hilos, supervisor y panel siempre abiertos, que gastaba un 34 % y un 12-15 % de un núcleo sin trabajo y unas 13 000 líneas de código (D-001).

## Piezas
| Pieza | Ruta | Qué hace |
|---|---|---|
| Orden única | `herramientas\cuadrilla.ps1` | Subcomandos `delegar`, `estado [<id>]`, `cortar <id>` y `cuota`. |
| Lanzador | `herramientas\proceso.ps1` | Job de Windows con KILL_ON_JOB_CLOSE, UTF-8, stdin aparte, shims de npm. `-Inactivo <s>`: sin salida, sin archivos escritos y sin CPU de los hijos en ese tiempo, corta el árbol con salida 124 y causa `colgado`. |
| Biblioteca | `herramientas\comun.ps1` | Rutas, configuración, JSON atómico, exclusiones, `Mesa-CausaFallo` (cuota, login, red) y `Mesa-Ocultar` (secretos fuera de la respuesta). |
| Worktrees | `herramientas\worktrees.ps1` | `crear`, `lista` y `limpiar`. `limpiar` solo quita los integrados y limpios, y respeta los de un agente con un encargo en marcha. |
| Bloqueo de git | `herramientas\git-bloqueo\reference-transaction` | Hook que aborta toda escritura de refs: commit, rama, reset, stash. El lanzador lo activa solo en el entorno del CLI con `GIT_CONFIG_COUNT`, que pone `core.hooksPath` y `url.cuadrilla-sin-push://.pushInsteadOf` para https://, git@ y ssh://. No toca la configuración del repo. |
| Skill | `plantillas\cuadrilla\SKILL.md`, instalada en `%USERPROFILE%\.claude\skills\cuadrilla\` | Cuándo delegar, la orden exacta, qué hacer con cada salida, revisión y PR. Vale en cualquier proyecto y se invoca sola o con `/cuadrilla`. |
| Instalación | `herramientas\instalar.ps1` | Crea `datos\mesa.json`, `excluidos.txt` y `trabajos\` si faltan, y escribe la skill con la ruta de esta carpeta si difiere. `estado` avisa si la copia instalada no coincide. |
| Configuración | `datos\mesa.ejemplo.json` | `modelos` (el primero es el de por defecto), `pago`, `niveles`, `precios`, `limites` (`encargo_min` 90 e `inactivo_min` 20), `limite_uso` (apagado), `worktrees.max_por_agente` y `puestos`. Lo que falte en `mesa.json` se toma del ejemplo. |
| Oficina | `oficina\` | Panel pixel-art de solo lectura en `127.0.0.1:8765`, a demanda. Contrato en `oficina\LEEME.md`. |
| Pruebas | `pruebas\` y `Probar.bat` | CLI falsos en una copia aislada (`MESA_DATOS`), sin gastar cuota, y una prueba real de solo lectura. |

## delegar, paso a paso
`delegar -A chatgpt|gemini|devin -Encargo <md> -Dir <carpeta> [-Tarea t] [-Modelo m] [-Esfuerzo low|medium|high] [-Nivel bajo|medio|alto] [-Lectura] [-Sandbox [-Red]] [-Minutos n]`
1. **Valida antes de tocar nada.** Si algo falla, responde `NO LANZADO: <motivo>` con salida 3 en menos de 3 s. Comprueba que el CLI está en el PATH; que el .md y -Dir existen; que la ruta no lleva `$`, `(` ni backtick; que nada cae bajo `datos\excluidos.txt`; que el modelo está en `mesa.json`; que, si -Dir contiene repos sin ser uno, se pidió -Lectura; que el CLI no tiene un `sin-cuota` vigente; y que la misma tarea no está viva ni hecha con el mismo hash del .md.
2. **Puestos.** `datos\trabajos\<agente>.<n>.lock` con n de 1 a `puestos.<agente>` (por defecto codex 3, agy 4, devin 4), abiertos en exclusiva durante todo el encargo: el lanzador toma el primero libre y Windows lo suelta si el proceso muere. Además, `tarea-<agente>-<huella>.lock` impide dos encargos de la misma tarea sobre el mismo repo.
3. **Worktree.** Si -Dir es un repo y no hay -Lectura, `worktrees.ps1 crear` da `<repo principal>\.claude\worktrees\<agente>-<tarea>` en la rama `<agente>/<tarea>`, siempre en la raíz del repo principal aunque -Dir sea ya un worktree (anidados pasan de MAX_PATH). La rama de partida es la de -Dir. La tarea es el nombre del .md sin `encargo-` ni el agente. Si la creación falla, no se lanza. Si el worktree ya existe, se reutiliza y el reintento sigue donde quedó.
4. **Prompt.** Una cabecera fija más el encargo. Las rutas `<repo>\...` que existen en el worktree se cambian a él; lo no versionado sigue en el original. La cabecera dice dónde trabaja, que no hace commit ni push, que no abre programas con interfaz ni deja procesos, y que termina con «Hecho / Archivos tocados / Cómo lo probaste / Pendiente». Tras un fallo o un corte añade «REINTENTO: el intento <id> terminó <estado>; log <ruta>; mira git status y no repitas lo hecho».
5. **Lanza** dentro del Job, con `resultado.json` ya en `ejecutando` y la identidad del lanzador (pid, inicio y nombre).
   - codex: `exec --skip-git-repo-check --ephemeral -C <trabajo>` más `-s read-only` (-Lectura), `-s workspace-write` (-Sandbox, con red solo con -Red) o `--dangerously-bypass-approvals-and-sandbox`; `--json -m <m> -c model_reasoning_effort=<e> -o final.txt -`, con el prompt por stdin.
   - agy: `-p "Lee el encargo completo en el archivo UTF-8 <prompt.txt> y ejecuta sus instrucciones." --model <m> --mode accept-edits|plan --output-format stream-json --log-file <carpeta>\agy.log`, y `--dangerously-skip-permissions` sin sandbox.
   - devin: `-p --prompt-file <prompt.txt> --model <m> --permission-mode dangerous|accept-edits|auto --respect-workspace-trust false`.
6. **Recoge.** El texto sale de `final.txt` o del último `agent_message` en codex, de `response` en agy y de la salida llana en devin; se queda la cola de 3 000 caracteres, pasada por `Mesa-Ocultar`, y la completa en `final.txt`. Los tokens, del evento final. La causa, de `Mesa-CausaFallo`, o `tiempo` o `colgado`. Los cambios, de `git status --short` y `diff --stat`. Hay aviso si se movió HEAD, si cambió `refs/remotes/origin/<rama>` o si cambió el status del checkout principal (o de la carpeta, con -Lectura).
7. **Sale** con 0 (hecho), 2 (hecho con aviso), 1 (fallo), 124 (tiempo o colgado) o 3 (no lanzado). Imprime una línea de resumen, la ruta de `resultado.json` y la respuesta.

Los otros subcomandos no leen transcritos de sesión:
- `estado` lee los `resultado.json` y `uso.jsonl`: una línea por agente («Devin (devin): 2 de 4 ocupados: <id> (12 min; log hace 0 min), …»; sin cuota hasta HH:MM; no instalado), su uso en 5 h y en 7 días, y los 10 últimos encargos. Un `ejecutando` cuyo lanzador ya no vive pasa a `interrumpido`.
- `cortar <id>` comprueba la identidad y mata al lanzador; el Job se lleva el árbol.
- `cuota` da la última señal sin cuota de cada agente, el uso acumulado y la lectura en vivo: `agy -p /usage` y los límites de codex por `codex app-server` (`account/rateLimits/read`), con tiempo máximo. Devin no ofrece lectura de cuota.

**Nivel, pago y registro de uso.** `-Nivel` (o una línea `Nivel: alto` en el .md) se traduce con `niveles.<nivel>.<cli>` a modelo y esfuerzo; `-Modelo` y `-Esfuerzo` mandan. Un modelo vale si está en `modelos.<cli>` o en `pago.<cli>`. Al terminar, cada encargo añade una línea a `datos\trabajos\uso.jsonl`: id, agente, modelo, esfuerzo, nivel, pago, estado, causa, inicio, fin, segundos, tokens, `usd` (tokens por `precios.<modelo>`; en ChatGPT y Gemini es el equivalente de API) y la cuota antes y después. `limite_uso` (`activo`, `horas`, `encargos.<cli>`, `tokens.<cli>`; 0 = sin tope) va apagado.

## Flujo
1. El usuario pide algo. Claude separa lo que pide criterio (diseño, revisión, publicación, licencias, lo irreversible) de lo mecánico y comprobable. Lo que lleva menos de 5 min lo hace él.
2. Escribe el encargo con cuatro apartados: Objetivo, Contexto (rutas absolutas y reglas del repo), Hecho cuando (con la orden que lo demuestra) y No toques.
3. Lo lanza con `run_in_background: true` y sigue con otra cosa. `estado` responde en menos de 1 s.
4. Al llegar el aviso, revisa en el worktree: avisos, `git -C <wt> diff`, compilación y pruebas. Si vale: commit, push de la rama y `gh pr create`. Si no: lo corrige, o escribe `<t>-correccion.md` y relanza con `-Tarea <t>` en el mismo worktree.
5. Tras unir, `worktrees.ps1 limpiar`. Al abrir sesión, `cuadrilla.ps1 estado` enseña lo interrumpido, que se retoma repitiendo la orden.

## Fallos reales cubiertos
| Fallo visto | Qué lo evita |
|---|---|
| Panel y supervisor con un 34 % y un 12-15 % de un núcleo sin trabajo | No queda ningún proceso residente |
| agy colgado 90 min con un log de 63 bytes | stream-json siempre y corte tras 20 min sin salida, sin archivos y sin CPU |
| agy marcado «fallo» habiendo entregado la respuesta | `hecho con aviso` (salida 2); el 503 cuenta como red |
| Tres codex en paralelo sin cuota; «hasta» mal calculado | Hora leída de «try again at»; rechazo inmediato hasta esa hora en todos los puestos del CLI |
| 3 KB de JSON crudo como respuesta de codex | `item.text` del último `agent_message` |
| Rutas con `$A` y `$( )`; modelo inexistente | Validación previa, con salida 3 |
| Prefijo `codex-codex-*`; worktree fallido que cae al checkout principal | Nombre de tarea limpio; sin worktree no se lanza |
| Push y `.git` prohibidos solo en el prompt | Bloqueo de refs y de push en el entorno del CLI; avisos después |
| Apagón a mitad | `resultado.json` atómico; `estado` lo marca `interrumpido`; la misma orden retoma en el worktree |
| Lectura de transcritos de sesión para cuota y costes | Los tokens salen del evento final del propio CLI |

## Riesgos abiertos
- **El encargo vive lo que la sesión de Claude Code.** Si la app se cierra, el Job corta el CLI, el encargo queda `interrumpido` y se retoma con la misma orden.
- **Corte por silencio.** Una compilación larga que no narra, no escribe archivos y no gasta CPU en los hijos se cortaría a los 20 min; se sube con `inactivo_min` o -Minutos.
- **Sin sandbox por defecto** (D-002): el CLI puede ejecutar cualquier orden con tu usuario. Se mitiga con encargos que nombran los archivos y un «No toques», y revisando el diff antes de confirmar.
- **Lectura de muchos resultados.** `estado`, `delegar` y `cuota` leen todos los `resultado.json` de `datos\trabajos\`; con cientos de encargos el «menos de 1 s» se degrada. Se pueden mover los viejos a otra carpeta.
