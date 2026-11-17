# Oficina Estrella (reunificada con la Cuadrilla)

La sala pixel-art de la mesa vuelve a estar viva: los sprites de Claude, Codex y agy en sus
puestos, la línea de tiempo del día, el archivo y el teletipo — pero ahora el estado sale
**solo** de la Cuadrilla ligera (`datos\trabajos\`, candados y `mesa.json`). No hay hilos,
reuniones ni calibrador: lo que no tiene fuente real se muestra como «sin dato».

## Arrancar

`oficina\ABRIR-OFICINA.bat` (o `powershell -File oficina\servidor.ps1 [-Puerto 8765]`).
Abre `http://127.0.0.1:8765/` en el navegador. El servidor se cierra con Ctrl+C, al cerrar
la consola o solo tras ~2 minutos sin clientes (~90 s si nadie abre la página).

## Contrato de `/api/estado`

Una sola respuesta JSON de solo lectura:

| Campo | Contenido |
|---|---|
| `version` | `oficina-1` |
| `generado_en` | ISO de cuándo se armó |
| `agentes[]` | `id`, `nombre`, `estado` (pose: `escribiendo`/`esperando`/`apagado`/`error`), `estado_texto`, `online`, `tarea`, `ultima` (tipo del último evento del log), `modelo`, `esfuerzo`, `personaje` (estático), `energia` (`null`, sin fuente), `estadisticas` (`tokens_hoy`, `tokens_7d`, `hechas_hoy`, `fallidas_hoy`, `tokens_parcial`), `tokens_7d_hist`, `vuelve` (si `sin-cuota`), `candado` |
| `trabajos[]` | Los últimos 40: `id`, `agente`, `tarea`, `modelo`, `estado`, `causa`, `inicio`, `fin`, `lectura`, `worktree`, `tokens`, `avisos`, `resumen` |
| `hilos[]` | Los últimos 20 trabajos en forma de hilo (`titulo`, `estado`, `agente`, `mensajes` derivados de inicio/fin/avisos) para las pestañas del cliente |
| `noticias[]` | Teletipo del día: inicios, fines, causas y avisos |
| `linea_tiempo[]` | Tramos del día por agente (`tramos` con `inicio_pct`/`ancho_pct`, `marcas`) |
| `limites` | `mesa.json` → `limites` (no es cuota del proveedor) |
| `pendientes` | `[]` (no hay mensajería en la ligera) |
| `avisos[]` | Problemas de lectura (`fuente`, `mensaje`) |

Estados del agente: `Trabajando` (candado retenido + `ejecutando`), `Preparando encargo`
(candado sin resultado), `Libre` (último `hecho`), `Libre · último trabajo falló`
(`fallo`, con causa), `Interrumpido` (`ejecutando` sin candado; solo se muestra, no se
repara), `Sin trabajos`. Claude aparece como «actividad no registrada»: la ligera solo
delega a codex y agy.

## Reglas

- **Solo lectura.** No lanza agentes, no aprueba nada, no repara estados, no escribe en
  `datos\` ni en ningún repo. No ejecuta `cuadrilla.ps1` (que sí puede escribir).
- **Solo loopback.** `HttpListener` en `127.0.0.1`; lista cerrada de rutas, solo GET.
- **Sin secretos.** Todo texto del `resultado.json` (escrito por un CLI, no confiable) pasa
  por `Mesa-Ocultar`, las exclusiones y un corte de longitud antes de salir; `agente` y
  `estado` solo del catálogo; `limites` se proyecta a tres números; el `ultima` solo admite
  identificadores de evento. Nunca se sirven logs ni `datos\` completos.
- **Sin rebinding.** Solo se sirve a `Host` `127.0.0.1`/`localhost` con el puerto. Se
  rechazan puntos de reanálisis dentro de `trabajos\` y hay topes de lectura (300 carpetas,
  64 KiB de log, 8 KiB de encargo).
- Los tokens son los registrados por la Cuadrilla en cada `resultado.json`, no el consumo
  de la cuenta; la cuota real se mira con `cuadrilla.ps1 cuota`.
