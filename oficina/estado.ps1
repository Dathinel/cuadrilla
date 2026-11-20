# Adaptador de estado de la Oficina: lee datos\ (trabajos, candados, mesa.json) y devuelve el JSON de /api/estado.
# Solo lectura: no ejecuta cuadrilla.ps1 (que puede marcar interrumpidos o lanzar procesos) ni escribe nada.
. (Join-Path $PSScriptRoot '..\herramientas\comun.ps1')

# Lee un JSON que otro proceso puede estar reemplazando: compartido y con un reintento breve.
function Oficina-LeerJson($ruta) {
  if (-not (Test-Path -LiteralPath $ruta)) { return $null }
  foreach ($intento in 1..3) {
    $fs = $null
    try {
      $fs = [IO.File]::Open($ruta, 'Open', 'Read', 'ReadWrite, Delete')
      $sr = New-Object IO.StreamReader($fs, [Text.Encoding]::UTF8)
      $raw = $sr.ReadToEnd(); $sr.Close(); $fs.Close(); $fs = $null
      try { return ($raw | ConvertFrom-Json -ErrorAction Stop) } catch { return $null }
    } catch {
      if ($fs) { try { $fs.Close() } catch {}; $fs = $null }
      Start-Sleep -Milliseconds 60
    }
  }
  return $null
}

# El candado existe siempre tras el primer uso: solo cuenta si el lanzador lo retiene con exclusividad.
# Desde el 16-nov cada CLI tiene varios puestos (<agente>.<n>.lock): basta con que uno esté tomado.
function Oficina-CandadoRetenido($agente) {
  foreach ($f in @(Get-ChildItem -LiteralPath (Join-Path $Global:Mesa_Raiz 'trabajos') -Filter "$agente.*lock" -File -ErrorAction SilentlyContinue)) {
    try {
      $fs = [IO.File]::Open($f.FullName, 'Open', 'ReadWrite', 'None')
      $fs.Close()
    } catch [IO.IOException] { return $true } catch {}
  }
  return $false
}

# Últimos 64 KiB del log del trabajo activo: solo el tipo del último evento completo, nunca el contenido.
function Oficina-UltimaActividad($carpeta) {
  $log = Join-Path $carpeta 'log.jsonl'
  if (-not (Test-Path -LiteralPath $log)) { return $null }
  $fs = $null
  try {
    $fs = [IO.File]::Open($log, 'Open', 'Read', 'ReadWrite, Delete')
    # Solo la cola: 64 KiB bastan para la última actividad y un log enorme no se traga entero.
    # Se tope también por delante: si el archivo crece mientras se lee, no se lee de más.
    $desde = if ($fs.Length -gt 65536) { $fs.Length - 65536 } else { 0 }
    $hasta = $fs.Length
    [void]$fs.Seek($desde, 'Begin')
    $ultima = $null
    $sr = New-Object IO.StreamReader($fs, [Text.Encoding]::UTF8)
    if ($desde -gt 0) { [void]$sr.ReadLine() }
    while ($fs.Position -lt $hasta -and -not $sr.EndOfStream) {
      $linea = $sr.ReadLine()
      if ($linea -and $linea.TrimEnd().EndsWith('}')) { $ultima = $linea }
    }
    $sr.Close(); $fs.Close(); $fs = $null
    if (-not $ultima) { return $null }
    try { $ev = $ultima | ConvertFrom-Json -ErrorAction Stop } catch { return $null }
    $tipo = if ($ev.type) { [string]$ev.type } elseif ($ev.event) { [string]$ev.event } else { $null }
    # Solo identificadores de evento: cualquier otra cosa (texto libre del CLI) no sale.
    if (-not $tipo -or $tipo -notmatch '^[a-zA-Z0-9._:-]{1,40}$') { return $null }
    return $tipo
  } catch {
    if ($fs) { try { $fs.Close() } catch {} }
    return $null
  }
}

# Resumen del encargo del propio trabajo (encargo.md copiado en su carpeta), saneado y acotado.
function Oficina-ResumenEncargo($carpeta) {
  $md = Join-Path $carpeta 'encargo.md'
  if (-not (Test-Path -LiteralPath $md)) { return $null }
  $fs = $null
  try {
    $fs = [IO.File]::Open($md, 'Open', 'Read', 'ReadWrite, Delete')
    $sr = New-Object IO.StreamReader($fs, [Text.Encoding]::UTF8)
    $lineas = @(); $leidos = 0
    while (-not $sr.EndOfStream -and $lineas.Count -lt 60 -and $leidos -lt 8192) {
      $linea = $sr.ReadLine(); if ($null -eq $linea) { break }
      $leidos += $linea.Length
      if ($linea.Length -gt 500) { $linea = $linea.Substring(0, 500) }
      $lineas += $linea
    }
    $sr.Close(); $fs.Close(); $fs = $null
    $titulo = ($lineas | Where-Object { $_ -match '^\s*#\s*(.+)$' } | Select-Object -First 1)
    if (-not $titulo) { $titulo = ($lineas | Where-Object { $_.Trim() } | Select-Object -First 1) }
    if (-not $titulo) { return $null }
    $limpio = (Mesa-Ocultar ($titulo -replace '^\s*#+\s*', '')).Trim()
    if ($limpio.Length -gt 120) { $limpio = $limpio.Substring(0, 119) + '…' }
    if ($limpio -match $Global:Mesa_Excluidos) { return $null }
    return $limpio
  } catch {
    if ($fs) { try { $fs.Close() } catch {} }
    return $null
  }
}

function Obtener-OficinaEstado {
  $ahora = Get-Date
  $hoy = $ahora.Date
  $avisos = @()

  # Texto de un JSON escrito por un CLI (no confiable): se sanea y se acota antes de publicar nada.
  function Oficina-Texto($v, [int]$max = 160) {
    if ($null -eq $v -or $v -isnot [string]) { return $null }
    $s = (Mesa-Ocultar $v).Trim()
    if ($s.Length -gt $max) { $s = $s.Substring(0, $max - 1) + '…' }
    if ($s -match $Global:Mesa_Excluidos) { return $null }
    if (-not $s) { return $null }
    return $s
  }

  function Oficina-Numero($v) {
    try { $n = [double]$v; if ([double]::IsNaN($n) -or [double]::IsInfinity($n) -or $n -lt 0 -or $n -gt 1e9) { return $null }; return $n } catch { return $null }
  }

  $trabajos = @()
  $raizTrabajos = Join-Path $Global:Mesa_Raiz 'trabajos'
  if (Test-Path -LiteralPath $raizTrabajos) {
    $raizResuelta = (Resolve-Path -LiteralPath $raizTrabajos).ProviderPath
    # Las carpetas más nuevas primero y con tope: un directorio abarrotado no debe tumbar el panel.
    $carpetas = @(Get-ChildItem -LiteralPath $raizTrabajos -Directory -ErrorAction SilentlyContinue |
      Where-Object { -not ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) } |
      Sort-Object Name -Descending | Select-Object -First 300)
    foreach ($carpeta in $carpetas) {
      # Un punto de reanálisis dentro de la carpeta tampoco debe sacar la lectura de datos\.
      try { if (-not $carpeta.FullName.StartsWith($raizResuelta, 'OrdinalIgnoreCase')) { continue } } catch { continue }
      $r = $null
      try { $r = Oficina-LeerJson (Join-Path $carpeta.FullName 'resultado.json') } catch { $avisos += @{ fuente = $carpeta.Name; mensaje = 'resultado.json ilegible' }; continue }
      if (-not $r -or -not $r.agente -or $r.agente -isnot [string] -or $r.agente -notmatch '^(codex|agy|claude)$') { continue }
      $inicio = $null; $fin = $null
      # En Windows PowerShell 5.1 ConvertFrom-Json ya entrega las fechas ISO como [datetime].
      try { if ($r.inicio -is [string]) { $inicio = [datetime]::Parse($r.inicio) } elseif ($r.inicio -is [datetime]) { $inicio = $r.inicio } } catch {}
      try { if ($r.fin -is [string]) { $fin = [datetime]::Parse($r.fin) } elseif ($r.fin -is [datetime]) { $fin = $r.fin } } catch {}
      $tokens = $null
      try { if ($r.tokens -and $null -ne $r.tokens.total) { $tokens = [long]$r.tokens.total; if ($tokens -lt 0 -or $tokens -gt 1e12) { $tokens = $null } } } catch { $tokens = $null }
      $estado = if ([string]$r.estado -in @('ejecutando', 'hecho', 'fallo', 'interrumpido', 'no-lanzado')) { [string]$r.estado } else { 'desconocido' }
      $trabajos += [pscustomobject]@{
        id = Oficina-Texto $r.id 80; agente = $r.agente; tarea = Oficina-Texto $r.tarea 80
        modelo = Oficina-Texto $r.modelo 60; esfuerzo = Oficina-Texto $r.esfuerzo 20; estado = $estado
        inicio = $inicio; fin = $fin
        causa = Oficina-Texto $r.causa 80; hasta = Oficina-Texto $r.hasta 40
        lectura = ($r.lectura -eq $true); worktree = [bool]($r.worktree)
        tokens = $tokens
        avisos = @(@($r.avisos) | Select-Object -First 5 | ForEach-Object { Oficina-Texto $_ 160 })
        resumen = Oficina-ResumenEncargo $carpeta.FullName
        carpeta = $carpeta.FullName
        log_mod = $carpeta.LastWriteTime
      }
    }
  }
  $trabajos = @($trabajos | Sort-Object { if ($_.inicio) { $_.inicio } else { [datetime]::MinValue } })

  $mesaCfg = Oficina-LeerJson (Mesa-ConfigPath)
  # Solo las tres claves que la ficha muestra, como números: mesa.json no se publica entero.
  $limites = $null
  if ($mesaCfg -and $mesaCfg.limites) {
    $lim = $mesaCfg.limites
    $limites = [ordered]@{
      encargo_min = Oficina-Numero $lim.encargo_min
      inactivo_min = Oficina-Numero $lim.inactivo_min
      max_por_agente = Oficina-Numero $lim.max_por_agente
    }
  }

  # Catálogo fijo de agentes; la apariencia es configuración del panel, no dato de sesión.
  $personajes = @{
    claude = @{ ropa = 'clasica'; accesorio = 'gafas'; color = '#dba08b'; velocidad = 1 }
    codex  = @{ ropa = 'tecnica'; accesorio = 'esfuerzo'; color = '#88c3dd'; velocidad = 1 }
    agy    = @{ ropa = 'sudadera'; accesorio = $null; color = '#89c3a7'; velocidad = 1 }
  }

  $agentes = @()
  foreach ($id in @('claude', 'codex', 'agy')) {
    $del = @($trabajos | Where-Object { $_.agente -eq $id })
    $ultimo = $del | Select-Object -Last 1
    $activo = @($del | Where-Object { $_.estado -eq 'ejecutando' } | Select-Object -Last 1)[0]
    $retenido = if ($id -eq 'claude') { $false } else { Oficina-CandadoRetenido $id }

    $tokensHoy = $null
    $finHoy = @($del | Where-Object { $_.fin -and $_.fin.Date -eq $hoy })
    if ($finHoy.Count -gt 0) {
      $suma = 0L; $falta = $false
      foreach ($t in $finHoy) { if ($null -ne $t.tokens) { $suma += $t.tokens } else { $falta = $true } }
      $tokensHoy = @{ total = $suma; parcial = $falta }
    }

    # Tokens reales por día, últimos 7 (el cliente los pinta en millones, el último es hoy).
    $hist = @(); $suma7 = 0L
    foreach ($d in 6..0) {
      $dia = $hoy.AddDays(-$d)
      $sumDia = 0L
      foreach ($t in @($del | Where-Object { $_.fin -and $_.fin.Date -eq $dia -and $null -ne $_.tokens })) { $sumDia += $t.tokens }
      $suma7 += $sumDia
      $hist += [Math]::Round($sumDia / 1000000.0, 1)
    }

    $estado = 'apagado'; $texto = 'Sin trabajos'; $tarea = ''
    $ultima = $null
    if ($id -eq 'claude') {
      $texto = 'Actividad no registrada (dirige fuera de la Cuadrilla)'
    } elseif ($activo -and $retenido) {
      $estado = 'escribiendo'; $texto = 'Trabajando'
      $tarea = if ($activo.resumen) { $activo.resumen } else { $activo.tarea }
      $ultima = Oficina-UltimaActividad $activo.carpeta
    } elseif ($retenido) {
      $estado = 'esperando'; $texto = 'Preparando encargo'; $tarea = 'Encargo nuevo en preparación'
    } elseif ($activo) {
      # ejecutando sin candado: el lanzador murió; solo se muestra, no se repara.
      $estado = 'apagado'; $texto = 'Interrumpido'; $tarea = "$($activo.tarea) (sin proceso)"
    } elseif ($ultimo) {
      $estado = if ($ultimo.estado -eq 'hecho') { 'esperando' } else { 'esperando' }
      $texto = switch ($ultimo.estado) {
        'hecho' { 'Libre' }
        'fallo' { "Libre · último trabajo falló$(if ($ultimo.causa) { " ($($ultimo.causa))" })" }
        'interrumpido' { 'Libre · último trabajo interrumpido' }
        default { "Libre · último: $($ultimo.estado)" }
      }
      if ($ultimo.estado -eq 'fallo') { $estado = 'error' }
      $tarea = ''
    }

    $agentes += [ordered]@{
      id = $id
      nombre = switch ($id) { 'claude' { 'Claude' } 'codex' { 'ChatGPT' } 'agy' { 'Gemini' } }
      estado = $estado
      estado_texto = $texto
      online = ($estado -eq 'escribiendo')
      tarea = $tarea
      ultima = $ultima
      modelo = if ($activo) { $activo.modelo } elseif ($ultimo) { $ultimo.modelo } elseif ($mesaCfg -and $mesaCfg.modelos -and $mesaCfg.modelos.$id) { [string]$mesaCfg.modelos.$id[0] } else { $null }
      esfuerzo = if ($activo) { $activo.esfuerzo } else { $null }
      personaje = $personajes[$id]
      energia = $null
      tokens_7d_hist = $hist
      estadisticas = @{
        tokens_hoy = if ($tokensHoy) { $tokensHoy.total } else { $null }
        tokens_parcial = if ($tokensHoy) { [bool]$tokensHoy.parcial } else { $false }
        tokens_7d = $suma7
        hechas_hoy = @($finHoy | Where-Object { $_.estado -eq 'hecho' }).Count
        fallidas_hoy = @($finHoy | Where-Object { $_.estado -eq 'fallo' }).Count
      }
      vuelve = if ($ultimo -and $ultimo.causa -eq 'sin-cuota') { $ultimo.hasta } else { $null }
      candado = if ($id -eq 'claude') { $null } else { $retenido }
    }
  }

  # Trabajos como hilos para el cliente; el «chat» se alimenta de eventos reales del trabajo.
  $hilos = @($trabajos | Select-Object -Last 20 | ForEach-Object {
    $t = $_
    $mensajes = @()
    if ($t.inicio) { $mensajes += @{ autor = 'mesa'; para = $t.agente; fecha = $t.inicio.ToString('o'); texto = "Encargo «$($t.tarea)»$(if ($t.lectura) { ' (solo lectura)' })$(if ($t.worktree) { ' en worktree' })." } }
    foreach ($a in $t.avisos) { $mensajes += @{ autor = $t.agente; para = 'mesa'; fecha = if ($t.fin) { $t.fin.ToString('o') } else { $null }; texto = "Aviso: $(Mesa-Ocultar $a)" } }
    if ($t.fin) {
      $como = if ($t.estado -eq 'hecho') { 'terminó' } elseif ($t.estado -eq 'fallo') { "falló$(if ($t.causa) { ": $($t.causa)" })" } else { "quedó $($t.estado)" }
      $mensajes += @{ autor = $t.agente; para = 'mesa'; fecha = $t.fin.ToString('o'); texto = "$como$(if ($t.tokens) { " · $($t.tokens) tokens" })$(if ($t.causa -eq 'sin-cuota' -and $t.hasta) { " · cuota hasta $($t.hasta)" })" }
    }
    [ordered]@{
      id = $t.id; titulo = if ($t.resumen) { $t.resumen } else { $t.tarea }
      estado = $t.estado; agente = $t.agente; mensajes = $mensajes
      actualizado = if ($t.fin) { $t.fin.ToString('o') } elseif ($t.inicio) { $t.inicio.ToString('o') } else { $null }
    }
  })

  $listaTrabajos = @($trabajos | Select-Object -Last 40 | ForEach-Object {
    [ordered]@{
      id = $_.id; agente = $_.agente; tarea = $_.tarea; modelo = $_.modelo
      estado = $_.estado; causa = $_.causa
      inicio = if ($_.inicio) { $_.inicio.ToString('o') } else { $null }
      fin = if ($_.fin) { $_.fin.ToString('o') } else { $null }
      lectura = $_.lectura; worktree = $_.worktree; tokens = $_.tokens
      avisos = @($_.avisos | ForEach-Object { Mesa-Ocultar $_ }); resumen = $_.resumen
    }
  })

  # Noticias del día: inicio, fin, causa y avisos de los trabajos de hoy (ordenadas por la fecha real).
  $noticias = @()
  foreach ($t in @($trabajos | Where-Object { ($_.inicio -and $_.inicio.Date -eq $hoy) -or ($_.fin -and $_.fin.Date -eq $hoy) })) {
    if ($t.inicio -and $t.inicio.Date -eq $hoy) { $noticias += [pscustomobject]@{ cuando = $t.inicio; hora = $t.inicio.ToString('HH:mm'); texto = "$($t.agente) empezó «$($t.tarea)»" } }
    if ($t.fin -and $t.fin.Date -eq $hoy) {
      $como = if ($t.estado -eq 'hecho') { 'terminó' } elseif ($t.estado -eq 'fallo') { "falló$(if ($t.causa) { ": $($t.causa)" })" } else { "quedó $($t.estado)" }
      $noticias += [pscustomobject]@{ cuando = $t.fin; hora = $t.fin.ToString('HH:mm'); texto = "$($t.agente) $como «$($t.tarea)»" }
    }
    foreach ($a in $t.avisos) { if ($t.fin -and $t.fin.Date -eq $hoy) { $noticias += [pscustomobject]@{ cuando = $t.fin; hora = $t.fin.ToString('HH:mm'); texto = "$($t.agente): aviso $(Mesa-Ocultar $a)" } } }
  }
  $noticias = @($noticias | Sort-Object cuando | Select-Object -Last 12 | ForEach-Object { [ordered]@{ hora = $_.hora; texto = $_.texto } })

  # Línea de tiempo: tramos reales del día por agente (el canvas usa inicio_pct/ancho_pct 0-100).
  $diaMinutos = 1440.0
  $linea = @()
  foreach ($id in @('codex', 'agy')) {
    $tramos = @(); $marcas = @()
    foreach ($t in @($trabajos | Where-Object { $_.agente -eq $id -and $_.inicio -and $_.inicio.Date -eq $hoy })) {
      $desde = $t.inicio
      $hasta = if ($t.fin) { $t.fin } elseif ($t.estado -eq 'ejecutando') { $ahora } else { $desde.AddMinutes(1) }
      if ($hasta.Date -gt $hoy) { $hasta = $hoy.AddDays(1) }
      $p0 = [Math]::Max(0, ($desde - $hoy).TotalMinutes) / $diaMinutos * 100
      $p1 = [Math]::Min(100, (($hasta - $hoy).TotalMinutes) / $diaMinutos * 100)
      if ($p1 -le $p0) { $p1 = $p0 + 0.4 }
      $tramos += [ordered]@{ inicio_pct = [Math]::Round($p0, 2); ancho_pct = [Math]::Round($p1 - $p0, 2); inicio = $desde.ToString('HH:mm'); fin = $hasta.ToString('HH:mm') }
      $marcas += [ordered]@{ pct = [Math]::Round($p0, 2); hora = $desde.ToString('HH:mm'); titulo = $t.tarea }
    }
    $linea += [ordered]@{ id = $id; nombre = if ($id -eq 'codex') { 'ChatGPT' } else { 'Gemini' }; color = if ($id -eq 'codex') { '#88c3dd' } else { '#89c3a7' }; tramos = $tramos; marcas = $marcas }
  }

  if (-not (Test-Path -LiteralPath $raizTrabajos)) { $avisos += @{ fuente = 'datos'; mensaje = 'No hay datos de trabajos todavía' } }

  [ordered]@{
    version = 'oficina-1'
    generado_en = $ahora.ToString('o')
    agentes = $agentes
    trabajos = $listaTrabajos
    hilos = $hilos
    noticias = $noticias
    linea_tiempo = $linea
    limites = $limites
    pendientes = @()
    avisos = $avisos
  }
}
