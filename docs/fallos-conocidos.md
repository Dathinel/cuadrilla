# Fallos conocidos

Cada problema real se anota con su síntoma, su causa y qué hacer.

| Síntoma | Causa | Qué hacer |
|---|---|---|
| Un `.bat` lanza decenas de «no se reconoce como un comando» | Se guardó con finales LF; cmd solo entiende CRLF. | `.gitattributes` lo fija en CRLF. Si se edita fuera de git, guardar con CRLF. |
| agy falla con `RESOURCE_EXHAUSTED` / 429 | Cuota de su familia de modelos agotada. | `delegar` sale con causa `sin-cuota` y la hora de vuelta; hasta entonces rechaza esa familia con salida 3. Usa otra familia (`-Modelo`) u otro CLI. |
| agy avisa `--mode auto is not available for this account` | La cuenta no tiene el modo automático. | Cuadrilla usa `--mode accept-edits` (o `plan` con `-Lectura`). |
| agy termina con `status: ERROR` habiendo respondido | Fallo interno de agy al cerrar. | Sin causa real, queda `hecho` con aviso (salida 2): lee la respuesta. |
| Un encargo queda `colgado` (salida 124) | 20 min sin salida, sin archivos escritos en el worktree y sin CPU de los hijos. | Sube `limites.inactivo_min` en `mesa.json` o relanza la misma orden: sigue en el mismo worktree con la cabecera REINTENTO. |
| Un encargo queda `interrumpido` | Se cerró la sesión de Claude Code o hubo un apagón: el Job cortó el CLI. | Repite la misma orden. |
| `NO LANZADO: no se pudo crear el worktree: ... worktrees vivos (tope N)` | Hay worktrees de ese agente sin integrar o sin limpiar. | Intégralos y ejecuta `herramientas\worktrees.ps1 limpiar`. |

## Ciclo de vida del lanzador

Al terminar un encargo se cierra el Job de Windows y se mata todo el árbol que lanzó el CLI, incluidos servidores o procesos que pretendiera dejar en segundo plano.

Riesgo bajo pendiente: `Process.Start` arranca el CLI antes de asignarlo al Job. Un CLI que cree un nieto inmediatamente podría dejarlo fuera del Job. Evitarlo requiere arranque nativo suspendido y redirecciones mediante handles heredables; se pospone para no reemplazar el transporte probado de PowerShell 5.1. Los descendientes creados después de asignar el Job sí quedan contenidos.
