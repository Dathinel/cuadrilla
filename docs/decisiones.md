# Decisiones de Cuadrilla

## D-001: Una orden que termina, sin procesos residentes (octubre de 2026)

**Decisión.** Se sustituye la primera Cuadrilla (hilos, supervisor y panel siempre abiertos) por una sola orden, `herramientas\cuadrilla.ps1`, que lanza un encargo a un CLI, espera y termina. Claude la ejecuta en segundo plano y Claude Code le avisa al acabar: no hay cola, hook, sondeo ni proceso residente. Detalle en `docs/cuadrilla-ligera.md`.

**Por qué.** El panel y el supervisor gastaban un 34 % y un 12-15 % de un núcleo sin trabajo; se acumularon 141 encargos fantasma; agy se colgó dos veces 90 min con un log de 63 bytes; tres codex en paralelo agotaron la cuota; y la cuota, los costes y el vigía exigían leer transcritos de sesión. Lo resuelve una orden que valida antes de lanzar, candados por CLI, un corte por silencio y un `resultado.json` atómico.

**Lo que cambia.**
- Código activo: de unas 13 000 líneas a unas 1 000 en `herramientas\` (pruebas aparte).
- Datos: solo `datos\mesa.json`, `excluidos.txt`, `encargos\` y `trabajos\<id>\`.
- Git en el CLI: hook `reference-transaction` por `GIT_CONFIG_COUNT` (solo en el entorno del proceso) que aborta commit, rama, reset, stash y el push a un remoto local; `pushInsteadOf` desvía https://, git@ y ssh://. Comprobado con los CLI reales en un repo temporal con remoto bare: **agy** hereda el entorno y `git commit --allow-empty` y `git push origin HEAD:main` fallan con «update aborted by the reference-transaction hook»; **codex** recibe las variables `GIT_CONFIG_*` completas (se le pasan con `-c shell_environment_policy.set`, porque quita del entorno las que llevan KEY en el nombre). El remoto quedó intacto en los dos casos.
- Dos `delegar` a la vez sobre el mismo repo chocan en los candados de git al crear el worktree: `worktrees.ps1 crear` reintenta hasta tres veces.

**Prueba real.** codex `gpt-6-luna` low y agy `gemini-3.8-flash-low` a la vez con `-Lectura` sobre un repo: los dos `hecho` con salida 0 en 12 y 15 s, 56 131 y 25 343 tokens leídos del evento final, `cpu_lanzador_s` 0,67 y 0,78, `git status --porcelain` idéntico, ningún worktree y 0 procesos de la herramienta antes y después (`pruebas\probar-real.ps1`).

**Tras la revisión independiente.** `estado` relee el `resultado.json` después de confirmar que el lanzador murió y solo lo marca interrumpido si sigue en ejecutando. `Mesa-EscribirJson` usa `File.Replace` (atómico) con reintentos, porque otro proceso puede tener el archivo abierto en ese instante. `worktrees.ps1 crear` rechaza una carpeta sin `.git` (apagón a mitad de `git worktree add`). El hook va fijado a LF en `.gitattributes`. Un encargo ya «hecho» con el mismo .md y la misma tarea solo se rechaza cuando hay worktree que proteger: con `-Lectura` se repite. Una raíz de unidad como `-Dir` se rechaza.

**Límites del bloqueo de git, dicho claro.** El hook y `pushInsteadOf` frenan el descuido, no a un CLI que quiera saltárselo: `pushInsteadOf` no cubre remotos `http://` ni rutas de red de otra máquina, y toda la configuración por `GIT_CONFIG_*` la anula un `git -c core.hooksPath=` o un entorno limpio. Quedan como segunda red los avisos de «HEAD del worktree se movió» y «cambió refs/remotes/origin/<rama>», que Claude lee antes de confirmar.

**Pendiente (no bloquea).** Dos `delegar` a la vez sobre el mismo repo pueden añadir dos veces `/.claude/worktrees/` a `.git\info\exclude`; es inofensivo.

## D-002: Devin como tercer ayudante y CLI sin sandbox por defecto (noviembre de 2026)

- **Qué:** `cuadrilla.ps1` acepta `-A devin` (CLI de Devin, modelo `swe-2-high` por defecto). Los tres CLI corren sin sandbox ni permisos que pedir por defecto: codex con `--dangerously-bypass-approvals-and-sandbox`, agy con `--dangerously-skip-permissions`, devin con `--permission-mode dangerous` y sin comprobar la confianza del workspace. `-Lectura` sigue sin poder escribir y `-Sandbox` vuelve al modo limitado al worktree.
- **Por qué:** con sandbox, codex se paraba al restaurar paquetes sin red y al no poder leer sus skills; Devin se negaba a correr en worktrees nuevos sin confianza. Si Claude Code trabaja sin pedir permisos, los ayudantes van igual.
- **Lo que no cambia:** cada encargo va en su worktree; el bloqueo de git sigue en todos los modos, porque revisar y subir es de Claude; nada bajo `excluidos.txt`.
- **Riesgo aceptado:** sin sandbox un CLI puede ejecutar cualquier orden con el usuario de Windows. Se mitiga con encargos que nombran los archivos y un «No toques», y revisando el diff antes de confirmar. Devin con SWE-2 es el menos fiable: solo tareas pequeñas y cerradas. Comprueba con `devin models` qué modelos se cobran.

## D-003: Varios encargos a la vez por CLI (noviembre de 2026)

- **Qué:** el candado único por CLI pasa a N puestos (`datos\trabajos\<cli>.<n>.lock`, `puestos` en `mesa.json`: codex 3, agy 4, devin 4 por defecto), que se toman abriendo el archivo en exclusiva (sin carrera) y se sueltan solos si el proceso muere. Un candado por tarea y repo impide que dos encargos con la misma tarea compartan worktree y rama; el id de la carpeta de trabajo se reserva con `CreateNew`. `estado` lista todos los vivos de cada CLI. El tope de worktrees por agente nunca baja de sus puestos.
- **Por qué:** los CLI son independientes y sus cuotas dan para más de un encargo a la vez; el límite real es la cuota, no el proceso.
- **Aislamiento entre instancias:** cada encargo tiene su worktree, rama, carpeta, `prompt.txt`, `log.jsonl` y `final.txt`, y las variables `GIT_CONFIG_*` solo en el entorno de su proceso. codex va con `--ephemeral` (sin archivos de sesión en `~/.codex`) y agy con `--log-file` propio en la carpeta del encargo. Devin arranca una sesión nueva por encargo (sin `--continue`). `cuota-*.txt` y `uso.jsonl` se anotan con `Mesa-Anotar` (reintento ante escritores a la vez) y `Mesa-LeerJson` reintenta si otro proceso está reemplazando el archivo.
- **Cuota:** manda el último encargo que terminó hecho o sin cuota (no el último lanzado, que puede seguir vivo): si fue sin cuota, ningún puesto de ese CLI se lanza hasta la hora de vuelta. En agy, por familia de modelos.
- **Rutas cortas:** el worktree del CLI se crea siempre en `<repo principal>\.claude\worktrees\<cli>-<tarea>`, aunque `-Dir` sea un worktree (anidado, un proyecto WinUI no compilaba por MAX_PATH); parte de la rama de `-Dir`. La misma tarea lanzada desde otro `-Dir` se rechaza.
- **Nivel:** `-Nivel bajo|medio|alto` o `Nivel: alto` en el .md; `niveles` de `mesa.json` lo traduce a modelo y esfuerzo por CLI. `-Modelo` y `-Esfuerzo` mandan.
- **Gasto:** los modelos de pago de Devin solo van si están en `pago.devin` de `mesa.json` y el nivel o `-Modelo` los piden; su cuota va aparte de la gratuita. No hay límite calculado por defecto: `limite_uso` existe pero va apagado, para calibrarlo con los datos de `datos\trabajos\uso.jsonl`, una línea por encargo con modelo, esfuerzo, duración, tokens, coste aproximado y cuota antes y después.
- **Qué da cada CLI para leer cuota o gasto:** agy, `-p /usage` (lo que queda de cada límite de 5 h y semanal, con su reinicio) y tokens en su evento final; codex, tokens en `turn.completed` y los límites por `codex app-server` (`account/rateLimits/read`: porcentaje usado de 5 h y semana, hora de reinicio y restablecimientos disponibles, en 2 s y sin gastar); devin, nada: `-p` imprime texto sin tokens, así que su coste no se puede calcular.
