<h1 align="center">Cuadrilla</h1>

<p align="center">
  Claude dirige; ChatGPT (CLI <code>codex</code>), Gemini (CLI <code>agy</code>, Antigravity), Devin (CLI <code>devin</code>) y Claude (CLI <code>claude</code>, con su propia suscripción) hacen lo mecánico.<br>
  Una orden lanza el encargo en su propio worktree, espera y termina. Sin procesos residentes: 0 % de CPU en reposo.
</p>

<p align="center">
  <a href="LICENSE"><img src="https://img.shields.io/badge/licencia-MIT-E8833A?style=flat-square&labelColor=1D1D1D" alt="Licencia MIT"></a>
  <img src="https://img.shields.io/badge/Windows-10%20%7C%2011-E8833A?style=flat-square&labelColor=1D1D1D" alt="Windows 10 y 11">
  <img src="https://img.shields.io/badge/PowerShell-5.1-E8833A?style=flat-square&labelColor=1D1D1D&logo=powershell&logoColor=white" alt="PowerShell 5.1">
</p>

## Qué hace

Claude Code escribe un encargo en un `.md` (objetivo, contexto, hecho cuando, no toques) y lo delega con una orden en segundo plano. Cuadrilla valida antes de lanzar, crea un worktree y una rama para el CLI, le impide escribir refs y hacer push, corta lo que se cuelga, respeta la cuota de cada CLI y deja todo en `datos\trabajos\<id>\resultado.json`. Claude revisa el diff, confirma y abre el PR.

- **Puestos:** varios encargos a la vez por CLI (por defecto ChatGPT 3, Gemini 4, Devin 4).
- **Niveles:** `-Nivel bajo|medio|alto` elige modelo y esfuerzo según `datos\mesa.json`.
- **Cuota y uso:** rechazo inmediato si un CLI está sin cuota, hasta la hora de vuelta; registro por encargo en `uso.jsonl` (duración, tokens, coste aproximado).
- **Oficina:** panel pixel-art de solo lectura, a demanda, en `http://127.0.0.1:8765/` (`oficina\ABRIR-OFICINA.bat`).

## Requisitos

Windows 10 u 11 con PowerShell 5.1, `git`, Claude Code y al menos uno de los CLI oficiales (`codex`, `agy`, `devin`) instalado y con la sesión iniciada. Cuadrilla no instala nada, no guarda credenciales y no lee transcritos de sesión: solo lee lo que cada CLI imprime en el encargo.

## Instalación

```
powershell -NoProfile -ExecutionPolicy Bypass -File herramientas\instalar.ps1
```

Crea `datos\mesa.json` (desde `datos\mesa.ejemplo.json`), `datos\excluidos.txt` y `datos\trabajos\`, e instala la skill `cuadrilla` en `%USERPROFILE%\.claude\skills\` con la ruta de esta carpeta. Con ella, Claude Code sabe cuándo delegar y cómo. Ajusta en `mesa.json` los modelos que tengas disponibles.

## Uso

```
herramientas\cuadrilla.ps1 delegar -A chatgpt -Encargo "C:\proyectos\web\encargos\pruebas-login.md" -Dir "C:\proyectos\web" -Nivel bajo
```

El CLI trabaja en `C:\proyectos\web\.claude\worktrees\codex-pruebas-login`, rama `codex/pruebas-login`. Salida `0` hecho, `2` hecho con aviso, `1` fallo, `124` tiempo o colgado, `3` no lanzado (con el motivo, en menos de 3 s).

Otras opciones: `-A gemini|devin`, `-Modelo`, `-Esfuerzo low|medium|high`, `-Lectura` (solo lee, sin worktree), `-Sandbox [-Red]`, `-Minutos n`, `-Tarea t` (corrección en el mismo worktree). Además: `estado [<id>]`, `cortar <id>` y `cuota`. Detalle en [`docs/cuadrilla-ligera.md`](docs/cuadrilla-ligera.md).

## Evidencias

| Qué | Primera versión (hilos, supervisor y panel) | Cuadrilla |
|---|---|---|
| Procesos en reposo | supervisor (12-15 % de un núcleo) + panel (34 %) | 0 |
| Código activo | ~13 000 líneas | ~1 000 en `herramientas\` |
| Encargo rechazado (CLI ausente, ruta mala, modelo inválido, sin cuota) | se encolaba o fallaba a los minutos | salida 3 en menos de 3 s, sin arrancar el CLI |
| CLI mudo | 90 min colgado | corte a los 20 min sin salida, sin archivos y sin CPU |

`Probar.bat` corre 114 casos en copias aisladas de `%TEMP%` con CLI falsos, sin gastar cuota: `pruebas\probar-cuadrilla.ps1` (65: salidas, rechazos, puestos, cortes, git bloqueado, instalación), `pruebas\caos-procesos.ps1` (17 del lanzador) y `pruebas\probar-oficina.ps1` (32 del panel y su saneado). `pruebas\probar-real.ps1` lanza un encargo de solo lectura a codex y agy reales con modelos baratos. La CI de GitHub corre `Probar.bat` en cada push.

## Licencia

[MIT](LICENSE). Sin dependencias de terceros: solo PowerShell y las API de Windows ([`LICENCIAS.md`](LICENCIAS.md)). Decisiones en [`docs/decisiones.md`](docs/decisiones.md).
