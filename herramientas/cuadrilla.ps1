# Cuadrilla ligera: una orden que lanza un encargo a ChatGPT (CLI codex), Gemini (CLI agy), Devin (CLI devin) o Claude (CLI claude), espera y termina. Sin procesos residentes.
#   cuadrilla.ps1 delegar -A chatgpt|gemini|devin|claude -Encargo <md> -Dir <carpeta> [-Tarea t] [-Modelo m] [-Esfuerzo low|medium|high] [-Nivel bajo|medio|alto] [-Lectura] [-Sandbox [-Red]] [-Minutos n]
#   Varios encargos a la vez por CLI: hasta puestos.<cli> de mesa.json (por defecto codex 3, agy 4, devin 4, claude 2).
#   -Nivel (o una línea «Nivel: alto» en el .md) elige modelo y esfuerzo según niveles.<nivel>.<cli> de mesa.json; -Modelo y -Esfuerzo mandan.
#   Cada encargo deja una línea en datos\trabajos\uso.jsonl (modelo, duración, tokens, coste aproximado y cuota antes y después).
#   cuadrilla.ps1 estado [<id>]        cuadrilla.ps1 cortar <id>        cuadrilla.ps1 cuota
# Salidas de delegar: 0 hecho, 2 hecho con aviso, 1 fallo, 124 tiempo o colgado, 3 no lanzado.
param(
  [Parameter(Position = 0, Mandatory = $true)][ValidateSet('delegar', 'estado', 'cortar', 'cuota')][string]$Comando,
  [Parameter(Position = 1)][string]$Id,
  [ValidateSet('chatgpt', 'gemini', 'codex', 'agy', 'devin', 'claude')][string]$A,
  [string]$Encargo, [string]$Dir, [string]$Tarea, [string]$Modelo,
  [ValidateSet('low', 'medium', 'high')][string]$Esfuerzo = 'medium',
  [ValidateSet('bajo', 'medio', 'alto')][string]$Nivel,
  [switch]$Lectura, [switch]$Sandbox, [switch]$Red, [double]$Minutos = 0
)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\comun.ps1"
$trabajos = Join-Path $Global:Mesa_Raiz 'trabajos'
New-Item -ItemType Directory -Force $trabajos | Out-Null
$cfg = Mesa-LeerJson (Mesa-ConfigPath)
# Las secciones que falten en mesa.json (puestos, niveles, pago, precios, limite_uso) salen del ejemplo: un mesa.json anterior sigue valiendo.
$ejemplo = Mesa-LeerJson (Join-Path $Global:Mesa_Base 'datos\mesa.ejemplo.json')
if ($cfg -and $ejemplo) { foreach ($k in $ejemplo.PSObject.Properties.Name) { if ($null -eq $cfg.$k) { $cfg | Add-Member -NotePropertyName $k -NotePropertyValue $ejemplo.$k } } }
$utf8 = New-Object Text.UTF8Encoding $false
# ChatGPT y Gemini son los nombres a la vista; por dentro siguen codex y agy (binarios, ramas, candados e historial).
$nombres = @{ codex = 'ChatGPT'; agy = 'Gemini'; devin = 'Devin'; claude = 'Claude' }
if ($A -eq 'chatgpt') { $A = 'codex' } elseif ($A -eq 'gemini') { $A = 'agy' }

function Ruta-Cli($a) {
  # Sin esto, buscar un CLI que no está recorre todos los módulos instalados (7 s el 16-nov).
  $PSModuleAutoLoadingPreference = 'None'
  $c = Get-Command $a -CommandType Application, ExternalScript -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($c) { return $c.Source }
  $exe = switch ($a) { 'agy' { Join-Path $env:LOCALAPPDATA 'agy\bin\agy.exe' } 'devin' { Join-Path $env:LOCALAPPDATA 'devin\cli\bin\devin.exe' } }
  if ($exe -and (Test-Path -LiteralPath $exe)) { return $exe }
  # claude CLI nativo: instalación por versión en Roaming\Claude\claude-code\<versión>\<hash>\claude.exe; se coge la más nueva.
  if ($a -eq 'claude') {
    $base = Join-Path $env:APPDATA 'Claude\claude-code'
    $exe = @(Get-ChildItem -LiteralPath $base -Directory -ErrorAction SilentlyContinue | ForEach-Object {
        Get-ChildItem -LiteralPath $_.FullName -Directory -ErrorAction SilentlyContinue |
          ForEach-Object { Join-Path $_.FullName 'claude.exe' } | Where-Object { Test-Path -LiteralPath $_ }
      } | Sort-Object -Descending | Select-Object -First 1)
    if ($exe.Count -gt 0) { return $exe[0] }
  }
}
function Resultados {
  @(Get-ChildItem -LiteralPath $trabajos -Directory -ErrorAction SilentlyContinue | ForEach-Object {
    $f = Join-Path $_.FullName 'resultado.json'
    if (Test-Path -LiteralPath $f) { try { Mesa-LeerJson $f } catch {} }
  } | Sort-Object inicio)
}
# Un ejecutando cuyo lanzador ya no vive (apagón, app cerrada) pasa a interrumpido; la misma orden lo retoma.
function Refrescar-Interrumpidos {
  foreach ($r in Resultados) {
    if ($r.estado -eq 'ejecutando' -and -not (Mesa-ProcesoVivo $r.lanzador.pid $r.lanzador.inicio $r.lanzador.nombre)) {
      # Se relee tras confirmar la muerte: el lanzador pudo escribir «hecho» y salir entre la lectura y la comprobación.
      $f = Join-Path $trabajos "$($r.id)\resultado.json"; $r = Mesa-LeerJson $f
      if ($r.estado -eq 'ejecutando') { $r.estado = 'interrumpido'; $r.fin = Mesa-IsoNow; Mesa-EscribirJson $f $r }
    }
  }
}
# Continue solo aquí: en PowerShell 5.1 el stderr de git, aunque vaya a $null, se volvería una excepción con Stop.
function Orden-Git($d) { $ErrorActionPreference = 'Continue'; $s = & git -C $d @args 2>$null; if ($LASTEXITCODE -eq 0) { @($s) -join "`n" } }
function Raiz-Repo($d) { $r = Orden-Git $d rev-parse --show-toplevel; if ($r) { [IO.Path]::GetFullPath($r) } }
function Hora($iso) { $d = [datetime]::Parse($iso); $d.ToString($(if ($d.Date -eq (Get-Date).Date) { 'HH:mm' } else { 'dd-MM HH:mm' })) }
# Con varios puestos el último lanzado puede seguir vivo: manda el último que terminó hecho o sin cuota (un fallo por otra causa no dice nada de la cuota).
# La cuota de pago de Devin va aparte de la gratuita. Los resultado.json anteriores no traen «pago»: cuentan como gratuitos.
# Gemini reparte la cuota por familia de modelos (tabla de agy /usage: Argon, los demás Gemini y los de terceros): quedarse sin
# Argon no frena a flash. Los demás CLI tienen un solo grupo.
function Grupo-Cuota($a, $modelo) { if ($a -ne 'agy') { '' } elseif ($modelo -match 'argon') { 'argon' } elseif ($modelo -match '^gemini') { 'gemini' } else { 'otros' } }
function Sin-Cuota($a, $todos, [bool]$pago = $false, $modelo = $null) {
  $g = if ($null -ne $modelo) { Grupo-Cuota $a $modelo }
  $u = @($todos | Where-Object { $_.agente -eq $a -and $_.fin -and ($_.estado -eq 'hecho' -or $_.causa -eq 'sin-cuota') -and [bool]$_.pago -eq $pago -and ($null -eq $modelo -or (Grupo-Cuota $a $_.modelo) -eq $g) } | Sort-Object { [datetime]::Parse($_.fin) }) | Select-Object -Last 1
  if ($u -and $u.causa -eq 'sin-cuota' -and $u.hasta -and [datetime]::Parse($u.hasta) -gt (Get-Date)) { $u }
}
function Minutos($iso) { [int]((Get-Date) - [datetime]::Parse($iso)).TotalMinutes }

# Lectura de cuota de un CLI sin gastar: agy da su tabla con «-p /usage»; codex, sus límites de 5 h y semana y los restablecimientos
# que le quedan por «app-server» (account/rateLimits/read); devin no ofrece nada (auth status no trae saldo) y claude tampoco
# (su uso solo se ve en la sesión interactiva). Si falla, $null: nunca frena un encargo.
function Leer-Cuota($a, $archivo) {
  try {
    if ($a -eq 'agy') {
      $r = Invocar-ProcesoMesa -Ejecutable (Ruta-Cli agy) -Argumentos @('-p', '/usage', '--output-format', 'text') -Directorio $trabajos -Log $archivo -Segundos 60
      if ($r.salida -eq 0) { return @([IO.File]::ReadAllLines($archivo, $utf8) | Where-Object { $_ -match '%' } | ForEach-Object { ($_.Trim() -replace '\t', ' | ') }) }
    } elseif ($a -eq 'codex') {
      # La primera línea es de sacrificio: app-server descarta lo primero que recibe por la tubería.
      $pide = "`n" + '{"id":1,"method":"initialize","params":{"clientInfo":{"name":"cuadrilla","title":"cuadrilla","version":"1.0.0"}}}' + "`n" + '{"method":"initialized"}' + "`n" + '{"id":2,"method":"account/rateLimits/read"}' + "`n"
      $null = Invocar-ProcesoMesa -Ejecutable (Ruta-Cli codex) -Argumentos @('app-server') -Entrada $pide -Directorio $trabajos -Log $archivo -Segundos 30 -Hasta '"id":\s*2\b'
      $l = [IO.File]::ReadAllLines($archivo, $utf8) | Where-Object { $_ -match '"rateLimits"' } | Select-Object -Last 1
      if ($l) {
        $j = ($l | ConvertFrom-Json).result; $iso = { param($s) if ($s) { ([DateTimeOffset]::FromUnixTimeSeconds([int64]$s)).LocalDateTime.ToString('yyyy-MM-ddTHH:mm:sszzz') } }
        return [ordered]@{ cinco_h_usado = $j.rateLimits.primary.usedPercent; cinco_h_reinicio = (& $iso $j.rateLimits.primary.resetsAt); semana_usado = $j.rateLimits.secondary.usedPercent; semana_reinicio = (& $iso $j.rateLimits.secondary.resetsAt); restablecimientos = $j.rateLimitResetCredits.availableCount }
      }
    }
  } catch {} finally { Remove-Item -LiteralPath $archivo -ErrorAction SilentlyContinue }
}
# Registro de uso: una línea JSON por encargo terminado en trabajos\uso.jsonl (Mesa-Anotar aguanta varios escritores).
function Uso-Leer {
  $f = Join-Path $trabajos 'uso.jsonl'
  if (-not (Test-Path -LiteralPath $f)) { return @() }
  $fs = [IO.File]::Open($f, 'Open', 'Read', 'ReadWrite'); try { $t = (New-Object IO.StreamReader $fs, $utf8).ReadToEnd() } finally { $fs.Dispose() }
  @($t -split "`r?`n" | Where-Object { $_ } | ForEach-Object { try { $_ | ConvertFrom-Json } catch {} })
}
function Uso-Acumulado($a, $horas, $uso) {
  $desde = (Get-Date).AddHours(-$horas); $m = @($uso | Where-Object { $_.agente -eq $a -and $_.fin -and [datetime]::Parse($_.fin) -ge $desde })
  $suma = { param($c) [double]($m | Measure-Object -Property $c -Sum -ErrorAction SilentlyContinue).Sum }
  @{ encargos = $m.Count; minutos = [int]((& $suma 'segundos') / 60); tokens = [int64](& $suma 'tokens'); usd = [Math]::Round((& $suma 'usd'), 2); pago = @($m | Where-Object pago).Count }
}
function Uso-Linea($a, $uso) {
  $t = foreach ($v in @(5, 'en 5 h'), @(168, 'en 7 d')) { $u = Uso-Acumulado $a $v[0] $uso; "$($v[1]): $($u.encargos) encargos$(if ($u.pago) { " ($($u.pago) de pago)" }), $($u.minutos) min, $($u.tokens) tokens$(if ($u.usd) { ", ~$($u.usd) USD" })" }
  "  uso $($t -join '; ')"
}

switch ($Comando) {
  'estado' {
    Refrescar-Interrumpidos
    $todos = Resultados; $uso = Uso-Leer
    if ($Id) { $r = $todos | Where-Object id -eq $Id; if (-not $r) { throw "No existe el encargo $Id." }; $r | ConvertTo-Json -Depth 6; return }
    foreach ($a in 'codex', 'agy', 'devin', 'claude') {
      if (-not (Ruta-Cli $a)) { "$($nombres[$a]) ($a): no instalado"; continue }
      $vivos = @($todos | Where-Object { $_.agente -eq $a -and $_.estado -eq 'ejecutando' })
      $lista = @($vivos | ForEach-Object {
        $log = Join-Path $trabajos "$($_.id)\log.jsonl"
        $edad = if (Test-Path -LiteralPath $log) { [int]((Get-Date) - (Get-Item -LiteralPath $log).LastWriteTime).TotalMinutes } else { '?' }
        "$($_.id) ($(Minutos $_.inicio) min; log hace $edad min)"
      })
      $linea = "$($nombres[$a]) ($a): $($vivos.Count) de $(Mesa-Puestos $a $cfg) ocupados$(if ($lista.Count) { ': ' + ($lista -join ', ') } else { ' (libre)' })"
      if ($a -eq 'agy') {
        foreach ($g in 'gemini-flash', 'gemini-argon', 'otros') { $sc = Sin-Cuota $a $todos $false $g; if ($sc) { $linea += "; $(Grupo-Cuota $a $g) sin cuota hasta $(Hora $sc.hasta)" } }
      } else {
        $sc = Sin-Cuota $a $todos
        if ($sc) { $linea += "; sin cuota hasta $(Hora $sc.hasta)" }
      }
      $scPago = Sin-Cuota $a $todos $true
      if ($scPago) { $linea += "; de pago sin cuota hasta $(Hora $scPago.hasta)" }
      $linea
      Uso-Linea $a $uso
    }
    foreach ($r in @($todos | Select-Object -Last 10)) {
      "{0}  {1,-13} salida={2} {3} {4}" -f $r.id, $r.estado, $r.salida, $(if ($r.causa) { "causa=$($r.causa)" } else { '' }), $(if ($r.avisos) { "avisos=$(@($r.avisos).Count)" } else { '' })
    }
    $instalada = Join-Path $env:USERPROFILE '.claude\skills\cuadrilla\SKILL.md'
    if (-not (Test-Path -LiteralPath $instalada) -or [IO.File]::ReadAllText($instalada, [Text.Encoding]::UTF8) -ne (Mesa-SkillTexto)) { 'AVISO: la skill instalada no coincide con plantillas\cuadrilla\SKILL.md: ejecuta herramientas\instalar.ps1' }
    return
  }
  'cortar' {
    if (-not $Id) { throw 'Uso: cuadrilla.ps1 cortar <id>' }
    $f = Join-Path $trabajos "$Id\resultado.json"
    $r = Mesa-LeerJson $f
    if (-not $r) { throw "No existe el encargo $Id." }
    if ($r.estado -ne 'ejecutando') { "No se corta nada: $Id está $($r.estado)."; return }
    if (-not (Mesa-ProcesoVivo $r.lanzador.pid $r.lanzador.inicio $r.lanzador.nombre)) { Refrescar-Interrumpidos; "No se corta nada: el lanzador de $Id ya no vive (queda interrumpido)."; return }
    # Matar al lanzador cierra su Job y el Job se lleva el árbol del CLI (KILL_ON_JOB_CLOSE).
    Stop-Process -Id $r.lanzador.pid -Force
    $r.estado = 'interrumpido'; $r.causa = 'cortado'; $r.fin = Mesa-IsoNow; Mesa-EscribirJson $f $r
    "CORTADO $Id"
    return
  }
  'cuota' {
    foreach ($a in 'codex', 'agy', 'devin', 'claude') {
      $u = Resultados | Where-Object { $_.agente -eq $a -and $_.causa -eq 'sin-cuota' } | Select-Object -Last 1
      if ($u) { "$($nombres[$a]) ($a): última señal sin cuota $($u.fin) (hasta $($u.hasta))" } else { "$($nombres[$a]) ($a): sin señal de falta de cuota" }
    }
    $uso = Uso-Leer
    foreach ($a in 'codex', 'agy', 'devin', 'claude') { "$($nombres[$a]) ($a):"; Uso-Linea $a $uso }
    $reg = Join-Path $trabajos 'cuota-codex.txt'
    if (Test-Path -LiteralPath $reg) { 'Señales sin cuota anotadas de ChatGPT (últimas 5):'; Get-Content -LiteralPath $reg -Encoding UTF8 -Tail 5 }
    . "$PSScriptRoot\proceso.ps1"
    # Lectura en vivo (cada una en su archivo temporal: puede haber otros delegar leyendo a la vez). Devin no ofrece ninguna.
    foreach ($a in 'codex', 'agy') {
      if (-not (Ruta-Cli $a)) { "$($a): no instalado"; continue }
      $c = Leer-Cuota $a (Join-Path $trabajos "cuota-$a.$PID.tmp")
      if (-not $c) { "$($a): no se pudo leer la cuota"; continue }
      if ($a -eq 'codex') { "ChatGPT ahora: 5 h usado $($c.cinco_h_usado) % (reinicia $($c.cinco_h_reinicio)); semana usado $($c.semana_usado) % (reinicia $($c.semana_reinicio)); restablecimientos disponibles: $($c.restablecimientos)" }
      else { 'Gemini ahora (lo que queda):'; $c; Mesa-Anotar (Join-Path $trabajos 'cuota-agy.txt') "== $(Mesa-IsoNow)`r`n$($c -join "`r`n")" }
    }
    return
  }
}

# ---- delegar ----
$reloj = [Diagnostics.Stopwatch]::StartNew()
function NoLanzado($motivo) { Write-Output "NO LANZADO: $motivo"; exit 3 }
if (-not $A -or -not $Encargo -or -not $Dir) { NoLanzado 'faltan -A, -Encargo o -Dir' }
foreach ($p in $Encargo, $Dir) { if ($p -match '[$(`]') { NoLanzado "la ruta lleva `$, ( o acento grave: $p" } }
if (-not (Test-Path -LiteralPath $Encargo -PathType Leaf)) { NoLanzado "no existe el encargo $Encargo" }
if (-not (Test-Path -LiteralPath $Dir -PathType Container)) { NoLanzado "no existe la carpeta $Dir" }
if ($Dir -match '^[A-Za-z]:\\?$') { NoLanzado "no se delega una raíz de unidad: $Dir" }
$Encargo = (Resolve-Path -LiteralPath $Encargo).Path; $Dir = (Resolve-Path -LiteralPath $Dir).Path.TrimEnd('\')
if ($Dir -eq [IO.Path]::GetPathRoot($Dir).TrimEnd('\')) { NoLanzado "no se delega una raíz de unidad: $Dir" }
foreach ($p in $Encargo, $Dir) { if ($p -match $Global:Mesa_Excluidos) { NoLanzado 'ruta excluida (datos\excluidos.txt)' } }
$cli = Ruta-Cli $A
if (-not $cli) { NoLanzado "$A no está en el PATH" }
# Nivel: el del parámetro o una línea «Nivel: alto» del .md; mesa.json (niveles.<nivel>.<cli>) lo traduce a modelo y esfuerzo. -Modelo y -Esfuerzo mandan.
if (-not $Nivel -and [IO.File]::ReadAllText($Encargo, [Text.Encoding]::UTF8) -match '(?im)^[\s>*#-]*Nivel\**:\**\s*(bajo|medio|alto)\b') { $Nivel = $Matches[1].ToLowerInvariant() }
$delNivel = if ($Nivel) { $cfg.niveles.$Nivel.$A }
if ($Nivel -and -not $delNivel.modelo -and -not $Modelo) { NoLanzado "el nivel $Nivel no tiene modelo para $A en mesa.json (niveles.$Nivel.$A)" }
if (-not $Modelo) { $Modelo = if ($delNivel.modelo) { $delNivel.modelo } else { Mesa-ModeloPorDefecto $A $cfg } }
if (-not $PSBoundParameters.ContainsKey('Esfuerzo') -and $delNivel.esfuerzo -in @('low', 'medium', 'high')) { $Esfuerzo = $delNivel.esfuerzo }
# De pago (la cuota de agentes de Devin): solo los modelos escritos en pago.<cli> de mesa.json.
$pago = $Modelo -in @($cfg.pago.$A)
if (-not $pago -and $Modelo -notin @($cfg.modelos.$A)) { NoLanzado "modelo $Modelo no está en mesa.json (modelos.$A ni pago.$A)" }
$repo = Raiz-Repo $Dir
if (-not $repo -and -not $Lectura) {
  $hijos = @(Get-ChildItem -LiteralPath $Dir -Directory -Depth 1 -ErrorAction SilentlyContinue | Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName '.git') })
  if ($hijos.Count) { NoLanzado "$Dir contiene repositorios sin ser uno: pide -Lectura o apunta a un repo" }
}
if (-not $Tarea) {
  $Tarea = [IO.Path]::GetFileNameWithoutExtension($Encargo).ToLowerInvariant() -replace '^encargo-', '' -replace "^$A-", '' -replace "-$A$", ''
}
if ($Tarea -notmatch '^[a-z0-9][a-z0-9-]*$') { NoLanzado "tarea «$Tarea»: solo minúsculas, cifras y guiones (usa -Tarea)" }
$hash = (Get-FileHash -LiteralPath $Encargo -Algorithm SHA256).Hash
$dirNorm = $Dir.TrimEnd('\', '/')
# El repo es el principal aunque -Dir sea un worktree suyo: todos los worktrees de los CLI van en su raíz.
$principal = if ($repo) { Mesa-RaizPrincipal $repo }
# Candado de la tarea: dos delegar con la misma tarea sobre el mismo repo (o carpeta) compartirían worktree y rama.
# Se toma antes de mirar los resultados para que la comprobación de «ya viva» o «ya hecho» no tenga carrera. Windows lo suelta si el proceso muere.
# shortcut: los tarea-*.lock (0 bytes) se acumulan en trabajos\; si molestan, se borran los que no estén abiertos.
$claveTarea = "$A|$Tarea|$($(if ($repo -and -not $Lectura) { $principal } else { $dirNorm }).ToLowerInvariant())"
$huella = -join ([Security.Cryptography.SHA1]::Create().ComputeHash([Text.Encoding]::UTF8.GetBytes($claveTarea)) | Select-Object -First 6 | ForEach-Object { $_.ToString('x2') })
try { $candadoTarea = [IO.File]::Open((Join-Path $trabajos "tarea-$A-$huella.lock"), 'OpenOrCreate', 'ReadWrite', 'None') }
catch { NoLanzado "la tarea $Tarea ya está viva en $dirNorm" }
Refrescar-Interrumpidos
$previos = @(Resultados | Where-Object agente -eq $A)
$enEsteRepo = { param($t) $t.dir -and $t.dir.TrimEnd('\', '/') -ieq $dirNorm }
$sc = Sin-Cuota $A $previos $pago $Modelo
if ($sc) { NoLanzado "$A$(if ($pago) { ' (de pago)' })$(if (Grupo-Cuota $A $Modelo) { " ($(Grupo-Cuota $A $Modelo))" }) sin cuota hasta $(Hora $sc.hasta)" }
$vivos = @($previos | Where-Object estado -eq 'ejecutando')
$vivo = $vivos | Where-Object { & $enEsteRepo $_ } | Select-Object -Last 1
if ($vivo -and $vivo.tarea -eq $Tarea) { NoLanzado "la tarea $Tarea ya está viva ($($vivo.id))" }
$hecho = $previos | Where-Object { $_.estado -eq 'hecho' -and $_.tarea -eq $Tarea -and $_.encargo_hash -eq $hash -and (& $enEsteRepo $_) } | Select-Object -Last 1
# Con -Lectura no hay worktree que proteger: una revisión de lectura se repite cuando haga falta.
if ($hecho -and -not $Lectura) { NoLanzado "ese .md ya se hizo ($($hecho.id)); escribe una corrección y relanza con -Tarea $Tarea" }
# Dos -Dir distintos (dos worktrees del mismo repo) con la misma tarea darían el mismo worktree del CLI, que partió de la rama del primero.
$rutaWt = if ($repo -and -not $Lectura) { Join-Path $principal ".claude\worktrees\$A-$Tarea" }
$dueno = if ($rutaWt) { $previos | Where-Object { $_.worktree -ieq $rutaWt } | Select-Object -Last 1 }
if ($dueno -and (Test-Path -LiteralPath $rutaWt) -and -not (& $enEsteRepo $dueno)) { NoLanzado "el worktree $A-$Tarea ya es de un encargo lanzado desde $($dueno.dir): usa otro -Tarea" }
# Límite de uso: apagado por defecto (limite_uso.activo en mesa.json), para calibrarlo con los datos de uso.jsonl. 0 = sin tope.
if ($cfg.limite_uso.activo) {
  $acum = Uso-Acumulado $A $(if ($cfg.limite_uso.horas) { [double]$cfg.limite_uso.horas } else { 5 }) (Uso-Leer)
  foreach ($m in 'encargos', 'tokens') { $t = [double]$cfg.limite_uso.$m.$A; if ($t -gt 0 -and $acum.$m -ge $t) { NoLanzado "$A llegó al límite de uso de mesa.json ($($acum.$m) de $t $m en $($cfg.limite_uso.horas) h)" } }
}
# Puestos: hasta N encargos a la vez por CLI, un archivo $A.<n>.lock por puesto, abierto en exclusiva (tomarlo es atómico: no hay carrera).
# Windows suelta el puesto si el proceso muere. Segunda pasada: «estado» de la Oficina y «limpiar» abren un instante cada candado para sondearlo.
$max = Mesa-Puestos $A $cfg
$candado = $null; $puesto = 0
foreach ($pasada in 1, 2) {
  for ($n = 1; $n -le $max -and -not $candado; $n++) {
    try { $candado = [IO.File]::Open((Join-Path $trabajos "$A.$n.lock"), 'OpenOrCreate', 'ReadWrite', 'None'); $puesto = $n } catch {}
  }
  if ($candado) { break }; Start-Sleep -Milliseconds 150
}
if (-not $candado) { NoLanzado "$A con $max de $max puestos ocupados ($(@($vivos | ForEach-Object id) -join ', '))" }
$anterior = $previos | Where-Object { $_.tarea -eq $Tarea -and $_.estado -in @('fallo', 'interrumpido') -and (& $enEsteRepo $_) } | Select-Object -Last 1
$wt = $null; $rama = $null
if ($repo -and -not $Lectura) {
  # Si el worktree falla no se lanza (antes caía al checkout principal con un aviso). Si ya existe, se reutiliza.
  try { $wt = @(& "$PSScriptRoot\worktrees.ps1" crear -Dir $repo -Agente $A -Tarea $Tarea 2>&1 | ForEach-Object { "$_" }) | Select-Object -Last 1 } catch { $wt = $_.Exception.Message }
  if (-not $wt -or -not (Test-Path -LiteralPath $wt)) { NoLanzado "no se pudo crear el worktree: $wt" }
  $rama = "$A/$Tarea"
}
$trabajo = if ($wt) { $wt } else { $Dir }
# El id lleva el segundo: si otro delegar de la misma tarea (en otra carpeta) lo tomó, se añade -2, -3… CreateNew lo reserva sin carrera.
$sello = "$A-$Tarea-$((Get-Date).ToString('yyyyMMdd-HHmmss'))"
for ($k = 1; ; $k++) {
  $id = if ($k -eq 1) { $sello } else { "$sello-$k" }
  $carpeta = Join-Path $trabajos $id
  New-Item -ItemType Directory -Force $carpeta | Out-Null
  try { [IO.File]::Open((Join-Path $carpeta 'encargo.md'), 'CreateNew').Dispose(); break } catch { if ($k -ge 50) { throw } }
}
Copy-Item -LiteralPath $Encargo -Destination (Join-Path $carpeta 'encargo.md')
$texto = [IO.File]::ReadAllText($Encargo, [Text.Encoding]::UTF8)
if ($wt) {
  # Las rutas del repo que existen en el worktree se cambian a él; lo no versionado (.entorno) sigue en el original.
  # El tramo admite espacios; si el final del match no existe en el worktree se recorta palabra a palabra
  # hasta el prefijo que sí existe y el resto del texto queda tal cual.
  $texto = [regex]::Replace($texto, [regex]::Escape($repo) + '[\\/][^\r\n"''`<>)\]]*', {
    param($m); $rel = $m.Value.Substring($repo.Length + 1)
    while (-not (Test-Path -LiteralPath (Join-Path $wt $rel))) {
      $i = $rel.LastIndexOf(' ')
      if ($i -lt 0) { return $m.Value }
      $rel = $rel.Substring(0, $i)
    }
    (Join-Path $wt $rel) + $m.Value.Substring($repo.Length + 1 + $rel.Length)
  }, 'IgnoreCase')
}
$cabecera = if ($wt) { "Trabajas en $wt (rama $rama). Solo cambias archivos ahí. No haces commit, push, merge, rebase ni cambias de rama: Claude revisa y confirma." }
  elseif ($Lectura) { "Trabajas en $trabajo en modo de solo lectura: no modificas nada y solo lees dentro de esa carpeta y los archivos que el encargo nombre por ruta absoluta. No hagas un plan ni pidas confirmación: tu respuesta final ES el entregable que pide el encargo, completa." }
  else { "Trabajas en $trabajo. Solo cambias archivos ahí." }
if (-not $Lectura -and -not $Sandbox) { $cabecera += " Trabajas sin sandbox: puedes compilar, correr pruebas y usar la red, pero no tocas nada fuera de esa carpeta salvo lo que el encargo nombre." }
$cabecera += " No abres programas con interfaz ni dejas procesos en segundo plano. Si algo te bloquea, para y dilo. Tu respuesta final empieza por el entregable completo (en solo lectura, todo lo que pide el encargo, no un resumen de él) y termina, aparte y en cuatro líneas, con: Hecho / Archivos tocados / Cómo lo probaste / Pendiente."
# rutas_equivalentes de mesa.json ([["D:\a", "D:\enlace\a"]]): un CLI que ve la carpeta por un enlace rechaza la otra ruta como ajena.
foreach ($par in @($cfg.rutas_equivalentes)) {
  if (@($par).Count -eq 2 -and $trabajo.StartsWith([string]$par[0], [StringComparison]::OrdinalIgnoreCase)) { $cabecera += " $($par[0]) y $($par[1]) son la misma carpeta: si una ruta de la primera se rechaza, usa la misma bajo la segunda." }
}
if ($anterior) { $cabecera += "`nREINTENTO: el intento $($anterior.id) terminó $($anterior.estado); log $(Join-Path $trabajos "$($anterior.id)\log.jsonl"); mira git status y no repitas lo hecho." }
$prompt = "$cabecera`n`n$texto"
$promptTxt = Join-Path $carpeta 'prompt.txt'; $log = Join-Path $carpeta 'log.jsonl'; $final = Join-Path $carpeta 'final.txt'
[IO.File]::WriteAllText($promptTxt, $prompt, $utf8)

$limite = if ($Minutos -gt 0) { $Minutos } elseif ($cfg.limites.encargo_min) { [double]$cfg.limites.encargo_min } else { 90 }
$inactivo = if ($cfg.limites.inactivo_min) { [double]$cfg.limites.inactivo_min } else { 20 }
$hooks = Join-Path $PSScriptRoot 'git-bloqueo'
# Bloqueo de refs y de push solo en el entorno del CLI: no toca la configuración del repo.
$gitPares = @(@('core.hooksPath', $hooks), @('url.cuadrilla-sin-push://.pushInsteadOf', 'https://'), @('url.cuadrilla-sin-push://.pushInsteadOf', 'git@'), @('url.cuadrilla-sin-push://.pushInsteadOf', 'ssh://'))
switch ($A) {
  'codex' {
    # --ephemeral: sin archivos de sesión en ~/.codex, que varias instancias a la vez no necesitan (nada se reanuda y la Cuadrilla no lee transcritos).
    $argumentos = @('exec', '--skip-git-repo-check', '--ephemeral', '-C', $trabajo)
    # Sin sandbox por defecto (D-002); -Lectura sigue sin poder escribir y -Sandbox vuelve al modo limitado.
    if ($Lectura) { $argumentos += @('-s', 'read-only') }
    elseif (-not $Sandbox) { $argumentos += '--dangerously-bypass-approvals-and-sandbox' }
    else {
      $argumentos += @('-s', 'workspace-write')
      if ($repo -and (Test-Path -LiteralPath (Join-Path $repo '.entorno'))) { $argumentos += @('--add-dir', (Join-Path $repo '.entorno')) }
      if ($Red) { $argumentos += @('-c', 'sandbox_workspace_write.network_access=true') }
    }
    # Codex quita del entorno de sus órdenes las variables con KEY en el nombre: las GIT_CONFIG_KEY_n se le pasan aparte.
    for ($i = 0; $i -lt $gitPares.Count; $i++) { $argumentos += @('-c', "shell_environment_policy.set.GIT_CONFIG_KEY_$i=`"$($gitPares[$i][0])`"") }
    $argumentos += @('--json', '-m', $Modelo, '-c', "model_reasoning_effort=`"$Esfuerzo`"", '-o', $final, '-')
    $entrada = $prompt
  }
  'agy' {
    $argumentos = @('-p', "Lee el encargo completo en el archivo UTF-8 $promptTxt y ejecuta sus instrucciones.", '--model', $Modelo, '--mode', $(if ($Lectura) { 'plan' } else { 'accept-edits' }), '--output-format', 'stream-json')
    if (-not $Lectura -and -not $Sandbox) { $argumentos += '--dangerously-skip-permissions' }
    # En plan, agy sin consola niega leer fuera del espacio de trabajo: prompt.txt va en la carpeta del trabajo (15-nov).
    if ($Lectura) { $argumentos += @('--add-dir', $carpeta) }
    # Varias instancias de agy compartirían su archivo de log global: cada encargo lleva el suyo.
    $argumentos += @('--log-file', (Join-Path $carpeta 'agy.log'))
    $entrada = ''
  }
  'devin' {
    # Devin no tiene sandbox en Windows: «dangerous» lo aprueba todo, «accept-edits» (-Sandbox) solo edita y «auto» (-Lectura) solo lee.
    # La confianza del workspace no se pregunta: cada worktree es una carpeta nueva.
    $argumentos = @('-p', '--prompt-file', $promptTxt, '--model', $Modelo, '--permission-mode', $(if ($Lectura) { 'auto' } elseif ($Sandbox) { 'accept-edits' } else { 'dangerous' }), '--respect-workspace-trust', 'false')
    $entrada = ''
  }
  'claude' {
    # Como agy: el encargo va por ruta (un -p con el texto entero pasaba del tope de línea de ordenes) y la respuesta llega por stream-json.
    # --no-session-persistence es su --ephemeral: varias instancias a la vez sin sesiones en disco. --add-dir deja leer prompt.txt, fuera de $Dir.
    $argumentos = @('-p', "Lee el encargo completo en el archivo UTF-8 $promptTxt y ejecuta sus instrucciones.", '--model', $Modelo, '--effort', $Esfuerzo, '--output-format', 'stream-json', '--verbose', '--no-session-persistence', '--add-dir', $carpeta)
    if ($Lectura) { $argumentos += @('--permission-mode', 'plan') }
    elseif (-not $Sandbox) { $argumentos += '--dangerously-skip-permissions' }
    else { $argumentos += @('--permission-mode', 'acceptEdits') }
    $entrada = ''
  }
}
$yo = Get-Process -Id $PID
$resultado = [ordered]@{
  id = $id; agente = $A; tarea = $Tarea; modelo = $Modelo; esfuerzo = $Esfuerzo; dir = $Dir; worktree = $wt; rama = $rama; lectura = [bool]$Lectura; nivel = $Nivel; puesto = $puesto; pago = $pago
  encargo = $Encargo; encargo_hash = $hash; estado = 'ejecutando'; inicio = Mesa-IsoNow; fin = $null; salida = $null; causa = $null; hasta = $null
  lanzador = @{ pid = $PID; inicio = $yo.StartTime.ToUniversalTime().ToString('o'); nombre = $yo.ProcessName }; cli = $null
  tokens = $null; avisos = @(); cambios = $null; respuesta = $null; cpu_lanzador_s = $null
}
$rutaResultado = Join-Path $carpeta 'resultado.json'
Mesa-EscribirJson $rutaResultado $resultado
$antes = @{ head = $(if ($wt) { Orden-Git $wt rev-parse HEAD }); origen = $(if ($wt) { Orden-Git $wt rev-parse "refs/remotes/origin/$rama" }); principal = $(if ($repo) { Orden-Git $repo status --porcelain }) }
. "$PSScriptRoot\proceso.ps1"
$cuotaAntes = Leer-Cuota $A (Join-Path $carpeta 'cuota.tmp')
try {
  for ($i = 0; $i -lt $gitPares.Count; $i++) { Set-Item "env:GIT_CONFIG_KEY_$i" $gitPares[$i][0]; Set-Item "env:GIT_CONFIG_VALUE_$i" $gitPares[$i][1] }
  $env:GIT_CONFIG_COUNT = $gitPares.Count
  $r = Invocar-ProcesoMesa -Ejecutable $cli -Argumentos $argumentos -Entrada $entrada -Directorio $trabajo -Log $log -Segundos ($limite * 60) -Inactivo ($inactivo * 60) -Latido:(-not $Lectura) -AlIniciar {
    param($identidad); $resultado.cli = $identidad; Mesa-EscribirJson $rutaResultado $resultado; $true
  }
} finally {
  $env:GIT_CONFIG_COUNT = $null
  for ($i = 0; $i -lt $gitPares.Count; $i++) { Remove-Item "env:GIT_CONFIG_KEY_$i", "env:GIT_CONFIG_VALUE_$i" -ErrorAction SilentlyContinue }
}

# Recoger: texto, tokens y causa salen del propio log del CLI; nunca de transcritos de sesión.
$eventos = @(); $texto = ''; $tokens = $null; $evFinal = $null; $agyStatus = $null
if (Test-Path -LiteralPath $log) {
  foreach ($l in [IO.File]::ReadLines($log, [Text.Encoding]::UTF8)) { if ($l.Trim().StartsWith('{')) { try { $eventos += ($l | ConvertFrom-Json -ErrorAction Stop) } catch {} } }
}
if ($A -eq 'devin') {
  # Devin imprime texto llano: la respuesta es la salida entera.
  if (Test-Path -LiteralPath $log) { $texto = [IO.File]::ReadAllText($log, [Text.Encoding]::UTF8).Trim() }
} elseif ($A -eq 'codex') {
  if (Test-Path -LiteralPath $final) { $texto = [IO.File]::ReadAllText($final, [Text.Encoding]::UTF8).Trim() }
  foreach ($ev in $eventos) {
    if ($ev.type -eq 'item.completed' -and $ev.item.type -eq 'agent_message' -and -not (Test-Path -LiteralPath $final)) { $texto = [string]$ev.item.text }
    if ($ev.type -eq 'turn.completed' -and $ev.usage) { $u = $ev.usage; $tokens = @{ entrada = [int64]$u.input_tokens + [int64]$u.cached_input_tokens; salida = [int64]$u.output_tokens } }
    if ($ev.type -in @('turn.failed', 'error', 'turn.completed')) { $evFinal = $ev }
  }
} else {
  $ev = $eventos | Where-Object { $_.event -eq 'result' -or $_.type -eq 'result' -or $_.status } | Select-Object -Last 1
  if ($ev) {
    $evFinal = $ev; $res = if ($ev.result -and $ev.result -isnot [string]) { $ev.result } else { $ev }
    $agyStatus = $res.status
    $texto = if ($res.response -is [string]) { $res.response } elseif ($ev.result -is [string]) { $ev.result } else { '' }
    if ($res.usage) { $u = $res.usage; $tokens = @{ entrada = [int64]$u.input_tokens; salida = [int64]$u.output_tokens; total = [int64]$u.total_tokens } }
    # claude trae el coste medido en total_cost_usd: mejor que estimarlo por precios.
    if ($ev.total_cost_usd) { $usdCli = [double]$ev.total_cost_usd }
  }
}
if ($tokens -and -not $tokens.total) { $tokens.total = $tokens.entrada + $tokens.salida }
$causa = $r.causa; $hasta = $null; $avisos = @(); $fallo = $false
if (-not $causa -and $evFinal) { $f = Mesa-CausaFallo ($evFinal | ConvertTo-Json -Depth 20 -Compress); if ($f) { $causa = $f.causa; $hasta = $f.hasta; $fallo = $true } }
# Devin no da eventos: su fallo es la salida llana («Error: Agent error: …quota…»).
if (-not $causa -and $A -eq 'devin' -and $r.salida -ne 0 -and $texto) { $f = Mesa-CausaFallo $texto; if ($f) { $causa = $f.causa; $hasta = $f.hasta; $fallo = $true } }
$estado = if ($r.salida -eq 124) { $causa } elseif ($r.salida -ne 0 -or $fallo) { 'fallo' } else { 'hecho' }
if ($A -eq 'agy' -and $estado -eq 'fallo' -and $agyStatus -eq 'ERROR' -and $texto -and -not $causa) {
  # #107 y #129: agy marcó ERROR habiendo entregado la respuesta. Solo vale sin causa real: un 503 con texto parcial sigue siendo fallo.
  $estado = 'hecho'; $avisos += "agy terminó con status ERROR pero entregó respuesta"
}
if ($estado -eq 'hecho' -and -not $texto) { $avisos += 'respuesta vacía' }
$cambios = $null
if ($wt) {
  $cambios = @{ status = Orden-Git $wt status --short; diff = Orden-Git $wt diff --stat }
  if ((Orden-Git $wt rev-parse HEAD) -ne $antes.head) { $avisos += 'HEAD del worktree se movió' }
  if ((Orden-Git $wt rev-parse "refs/remotes/origin/$rama") -ne $antes.origen) { $avisos += "cambió refs/remotes/origin/$rama" }
}
if ($repo -and (Orden-Git $repo status --porcelain) -ne $antes.principal) { $avisos += "cambió el status de $(if ($Lectura) { 'la carpeta' } else { 'el checkout principal' })" }
if (-not $texto) { $texto = "(sin texto de salida; log en $log)" }
# La respuesta completa siempre queda en final.txt (Devin y agy no lo escribían y el recorte perdía el principio, 15-nov).
if (-not (Test-Path -LiteralPath $final) -and $texto) { [IO.File]::WriteAllText($final, $texto, $utf8) }
if ($texto.Length -gt 3000) { $texto = '…' + $texto.Substring($texto.Length - 3000) + "`n(respuesta completa en $final)" }
$texto = Mesa-Ocultar $texto
$resultado.estado = $estado; $resultado.fin = Mesa-IsoNow; $resultado.causa = $causa; $resultado.hasta = $hasta; $resultado.tokens = $tokens
$resultado.avisos = $avisos; $resultado.cambios = $cambios; $resultado.respuesta = $texto
$resultado.cpu_lanzador_s = [Math]::Round((Get-Process -Id $PID).TotalProcessorTime.TotalSeconds, 2)
$codigo = if ($estado -eq 'hecho') { $(if ($avisos.Count) { 2 } else { 0 }) } elseif ($r.salida -eq 124) { 124 } else { 1 }
$resultado.salida = $codigo
Mesa-EscribirJson $rutaResultado $resultado
# Registro de restablecimientos (el de ChatGPT es el que se pidió): cada señal sin cuota con su hora de vuelta.
if ($causa -eq 'sin-cuota') { Mesa-Anotar (Join-Path $trabajos "cuota-$A.txt") "$(Mesa-IsoNow) sin cuota$(if ($pago) { ' (de pago)' }) hasta $hasta ($id)" }
$candado.Dispose(); $candadoTarea.Dispose()
# Registro de uso, ya con el puesto libre. Coste aproximado: tokens por precios.<modelo> de mesa.json (USD por millón de entrada y de salida);
# en ChatGPT y Gemini es el equivalente de API (van por suscripción) y Devin no informa de tokens, así que ahí queda vacío.
$precio = @($cfg.precios.$Modelo)
$usd = if ($usdCli) { [Math]::Round($usdCli, 4) } elseif ($tokens -and $precio.Count -eq 2) { [Math]::Round(($tokens.entrada * [double]$precio[0] + $tokens.salida * [double]$precio[1]) / 1e6, 4) }
$linea = [ordered]@{
  id = $id; agente = $A; modelo = $Modelo; esfuerzo = $Esfuerzo; nivel = $Nivel; pago = $pago; estado = $estado; causa = $causa; inicio = $resultado.inicio; fin = $resultado.fin
  segundos = [int]$reloj.Elapsed.TotalSeconds; tokens = $(if ($tokens) { $tokens.total }); tokens_entrada = $(if ($tokens) { $tokens.entrada }); tokens_salida = $(if ($tokens) { $tokens.salida }); usd = $usd
  cuota_antes = $cuotaAntes; cuota_despues = (Leer-Cuota $A (Join-Path $carpeta 'cuota.tmp'))
}
# Un «if» sin resultado no es $null para ConvertTo-Json de PowerShell 5.1 (escribe {}): se deja en null de verdad.
foreach ($k in @($linea.Keys)) { if ($null -eq $linea[$k] -or '' -eq $linea[$k]) { $linea[$k] = $null } }
Mesa-Anotar (Join-Path $trabajos 'uso.jsonl') ($linea | ConvertTo-Json -Depth 5 -Compress)
"$id $estado salida=$codigo$(if ($causa) { " causa=$causa" })$(if ($hasta) { " hasta=$(Hora $hasta)" }) $([int]$reloj.Elapsed.TotalSeconds) s tokens=$(if ($tokens) { $tokens.total } else { '?' })$(if ($avisos.Count) { " AVISOS: $($avisos -join '; ')" })"
$rutaResultado
$texto
exit $codigo
