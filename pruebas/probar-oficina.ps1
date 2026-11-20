# Oficina Estrella con datos sintéticos (MESA_DATOS en %TEMP%): adaptador de estado y humo HTTP. No gasta cuota ni toca datos\.
param([switch]$Conservar)
$ErrorActionPreference = 'Stop'
$base = Split-Path -Parent $PSScriptRoot
$raiz = Join-Path $env:TEMP ('mesa-oficina-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
$datos = Join-Path $raiz 'datos'
$utf8 = New-Object Text.UTF8Encoding $false
$guardado = @{}
foreach ($clave in @('MESA_DATOS', 'MESA_TRABAJO', 'MESA_CONFIG')) { $guardado[$clave] = [Environment]::GetEnvironmentVariable($clave, 'Process') }
$script:fallos = 0
function Caso($nombre, $esperado, $obtenido, [bool]$ok) {
  if (-not $ok) { $script:fallos++ }
  Write-Host ("[{0}] {1}`n      esperado: {2}`n      obtenido: {3}" -f $(if ($ok) { 'OK' } else { 'FALLO' }), $nombre, $esperado, $obtenido)
}
function Trabajo($id, $agente, $tarea, $estado, $inicio, $fin, $extra = @{}) {
  $carp = Join-Path $datos "trabajos\$id"; New-Item -ItemType Directory -Force $carp | Out-Null
  $r = [ordered]@{ id = $id; agente = $agente; tarea = $tarea; modelo = 'modelo-falso'; esfuerzo = 'low'; dir = $raiz
    worktree = $null; rama = $null; lectura = $true; encargo = ''; encargo_hash = 'x'; estado = $estado
    inicio = $inicio; fin = $fin; salida = 0; causa = $null; hasta = $null; lanzador = $null; cli = $null
    tokens = @{ entrada = 100; total = 150; salida = 50 }; avisos = @(); cambios = $null; respuesta = 'ok'; cpu_lanzador_s = 1 }
  foreach ($k in $extra.Keys) { $r[$k] = $extra[$k] }
  [IO.File]::WriteAllText((Join-Path $carp 'resultado.json'), ($r | ConvertTo-Json -Depth 8), $utf8)
  [IO.File]::WriteAllText((Join-Path $carp 'encargo.md'), "# $tarea`n`nObjetivo de prueba.", $utf8)
  $carp
}
$puerto = 18765
$servidor = $null

try {
  New-Item -ItemType Directory -Force (Join-Path $datos 'trabajos'), (Join-Path $raiz 'oficina'), (Join-Path $raiz 'herramientas') | Out-Null
  Copy-Item -LiteralPath (Join-Path $base 'herramientas\comun.ps1') -Destination (Join-Path $raiz 'herramientas')
  foreach ($a in @('estado.ps1', 'servidor.ps1')) { Copy-Item -LiteralPath (Join-Path $base "oficina\$a") -Destination (Join-Path $raiz 'oficina') }
  foreach ($a in @('index.html', 'oficina.js', 'oficina.css', 'arte-v1.js')) { Copy-Item -LiteralPath (Join-Path $base "oficina\$a") -Destination (Join-Path $raiz 'oficina') }
  [IO.File]::WriteAllText((Join-Path $datos 'mesa.json'), '{"modelos":{"codex":["modelo-falso"],"agy":["modelo-falso"]},"limites":{"encargo_min":5,"inactivo_min":30,"max_por_agente":3}}', $utf8)
  # Canario genérico: las zonas excluidas reales nunca se nombran, ni siquiera en pruebas.
  [IO.File]::WriteAllText((Join-Path $datos 'excluidos.txt'), "ZONA-PROHIBIDA`r`n", $utf8)
  $env:MESA_DATOS = $datos; $env:MESA_TRABAJO = $raiz
  Remove-Item Env:\MESA_CONFIG -ErrorAction SilentlyContinue

  . (Join-Path $raiz 'oficina\estado.ps1')

  # --- Vacío: sin trabajos, agentes en reposo, colecciones vacías ---
  $e = Obtener-OficinaEstado
  Caso 'vacío: tres agentes' 3 $e.agentes.Count ($e.agentes.Count -eq 3)
  Caso 'vacío: sin trabajos ni noticias' '0,0' "$($e.trabajos.Count),$($e.noticias.Count)" ($e.trabajos.Count -eq 0 -and $e.noticias.Count -eq 0)
  $cod = $e.agentes | Where-Object { $_.id -eq 'codex' }
  Caso 'vacío: codex apagado' 'apagado' $cod.estado ($cod.estado -eq 'apagado')
  Caso 'vacío: límites de mesa.json' 5 $e.limites.encargo_min ($e.limites.encargo_min -eq 5)

  # --- Hecho hoy con tokens ---
  $hoy = Get-Date
  $ini1 = $hoy.AddHours(-2); if ($ini1.Date -ne $hoy.Date) { $ini1 = $hoy.Date.AddMinutes(1) }
  Trabajo 'codex-t1-20260101-100000' 'codex' 'tarea-uno' 'hecho' $ini1.ToString('o') $hoy.AddHours(-1).ToString('o') | Out-Null
  $e = Obtener-OficinaEstado
  $cod = $e.agentes | Where-Object { $_.id -eq 'codex' }
  Caso 'hecho: codex libre' 'esperando' $cod.estado ($cod.estado -eq 'esperando')
  Caso 'hecho: tokens de hoy' 150 $cod.estadisticas.tokens_hoy ($cod.estadisticas.tokens_hoy -eq 150)
  Caso 'hecho: una hecha hoy' 1 $cod.estadisticas.hechas_hoy ($cod.estadisticas.hechas_hoy -eq 1)
  Caso 'hecho: noticia de fin' 'terminó' ($e.noticias | Select-Object -Last 1).texto (($e.noticias | Select-Object -Last 1).texto -match 'terminó')
  Caso 'hecho: línea de tiempo con tramo' 1 ($e.linea_tiempo | Where-Object { $_.id -eq 'codex' }).tramos.Count ((($e.linea_tiempo | Where-Object { $_.id -eq 'codex' }).tramos.Count) -ge 1)
  Caso 'hecho: hilo con mensajes' $true ((($e.hilos | Select-Object -Last 1).mensajes.Count) -ge 2) (((($e.hilos | Select-Object -Last 1).mensajes.Count)) -ge 2)

  # --- Fallo con causa y aviso de cuota ---
  Trabajo 'agy-t2-20260101-110000' 'agy' 'tarea-dos' 'fallo' $hoy.AddMinutes(-50).ToString('o') $hoy.AddMinutes(-40).ToString('o') @{ causa = 'sin-cuota'; hasta = $hoy.AddHours(3).ToString('o'); avisos = @('reintento agotado') } | Out-Null
  $e = Obtener-OficinaEstado
  $agy = $e.agentes | Where-Object { $_.id -eq 'agy' }
  Caso 'fallo: agy en error' 'error' $agy.estado ($agy.estado -eq 'error')
  Caso 'fallo: vuelve con la hora' $true ($null -ne $agy.vuelve) ($null -ne $agy.vuelve)
  Caso 'fallo: texto con causa' 'sin-cuota' $agy.estado_texto ($agy.estado_texto -match 'sin-cuota')

  # --- Candado retenido + ejecutando: trabajando ---
  $candado = [IO.File]::Open((Join-Path $datos 'trabajos\codex.lock'), 'OpenOrCreate', 'ReadWrite', 'None')
  try {
    Trabajo 'codex-t3-20260101-120000' 'codex' 'tarea-tres' 'ejecutando' $hoy.AddMinutes(-5).ToString('o') $null | Out-Null
    $e = Obtener-OficinaEstado
    $cod = $e.agentes | Where-Object { $_.id -eq 'codex' }
    Caso 'candado: codex escribiendo' 'escribiendo' $cod.estado ($cod.estado -eq 'escribiendo')
    Caso 'candado: online' $true $cod.online ($cod.online -eq $true)
    Caso 'candado: tarea visible' 'tarea-tres' $cod.tarea ($cod.tarea -eq 'tarea-tres')
  } finally { $candado.Dispose() }

  # --- Candado sin resultado: preparando ---
  $candado = [IO.File]::Open((Join-Path $datos 'trabajos\agy.lock'), 'OpenOrCreate', 'ReadWrite', 'None')
  try {
    $e = Obtener-OficinaEstado
    $agy = $e.agentes | Where-Object { $_.id -eq 'agy' }
    Caso 'sin resultado: preparando' 'Preparando encargo' $agy.estado_texto ($agy.estado_texto -eq 'Preparando encargo')
  } finally { $candado.Dispose() }

  # --- Ejecutando sin candado: interrumpido, no se repara ---
  $e = Obtener-OficinaEstado
  $cod = $e.agentes | Where-Object { $_.id -eq 'codex' }
  Caso 'colgado: interrumpido' 'Interrumpido' $cod.estado_texto ($cod.estado_texto -eq 'Interrumpido')
  $r3 = Oficina-LeerJson (Join-Path $datos 'trabajos\codex-t3-20260101-120000\resultado.json')
  Caso 'colgado: resultado intacto' 'ejecutando' $r3.estado ($r3.estado -eq 'ejecutando')

  # --- JSON inválido: se salta sin romper ---
  $mal = Join-Path $datos 'trabajos\codex-malo'; New-Item -ItemType Directory -Force $mal | Out-Null
  [IO.File]::WriteAllText((Join-Path $mal 'resultado.json'), '{no es json', $utf8)
  $e = Obtener-OficinaEstado
  Caso 'JSON dañado: estado sigue armado' 3 $e.agentes.Count ($e.agentes.Count -eq 3)

  # --- Campos maliciosos: secretos y estados raros no salen al JSON ---
  Trabajo 'codex-mal-20260101-130000' 'codex' 'sk-live123456789 ZONA-PROHIBIDA-x' 'hecho' $hoy.AddMinutes(-30).ToString('o') $hoy.AddMinutes(-25).ToString('o') @{ causa = '</span><h1>falso</h1>'; modelo = 'x'; avisos = @('Bearer tokensecreto123') } | Out-Null
  $e = Obtener-OficinaEstado
  $json = $e | ConvertTo-Json -Depth 12 -Compress
  Caso 'saneado: sin secreto en el JSON' $false ($json -match 'sk-live123456789') ($json -notmatch 'sk-live123456789')
  Caso 'saneado: sin ruta excluida' $false ($json -match 'ZONA-PROHIBIDA-x') ($json -notmatch 'ZONA-PROHIBIDA-x')
  Caso 'saneado: aviso ocultado' $false ($json -match 'tokensecreto123') ($json -notmatch 'tokensecreto123')
  Trabajo 'mallory-t9-20260101-140000' 'mallory' 'intruso' 'hecho' $hoy.ToString('o') $hoy.ToString('o') | Out-Null
  $e = Obtener-OficinaEstado
  Caso 'saneado: agente intruso no sale' 0 (($e.trabajos | Where-Object { $_.agente -eq 'mallory' }).Count) (($e.trabajos | Where-Object { $_.agente -eq 'mallory' }).Count -eq 0)

  # --- Solo lectura: nada escrito en datos ---
  $antes = Get-ChildItem -Recurse -File $datos | ForEach-Object { "$($_.FullName)|$($_.Length)|$($_.LastWriteTimeUtc.Ticks)" } | Sort-Object
  [void](Obtener-OficinaEstado)
  $despues = Get-ChildItem -Recurse -File $datos | ForEach-Object { "$($_.FullName)|$($_.Length)|$($_.LastWriteTimeUtc.Ticks)" } | Sort-Object
  Caso 'solo lectura: datos intactos' $antes.Count $despues.Count ((Compare-Object $antes $despues) -eq $null)

  # --- Humo HTTP: servidor en puerto de pruebas, GETs, rechazos y cierre limpio ---
  $servidor = Start-Process powershell.exe -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File',"`"$raiz\oficina\servidor.ps1`"",'-Puerto',"$puerto" -WindowStyle Hidden -PassThru
  $fin = (Get-Date).AddSeconds(20)
  do { Start-Sleep -Milliseconds 300; $ok = $false; try { $null = Invoke-WebRequest -Uri "http://127.0.0.1:$puerto/api/ping" -UseBasicParsing -TimeoutSec 2; $ok = $true } catch {} } until ($ok -or (Get-Date) -ge $fin -or $servidor.HasExited)
  Caso 'humo: servidor responde ping' $true $ok $ok
  if ($ok) {
    $est = Invoke-RestMethod -Uri "http://127.0.0.1:$puerto/api/estado" -TimeoutSec 10
    Caso 'humo: estado JSON' 'oficina-1' $est.version ($est.version -eq 'oficina-1')
    $idx = Invoke-WebRequest -Uri "http://127.0.0.1:$puerto/" -UseBasicParsing -TimeoutSec 5
    Caso 'humo: index.html servido' 200 $idx.StatusCode ($idx.StatusCode -eq 200 -and $idx.Content -match 'Oficina')
    $js = Invoke-WebRequest -Uri "http://127.0.0.1:$puerto/oficina.js" -UseBasicParsing -TimeoutSec 5
    Caso 'humo: oficina.js servido' 200 $js.StatusCode ($js.StatusCode -eq 200)
    try { Invoke-WebRequest -Uri "http://127.0.0.1:$puerto/../comun.ps1" -UseBasicParsing -TimeoutSec 5; Caso 'humo: fuga de archivos' 404 200 $false }
    catch { Caso 'humo: fuga de archivos' '404 o 400' $_.Exception.Response.StatusCode.value__ ($_.Exception.Response.StatusCode.value__ -in @(400, 404)) }
    try { Invoke-WebRequest -Uri "http://127.0.0.1:$puerto/api/estado" -Method Post -UseBasicParsing -TimeoutSec 5; Caso 'humo: POST rechazado' 405 200 $false }
    catch { Caso 'humo: POST rechazado' 405 $_.Exception.Response.StatusCode.value__ ($_.Exception.Response.StatusCode.value__ -eq 405) }
    try { Invoke-WebRequest -Uri "http://127.0.0.1:$puerto/api/estado" -Headers @{ Host = "malicioso.example:$puerto" } -UseBasicParsing -TimeoutSec 5; Caso 'humo: Host extraño' 403 200 $false }
    catch { Caso 'humo: Host extraño' 403 $_.Exception.Response.StatusCode.value__ ($_.Exception.Response.StatusCode.value__ -eq 403) }
  }
} finally {
  if ($servidor -and -not $servidor.HasExited) { Stop-Process -Id $servidor.Id -Force -ErrorAction SilentlyContinue; $servidor.WaitForExit(5000) | Out-Null }
  foreach ($k in $guardado.Keys) { if ($null -eq $guardado[$k]) { Remove-Item "Env:\$k" -ErrorAction SilentlyContinue } else { [Environment]::SetEnvironmentVariable($k, $guardado[$k], 'Process') } }
  if (-not $Conservar) { Remove-Item -Recurse -Force $raiz -ErrorAction SilentlyContinue }
}
if ($script:fallos) { Write-Host "`nFallaron $script:fallos pruebas de la oficina."; exit 1 }
Write-Host "`nTodas las pruebas de la oficina pasaron."
