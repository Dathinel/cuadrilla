# Cuadrilla

Una orden (`herramientas\cuadrilla.ps1`) que delega un encargo a ChatGPT (CLI `codex`), Gemini (CLI `agy`), Devin (CLI `devin`) o Claude (CLI `claude`), espera y termina. Claude dirige y revisa; no hay proceso residente. Cómo funciona: `docs/cuadrilla-ligera.md`; decisiones: `docs/decisiones.md`.

## Dónde está cada cosa
- `herramientas\`: `cuadrilla.ps1` (`delegar`, `estado`, `cortar`, `cuota`), `proceso.ps1` (Job con KILL_ON_JOB_CLOSE), `comun.ps1`, `worktrees.ps1`, `git-bloqueo\` (hook que impide escribir refs en el CLI), `instalar.ps1`.
- `plantillas\cuadrilla\SKILL.md`: la skill de Claude Code; `{{CUADRILLA}}` se sustituye por esta carpeta al instalarla.
- `datos\` (no versionado salvo `mesa.ejemplo.json`): configuración, exclusiones, encargos y `trabajos\<id>\`.
- `oficina\`: panel de solo lectura a demanda; contrato en `oficina\LEEME.md`.
- `pruebas\`: `Probar.bat` corre `probar-cuadrilla`, `caos-procesos` y `probar-oficina` con CLI falsos; `probar-real.ps1` gasta un poco de cuota real.

## Reglas
- Solo los binarios oficiales de los CLI con su propia sesión; nada lee, guarda ni intermedia tokens, credenciales ni transcritos de sesión.
- Sin simular teclas ni abrir programas con interfaz. Nada bajo `datos\excluidos.txt`.
- PowerShell 5.1, rutas con espacios y tildes, `.ps1` y `.bat` en CRLF.
- Un cambio se une con `Probar.bat` en verde. Comentarios mínimos, solo para el porqué.
