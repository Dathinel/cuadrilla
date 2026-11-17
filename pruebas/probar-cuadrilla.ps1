# cuadrilla.ps1 con CLI falsos en una copia aislada (MESA_DATOS en %TEMP%): salidas, rechazos, cortes y git. No gasta cuota.
param([switch]$Conservar)
$ErrorActionPreference = 'Stop'
$base = Split-Path -Parent $PSScriptRoot
$raiz = Join-Path $env:TEMP ('mesa-cuadrilla-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
$datos = Join-Path $raiz 'datos'; $h = Join-Path $raiz 'herramientas'; $bin = Join-Path $raiz 'bin'; $casos = Join-Path $raiz 'casos'
$utf8 = New-Object Text.UTF8Encoding $false; $bom = New-Object Text.UTF8Encoding $true
$guardado = @{}
foreach ($clave in @('MESA_DATOS', 'MESA_TRABAJO', 'MESA_FALSO_DIR', 'MESA_FALSO_MODO', 'LOCALAPPDATA', 'Path', 'USERPROFILE')) { $guardado[$clave] = [Environment]::GetEnvironmentVariable($clave, 'Process') }
$script:fallos = 0; $lanzados = New-Object Collections.ArrayList
function Caso($nombre, $esperado, $obtenido, [bool]$ok) {
  if (-not $ok) { $script:fallos++ }
  Write-Host ("[{0}] {1}`n      esperado: {2}`n      obtenido: {3}" -f $(if ($ok) { 'OK' } else { 'FALLO' }), $nombre, $esperado, $obtenido)
}
function Esperar([scriptblock]$condicion, [int]$segundos = 30) {
  $fin = (Get-Date).AddSeconds($segundos)
  while (-not (& $condicion)) { if ((Get-Date) -ge $fin) { throw "Tiempo de espera de la prueba ($segundos s)." }; Start-Sleep -Milliseconds 100 }
}
function Encargo-Md($nombre, $texto = 'Objetivo: prueba. Contexto: ninguno. Hecho cuando: sí. No toques: nada.') { $f = Join-Path $casos $nombre; [IO.File]::WriteAllText($f, $texto, $utf8); $f }
# Cada delegar es un proceso aparte, como lo lanza Claude: así valen el candado y la muerte del lanzador.
function Lanzar($modo, [string[]]$argumentos) {
  $casoDir = Join-Path $casos ('falso-' + [Guid]::NewGuid().ToString('N').Substring(0, 6)); New-Item -ItemType Directory -Force $casoDir | Out-Null
  $env:MESA_FALSO_DIR = $casoDir; $env:MESA_FALSO_MODO = $modo
  $todos = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$h\cuadrilla.ps1`"", 'delegar') + @($argumentos | ForEach-Object { if ($_ -like '-*') { $_ } else { "`"$_`"" } })
  $p = Start-Process powershell.exe -ArgumentList $todos -WindowStyle Hidden -PassThru -RedirectStandardOutput (Join-Path $casoDir 'salida.txt') -RedirectStandardError (Join-Path $casoDir 'error.txt')
  $null = $p.Handle; [void]$lanzados.Add($p)
  [pscustomobject]@{ proceso = $p; carpeta = $casoDir; reloj = [Diagnostics.Stopwatch]::StartNew() }
}
function Terminar($l, [int]$segundos = 60) {
  if (-not $l.proceso.WaitForExit($segundos * 1000)) { throw "delegar no terminó: $($l.carpeta)" }
  $l.reloj.Stop()
  $salida = [IO.File]::ReadAllText((Join-Path $l.carpeta 'salida.txt'), $utf8)
  $err = [IO.File]::ReadAllText((Join-Path $l.carpeta 'error.txt'), $utf8)
  $res = if ($salida -match '(?m)^(.+\\resultado\.json)\s*$') { Mesa-LeerJson $Matches[1] }
  [pscustomobject]@{ codigo = $l.proceso.ExitCode; texto = $salida; error = $err; resultado = $res; segundos = $l.reloj.Elapsed.TotalSeconds; carpeta = $l.carpeta }
}
function Delegar($modo, [string[]]$argumentos) { Terminar (Lanzar $modo $argumentos) }
function Vivos($arbol) { return @($arbol | Where-Object { Mesa-ProcesoVivo $_.id $_.inicio $_.nombre }).Count }
function Arbol($l) { $f = Join-Path $l.carpeta 'arbol.json'; Esperar { Test-Path -LiteralPath $f }; @(Mesa-LeerJson $f) }
function Resultado-Vivo($agente) {
  $fin = (Get-Date).AddSeconds(30)
  do {
    $v = Get-ChildItem (Join-Path $datos 'trabajos') -Directory -Filter "$agente-*" | ForEach-Object { Mesa-LeerJson (Join-Path $_.FullName 'resultado.json') } | Where-Object { $_.estado -eq 'ejecutando' -and $_.cli } | Select-Object -Last 1
    if ($v) { return $v }; Start-Sleep -Milliseconds 100
  } while ((Get-Date) -lt $fin)
  throw "ningún encargo de $agente vivo"
}
function Res-Vivos($agente) { @(Get-ChildItem (Join-Path $datos 'trabajos') -Directory -Filter "$agente-*" | ForEach-Object { Mesa-LeerJson (Join-Path $_.FullName 'resultado.json') } | Where-Object { $_.estado -eq 'ejecutando' -and $_.cli }) }
function Estado { & powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$h\cuadrilla.ps1" estado 2>&1 | Out-String }

try {
  New-Item -ItemType Directory -Force $h, $bin, (Join-Path $datos 'trabajos'), $casos, (Join-Path $raiz 'perfil') | Out-Null
  foreach ($a in @('cuadrilla.ps1', 'proceso.ps1', 'comun.ps1', 'worktrees.ps1')) { Copy-Item -LiteralPath (Join-Path $base "herramientas\$a") -Destination $h }
  Copy-Item -LiteralPath (Join-Path $base 'herramientas\git-bloqueo') -Destination (Join-Path $h 'git-bloqueo') -Recurse
  New-Item -ItemType Directory -Force (Join-Path $raiz 'plantillas\cuadrilla') | Out-Null
  Copy-Item -LiteralPath (Join-Path $base 'plantillas\cuadrilla\SKILL.md') -Destination (Join-Path $raiz 'plantillas\cuadrilla')
  [IO.File]::WriteAllText((Join-Path $datos 'mesa.json'), '{"modelos":{"codex":["modelo-falso","modelo-caro","modelo-otro"],"agy":["modelo-falso"],"devin":["swe-2-falso"]},"pago":{"devin":["claude-falso-de-pago"]},"niveles":{"bajo":{"codex":{"modelo":"modelo-falso","esfuerzo":"low"}},"alto":{"codex":{"modelo":"modelo-caro","esfuerzo":"high"},"devin":{"modelo":"claude-falso-de-pago"}}},"precios":{"modelo-falso":[1000000,2000000]},"limites":{"encargo_min":0.5,"inactivo_min":0.05},"worktrees":{"max_por_agente":3},"puestos":{"codex":2,"agy":2,"devin":2}}', $utf8)
  # Canario genérico: las zonas excluidas reales nunca se nombran, ni siquiera en pruebas.
  [IO.File]::WriteAllText((Join-Path $datos 'excluidos.txt'), "ZONA-PROHIBIDA`r`n", $utf8)
  # Solo los CLI falsos y lo imprescindible (git, powershell): nunca un CLI real.
  $gitDir = Split-Path -Parent (Get-Command git.exe).Source
  $env:Path = "$bin;$gitDir;$env:SystemRoot\System32;$env:SystemRoot\System32\WindowsPowerShell\v1.0"
  $env:MESA_DATOS = $datos; $env:MESA_TRABAJO = $casos; $env:LOCALAPPDATA = $raiz; $env:USERPROFILE = Join-Path $raiz 'perfil'
  . "$h\comun.ps1"

  $falso = @'
[Console]::InputEncoding = New-Object Text.UTF8Encoding $false
[Console]::OutputEncoding = New-Object Text.UTF8Encoding $false
$u = New-Object Text.UTF8Encoding $false
$dir = $env:MESA_FALSO_DIR; $modo = $env:MESA_FALSO_MODO
$cli = [IO.Path]::GetFileNameWithoutExtension($PSCommandPath)
$argumentos = @($args)
# Lecturas de cuota de delegar: no son el encargo y no dejan rastro en la carpeta del caso.
if ($argumentos -contains 'app-server') { [Console]::WriteLine('{"id":2,"result":{"rateLimits":{"primary":{"usedPercent":12,"windowDurationMins":300,"resetsAt":1794834080},"secondary":{"usedPercent":65,"windowDurationMins":10080,"resetsAt":1794889221}},"rateLimitResetCredits":{"availableCount":3}}}'); Start-Sleep -Seconds 20; exit 0 }
if ($argumentos -contains '/usage') { [Console]::WriteLine("Gemini Models`tFive Hour Limit Remaining`t64%`t2026-11-16T14:15:38Z"); exit 0 }
$texto = [Console]::In.ReadToEnd()
$i = [Array]::IndexOf($argumentos, '-p')
if ($i -ge 0 -and $argumentos[$i + 1] -match 'archivo UTF-8 (.+) y ejecuta') { $texto = [IO.File]::ReadAllText($Matches[1], $u) }
$j = [Array]::IndexOf($argumentos, '--prompt-file'); if ($j -ge 0) { $texto = [IO.File]::ReadAllText($argumentos[$j + 1], $u) }
[IO.File]::WriteAllText((Join-Path $dir 'entrada.txt'), $texto, $u)
[IO.File]::WriteAllText((Join-Path $dir 'argumentos.json'), (ConvertTo-Json -InputObject $argumentos -Compress), $u)
[IO.File]::WriteAllText((Join-Path $dir 'cwd.txt'), (Get-Location).Path, $u)
function Evento($o) { [Console]::WriteLine((ConvertTo-Json -InputObject $o -Compress -Depth 5)) }
if ($modo -in @('arbol', 'mudo')) {
  $p = Start-Process powershell.exe -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File',("`"" + (Join-Path (Split-Path -Parent $PSCommandPath) 'hijo.ps1') + "`"") -PassThru -WindowStyle Hidden
  while (-not (Test-Path (Join-Path $dir 'arbol.json'))) { Start-Sleep -Milliseconds 40 }
  if ($modo -eq 'mudo') { Start-Sleep -Seconds 300 }
  for ($n = 0; $n -lt 300; $n++) { [Console]::WriteLine("latido $n"); Start-Sleep -Seconds 1 }
}
if ($modo -eq 'git') {
  # Latidos entre órdenes: con la máquina cargada, git tardaba más que el corte por silencio de la prueba (3 s).
  $c1 = & git commit --allow-empty -m x 2>&1; $commit = $LASTEXITCODE; [Console]::WriteLine('latido')
  $c2 = & git push origin HEAD:main 2>&1; $push = $LASTEXITCODE; [Console]::WriteLine('latido')
  [IO.File]::AppendAllText((Join-Path (Get-Location).Path 'README.md'), 'cambio', $u)
  $c3 = & git stash 2>&1; $stash = $LASTEXITCODE
  & git checkout -- README.md 2>&1 | Out-Null
  [IO.File]::WriteAllText((Join-Path $dir 'git.json'), (ConvertTo-Json -Compress @{ commit = $commit; push = $push; stash = $stash; salida = "$c1`n$c2`n$c3" }), $u)
}
# lento: unos segundos con latidos (el corte por silencio es de 3 s) para que dos encargos coincidan; deja su cwd en la respuesta.
if ($modo -in @('lento', 'cuota-lento')) { for ($n = 0; $n -lt 8; $n++) { [Console]::WriteLine("latido $n"); Start-Sleep -Milliseconds 500 }; [Console]::WriteLine("cwd=$((Get-Location).Path)") }
if ($modo -eq 'cuota-lento') { $modo = 'cuota' }
if ($cli -eq 'codex') {
  switch ($modo) {
    'cuota' { Evento @{ type = 'error'; message = 'You have hit your usage limit. Upgrade to Pro or try again at 6:57 PM.' }; Evento @{ type = 'turn.failed'; error = @{ message = 'You have hit your usage limit. Upgrade to Pro or try again at 6:57 PM.' } }; exit 1 }
    '401' { Evento @{ type = 'turn.failed'; error = @{ message = 'Error: 401 Unauthorized. Please run codex login' } }; exit 1 }
    default {
      Evento @{ type = 'item.completed'; item = @{ type = 'agent_message'; text = 'respuesta item con acción' } }
      Evento @{ type = 'turn.completed'; usage = @{ input_tokens = 13; cached_input_tokens = 0; output_tokens = 7 } }
      $o = [Array]::IndexOf($argumentos, '-o')
      if ($modo -ne 'sin-final' -and $o -ge 0) { [IO.File]::WriteAllText($argumentos[$o + 1], 'respuesta final con acción', $u) }
    }
  }
} else {
  Evento @{ event = 'init'; conversation_id = 'x' }
  switch ($modo) {
    'agy-error' { Evento @{ event = 'result'; result = @{ status = 'ERROR'; response = 'respuesta agy a medias'; error = 'Malformed function call'; usage = @{ input_tokens = 13; output_tokens = 7; total_tokens = 20 } } }; exit 1 }
    '503' { Evento @{ event = 'result'; result = @{ status = 'ERROR'; response = ''; error = '503 Service Unavailable' } }; exit 1 }
    default { Evento @{ event = 'result'; result = @{ status = 'SUCCESS'; response = 'respuesta agy con acción'; usage = @{ input_tokens = 13; output_tokens = 7; total_tokens = 20 } } } }
  }
}
'@
  foreach ($cli in @('codex', 'agy', 'devin')) { [IO.File]::WriteAllText((Join-Path $bin "$cli.ps1"), $falso, $bom) }
  $hijo = @'
$nieto = Start-Process powershell.exe -ArgumentList '-NoProfile','-Command','Start-Sleep -Seconds 300' -PassThru -WindowStyle Hidden
$arbol = @((Get-Process -Id $PID), $nieto) | ForEach-Object { @{ id = $_.Id; inicio = $_.StartTime.ToUniversalTime().ToString('o'); nombre = $_.ProcessName } }
[IO.File]::WriteAllText((Join-Path $env:MESA_FALSO_DIR 'arbol.json'), (ConvertTo-Json -InputObject @($arbol) -Compress), (New-Object Text.UTF8Encoding $false))
Start-Sleep -Seconds 300
'@
  [IO.File]::WriteAllText((Join-Path $bin 'hijo.ps1'), $hijo, $bom)
  $carpeta = Join-Path $casos 'carpeta'; New-Item -ItemType Directory -Force $carpeta | Out-Null

  # --- salidas ---
  $r = Delegar normal @('-A', 'codex', '-Encargo', (Encargo-Md 'uno.md'), '-Dir', $carpeta)
  Caso 'codex con final.txt' 'salida 0, hecho, respuesta de final.txt, 20 tokens medidos' "codigo=$($r.codigo), estado=$($r.resultado.estado), respuesta=$($r.resultado.respuesta), tokens=$($r.resultado.tokens.total) $($r.error)" ($r.codigo -eq 0 -and $r.resultado.estado -eq 'hecho' -and $r.resultado.respuesta -eq 'respuesta final con acción' -and $r.resultado.tokens.total -eq 20 -and $r.resultado.cli.cli_pid -gt 0)
  $args1 = @(Mesa-LeerJson (Join-Path $r.carpeta 'argumentos.json'))
  Caso 'codex sin sandbox por defecto y sin sesión en disco' '--dangerously-bypass-approvals-and-sandbox y --ephemeral, sin -s' ($args1 -join ' ') ($args1 -contains '--dangerously-bypass-approvals-and-sandbox' -and $args1 -contains '--ephemeral' -and $args1 -notcontains 'workspace-write')
  $entrada = [IO.File]::ReadAllText((Join-Path $r.carpeta 'entrada.txt'), $utf8)
  Caso 'prompt con cabecera y encargo' 'cabecera fija, sin REINTENTO, encargo al final' ($entrada.Substring(0, [Math]::Min(80, $entrada.Length))) ($entrada -like 'Trabajas en *' -and $entrada -notmatch 'REINTENTO' -and $entrada -like '*No toques: nada.')
  $usoF = Join-Path $datos 'trabajos\uso.jsonl'
  $u1 = if (Test-Path $usoF) { @([IO.File]::ReadAllLines($usoF, $utf8) | Where-Object { $_ } | ForEach-Object { $_ | ConvertFrom-Json }) | Where-Object id -eq $r.resultado.id }
  Caso 'registro de uso del encargo' 'una línea en uso.jsonl con modelo, tokens, coste y cuota de codex antes y después (12 % en 5 h, 3 restablecimientos)' "modelo=$($u1.modelo), tokens=$($u1.tokens), usd=$($u1.usd), antes=$($u1.cuota_antes.cinco_h_usado), despues=$($u1.cuota_despues.cinco_h_usado), rest=$($u1.cuota_antes.restablecimientos), reinicio=$($u1.cuota_antes.cinco_h_reinicio)" ($u1.modelo -eq 'modelo-falso' -and $u1.tokens -eq 20 -and $u1.usd -eq 27 -and $u1.cuota_antes.cinco_h_usado -eq 12 -and $u1.cuota_despues.cinco_h_usado -eq 12 -and $u1.cuota_antes.restablecimientos -eq 3 -and $u1.cuota_antes.cinco_h_reinicio -and $u1.segundos -ge 0)
  $r = Delegar normal @('-A', 'codex', '-Encargo', (Encargo-Md 'nivel1.md'), '-Dir', $carpeta, '-Nivel', 'alto')
  $argsN = @(Mesa-LeerJson (Join-Path $r.carpeta 'argumentos.json')) -join ' '
  Caso '-Nivel alto elige modelo y esfuerzo' 'modelo-caro con model_reasoning_effort="high" y nivel=alto en el resultado' "codigo=$($r.codigo), modelo=$($r.resultado.modelo), esfuerzo=$($r.resultado.esfuerzo), nivel=$($r.resultado.nivel)" ($r.codigo -eq 0 -and $r.resultado.modelo -eq 'modelo-caro' -and $r.resultado.esfuerzo -eq 'high' -and $r.resultado.nivel -eq 'alto' -and $argsN -match 'modelo-caro' -and $argsN -match 'model_reasoning_effort="high"')
  $r = Delegar normal @('-A', 'codex', '-Encargo', (Encargo-Md 'nivel2.md' "Objetivo: prueba.`nNivel: alto`nNo toques: nada."), '-Dir', $carpeta)
  Caso 'Nivel declarado en el .md' 'modelo-caro sin pasar -Nivel' "codigo=$($r.codigo), modelo=$($r.resultado.modelo), nivel=$($r.resultado.nivel)" ($r.codigo -eq 0 -and $r.resultado.modelo -eq 'modelo-caro' -and $r.resultado.nivel -eq 'alto')
  $r = Delegar normal @('-A', 'codex', '-Encargo', (Encargo-Md 'nivel3.md'), '-Dir', $carpeta, '-Nivel', 'alto', '-Modelo', 'modelo-otro', '-Esfuerzo', 'low')
  Caso '-Modelo y -Esfuerzo mandan sobre el nivel' 'modelo-otro con esfuerzo low' "codigo=$($r.codigo), modelo=$($r.resultado.modelo), esfuerzo=$($r.resultado.esfuerzo)" ($r.codigo -eq 0 -and $r.resultado.modelo -eq 'modelo-otro' -and $r.resultado.esfuerzo -eq 'low')
  $r = Delegar normal @('-A', 'codex', '-Encargo', (Encargo-Md 'nivel4.md'), '-Dir', $carpeta)
  Caso 'sin nivel, el modelo por defecto de siempre' 'modelo-falso, esfuerzo medium, sin nivel' "modelo=$($r.resultado.modelo), esfuerzo=$($r.resultado.esfuerzo), nivel=$($r.resultado.nivel)" ($r.codigo -eq 0 -and $r.resultado.modelo -eq 'modelo-falso' -and $r.resultado.esfuerzo -eq 'medium' -and -not $r.resultado.nivel)
  $r = Delegar normal @('-A', 'agy', '-Encargo', (Encargo-Md 'nivel5.md'), '-Dir', $carpeta, '-Nivel', 'alto')
  Caso 'nivel sin modelo para ese CLI' '3 con «no tiene modelo para agy»' "codigo=$($r.codigo), texto=$($r.texto.Trim())" ($r.codigo -eq 3 -and $r.texto -match 'el nivel alto no tiene modelo para agy')
  $r = Delegar sin-final @('-A', 'codex', '-Encargo', (Encargo-Md 'dos.md'), '-Dir', $carpeta)
  Caso 'codex sin final.txt' 'texto del item.text del último agent_message' "codigo=$($r.codigo), respuesta=$($r.resultado.respuesta)" ($r.codigo -eq 0 -and $r.resultado.respuesta -eq 'respuesta item con acción')
  $r = Delegar agy-error @('-A', 'agy', '-Encargo', (Encargo-Md 'tres.md'), '-Dir', $carpeta)
  Caso 'agy ERROR con respuesta' 'salida 2, hecho con aviso, respuesta no vacía' "codigo=$($r.codigo), estado=$($r.resultado.estado), avisos=$($r.resultado.avisos -join ';')" ($r.codigo -eq 2 -and $r.resultado.estado -eq 'hecho' -and $r.resultado.respuesta -eq 'respuesta agy a medias' -and @($r.resultado.avisos).Count -eq 1)
  $args4 = @(Mesa-LeerJson (Join-Path $r.carpeta 'argumentos.json'))
  Caso 'agy va en stream-json y accept-edits' '--output-format stream-json, --mode accept-edits, --model modelo-falso' ($args4 -join ' ') ($args4 -contains 'stream-json' -and $args4 -contains 'accept-edits' -and $args4 -contains 'modelo-falso')
  Caso 'agy sin permisos que pedir por defecto' '--dangerously-skip-permissions' ($args4 -join ' ') ($args4 -contains '--dangerously-skip-permissions')
  $iLog = [Array]::IndexOf($args4, '--log-file')
  Caso 'agy con su propio log por encargo' "--log-file <carpeta de $($r.resultado.id)>\agy.log" ($args4 -join ' ') ($iLog -ge 0 -and $args4[$iLog + 1] -like "*\trabajos\$($r.resultado.id)\agy.log")
  $r = Delegar normal @('-A', 'devin', '-Encargo', (Encargo-Md 'devin1.md'), '-Dir', $carpeta)
  $argsDevin = @(Mesa-LeerJson (Join-Path $r.carpeta 'argumentos.json'))
  Caso 'devin: dangerous por defecto, prompt por archivo y respuesta de la salida' 'salida 0, --permission-mode dangerous, --prompt-file, respuesta no vacía' "codigo=$($r.codigo), args=$($argsDevin -join ' ')" ($r.codigo -eq 0 -and $argsDevin -contains 'dangerous' -and $argsDevin -contains '--prompt-file' -and $argsDevin -contains 'swe-2-falso' -and $r.resultado.respuesta -and $r.resultado.pago -eq $false)
  $finalDevin = Join-Path $datos "trabajos\$($r.resultado.id)\final.txt"
  Caso 'devin deja la respuesta completa en final.txt' 'final.txt con el texto de la salida' (Test-Path $finalDevin) ((Test-Path $finalDevin) -and ([IO.File]::ReadAllText($finalDevin, $utf8).Trim().Length -gt 0))
  $r = Delegar normal @('-A', 'devin', '-Encargo', (Encargo-Md 'devin2.md'), '-Dir', $carpeta, '-Sandbox')
  $argsDevin = @(Mesa-LeerJson (Join-Path $r.carpeta 'argumentos.json'))
  Caso 'devin -Sandbox solo edita' '--permission-mode accept-edits' ($argsDevin -join ' ') ($r.codigo -eq 0 -and $argsDevin -contains 'accept-edits' -and $argsDevin -notcontains 'dangerous')
  $r = Delegar normal @('-A', 'devin', '-Encargo', (Encargo-Md 'devin3.md'), '-Dir', $carpeta, '-Modelo', 'claude-falso-de-pago')
  Caso 'devin con -Modelo de pago (escrito en pago.devin) va y lo marca' 'salida 0 y pago=true' "codigo=$($r.codigo), pago=$($r.resultado.pago), texto=$($r.texto.Trim() -split "`n" | Select-Object -First 1)" ($r.codigo -eq 0 -and $r.resultado.pago -eq $true)
  $r = Delegar normal @('-A', 'devin', '-Encargo', (Encargo-Md 'devin5.md'), '-Dir', $carpeta, '-Nivel', 'alto')
  Caso 'devin: el nivel alto activa el modelo de pago' 'salida 0, claude-falso-de-pago y pago=true' "codigo=$($r.codigo), modelo=$($r.resultado.modelo), pago=$($r.resultado.pago)" ($r.codigo -eq 0 -and $r.resultado.modelo -eq 'claude-falso-de-pago' -and $r.resultado.pago -eq $true)
  $r = Delegar normal @('-A', 'devin', '-Encargo', (Encargo-Md 'devin4.md'), '-Dir', $carpeta, '-Modelo', 'swe-2-no-listado')
  Caso 'devin: modelo fuera de modelos.devin y de pago.devin se rechaza' '3 con «no está en mesa.json»' "codigo=$($r.codigo), texto=$($r.texto.Trim())" ($r.codigo -eq 3 -and $r.texto -match 'no está en mesa.json')
  $r = Delegar cuota @('-A', 'codex', '-Encargo', (Encargo-Md 'cuatro.md'), '-Dir', $carpeta)
  $hasta = if ($r.resultado.hasta) { ([datetime]::Parse($r.resultado.hasta)).ToString('HH:mm') }
  Caso '«try again at 6:57 PM»' 'fallo, sin-cuota, hasta las 18:57' "codigo=$($r.codigo), estado=$($r.resultado.estado), causa=$($r.resultado.causa), hasta=$hasta" ($r.codigo -eq 1 -and $r.resultado.estado -eq 'fallo' -and $r.resultado.causa -eq 'sin-cuota' -and $hasta -eq '18:57')
  $r = Delegar normal @('-A', 'codex', '-Encargo', (Encargo-Md 'cinco.md'), '-Dir', $carpeta)
  Caso 'segundo intento sin cuota' 'NO LANZADO con 3 en menos de 3 s y sin arrancar el CLI' "codigo=$($r.codigo), segundos=$([int]$r.segundos), texto=$($r.texto.Trim())" ($r.codigo -eq 3 -and $r.segundos -lt 3 -and $r.texto -match 'NO LANZADO: codex sin cuota hasta 18:57' -and -not (Test-Path (Join-Path $r.carpeta 'argumentos.json')))
  # La señal de cuota caduca: se finge que ya pasó la hora.
  $ult = Get-ChildItem (Join-Path $datos 'trabajos') -Directory -Filter 'codex-cuatro-*' | Select-Object -Last 1
  $res = Mesa-LeerJson (Join-Path $ult.FullName 'resultado.json'); $res.hasta = (Get-Date).AddMinutes(-1).ToString('yyyy-MM-ddTHH:mm:sszzz'); Mesa-EscribirJson (Join-Path $ult.FullName 'resultado.json') $res
  $r = Delegar 503 @('-A', 'agy', '-Encargo', (Encargo-Md 'seis.md'), '-Dir', $carpeta)
  Caso '503 da red' 'fallo con causa red' "codigo=$($r.codigo), causa=$($r.resultado.causa)" ($r.codigo -eq 1 -and $r.resultado.causa -eq 'red')
  $r = Delegar 401 @('-A', 'codex', '-Encargo', (Encargo-Md 'siete.md'), '-Dir', $carpeta)
  Caso '401 da necesita-login' 'fallo con causa necesita-login' "codigo=$($r.codigo), causa=$($r.resultado.causa)" ($r.codigo -eq 1 -and $r.resultado.causa -eq 'necesita-login')

  # --- límite de uso: apagado por defecto; encendido rechaza al llegar al tope ---
  $cfgF = Join-Path $datos 'mesa.json'; $cfgTxt = [IO.File]::ReadAllText($cfgF, $utf8)
  [IO.File]::WriteAllText($cfgF, $cfgTxt.Substring(0, $cfgTxt.LastIndexOf('}')) + ',"limite_uso":{"activo":true,"horas":5,"encargos":{"devin":1},"tokens":{"codex":0}}}', $utf8)
  $r = Delegar normal @('-A', 'devin', '-Encargo', (Encargo-Md 'limite1.md'), '-Dir', $carpeta)
  $r0 = Delegar normal @('-A', 'codex', '-Encargo', (Encargo-Md 'limite2.md'), '-Dir', $carpeta)
  [IO.File]::WriteAllText($cfgF, $cfgTxt, $utf8)
  Caso 'límite de uso encendido' 'devin (tope 1 encargo en 5 h) sale 3; codex (tope 0 = sin tope) va' "devin=$($r.codigo) $($r.texto.Trim()); codex=$($r0.codigo)" ($r.codigo -eq 3 -and $r.texto -match 'devin llegó al límite de uso' -and $r0.codigo -eq 0)

  # --- rechazos ---
  $repo = Join-Path $casos 'repo'; $bare = Join-Path $casos 'remoto.git'
  & git init -q --bare $bare; & git init -q -b main $repo
  & git -C $repo -c user.name=p -c user.email=p@p config user.name p; & git -C $repo config user.email p@p
  [IO.File]::WriteAllText((Join-Path $repo 'README.md'), 'hola', $utf8); & git -C $repo add .; & git -C $repo commit -q -m inicial; & git -C $repo remote add origin $bare; & git -C $repo push -q origin main 2>&1 | Out-Null
  Remove-Item (Join-Path $bin 'agy.ps1')
  $r = Delegar normal @('-A', 'agy', '-Encargo', (Encargo-Md 'r1.md'), '-Dir', $repo)
  Caso 'CLI fuera del PATH' '3 en menos de 3 s' "codigo=$($r.codigo), segundos=$([int]$r.segundos), texto=$($r.texto.Trim())" ($r.codigo -eq 3 -and $r.segundos -lt 3 -and $r.texto -match 'NO LANZADO: agy no está en el PATH')
  [IO.File]::WriteAllText((Join-Path $bin 'agy.ps1'), $falso, $bom)
  $r = Delegar normal @('-A', 'codex', '-Encargo', (Encargo-Md 'r2.md'), '-Dir', (Join-Path $casos 'no-existe'))
  Caso 'carpeta inexistente' '3 en menos de 3 s' "codigo=$($r.codigo), segundos=$([int]$r.segundos), texto=$($r.texto.Trim())" ($r.codigo -eq 3 -and $r.segundos -lt 3 -and $r.texto -match 'no existe la carpeta')
  $r = Delegar normal @('-A', 'codex', '-Encargo', (Encargo-Md 'r3.md'), '-Dir', ($repo + '\$(x)'))
  Caso 'ruta con $(' '3 en menos de 3 s' "codigo=$($r.codigo), segundos=$([int]$r.segundos), texto=$($r.texto.Trim())" ($r.codigo -eq 3 -and $r.segundos -lt 3 -and $r.texto -match 'acento grave')
  $r = Delegar normal @('-A', 'codex', '-Encargo', (Encargo-Md 'r4.md'), '-Dir', $repo, '-Modelo', 'gemini-3-flash')
  Caso 'modelo inválido' '3 en menos de 3 s' "codigo=$($r.codigo), segundos=$([int]$r.segundos), texto=$($r.texto.Trim())" ($r.codigo -eq 3 -and $r.segundos -lt 3 -and $r.texto -match 'modelo gemini-3-flash no está')
  $excl = Join-Path $casos 'ZONA-PROHIBIDA-cosa'; New-Item -ItemType Directory -Force $excl | Out-Null
  $r = Delegar normal @('-A', 'codex', '-Encargo', (Encargo-Md 'r5.md'), '-Dir', $excl)
  Caso 'ruta excluida' '3' "codigo=$($r.codigo), texto=$($r.texto.Trim())" ($r.codigo -eq 3 -and $r.texto -match 'excluida')
  $r = Delegar normal @('-A', 'codex', '-Encargo', (Encargo-Md 'r6.md'), '-Dir', $casos)
  Caso 'carpeta con repos sin ser uno exige -Lectura' '3' "codigo=$($r.codigo), texto=$($r.texto.Trim())" ($r.codigo -eq 3 -and $r.texto -match 'pide -Lectura')
  Caso 'ningún rechazo creó worktree' 'sin .claude\worktrees en el repo' (Test-Path (Join-Path $repo '.claude\worktrees')) (-not (Test-Path (Join-Path $repo '.claude\worktrees')))

  # --- cortes --- (Continue: el stderr de powershell.exe y git en 5.1 se volvería excepción)
  $ErrorActionPreference = 'Continue'
  # --- puestos: la prueba da 2 por CLI ---
  $l1 = Lanzar arbol @('-A', 'codex', '-Encargo', (Encargo-Md 'ocupado.md'), '-Dir', $carpeta)
  $arbol = Arbol $l1
  $vivo = Resultado-Vivo codex
  $l1b = Lanzar arbol @('-A', 'codex', '-Encargo', (Encargo-Md 'ocupado-b.md'), '-Dir', $carpeta)
  $arbolB = Arbol $l1b
  Esperar { (Res-Vivos codex).Count -eq 2 }
  $vivoB = Res-Vivos codex | Where-Object id -ne $vivo.id
  $r = Delegar normal @('-A', 'codex', '-Encargo', (Encargo-Md 'ocupado2.md'), '-Dir', $carpeta)
  Caso 'puestos llenos' "3 con «codex con 2 de 2 puestos ocupados» y los dos ids" "codigo=$($r.codigo), texto=$($r.texto.Trim())" ($r.codigo -eq 3 -and $r.texto -match 'NO LANZADO: codex con 2 de 2 puestos ocupados' -and $r.texto -match [regex]::Escape($vivo.id) -and $r.texto -match [regex]::Escape($vivoB.id))
  $r = Delegar normal @('-A', 'codex', '-Encargo', (Encargo-Md 'otra-cosa.md'), '-Dir', $carpeta, '-Tarea', 'ocupado')
  Caso 'la misma tarea viva no se pisa' '3 con «ya está viva»' "codigo=$($r.codigo), texto=$($r.texto.Trim())" ($r.codigo -eq 3 -and $r.texto -match 'ya está viva')
  $estado = Estado
  Caso 'estado con varios' 'ChatGPT (codex): 2 de 2 ocupados con los dos ids; Gemini libre' ($estado.Trim() -replace "`r?`n", ' | ') ($estado -match 'ChatGPT \(codex\): 2 de 2 ocupados: ' -and $estado -match [regex]::Escape($vivo.id) -and $estado -match [regex]::Escape($vivoB.id) -and $estado -match 'Gemini \(agy\): 0 de 2 ocupados \(libre\)' -and $estado -match 'uso en 5 h: \d+ encargos.*; en 7 d: \d+ encargos')
  Stop-Process -Id $l1b.proceso.Id -Force
  Esperar { (Vivos $arbolB) -eq 0 } 10
  $r = Delegar normal @('-A', 'codex', '-Encargo', (Encargo-Md 'tras-morir.md'), '-Dir', $carpeta)
  Caso 'puesto liberado al morir el proceso' 'salida 0 en el puesto 2 con el otro aún vivo' "codigo=$($r.codigo), puesto=$($r.resultado.puesto), texto=$($r.texto.Trim() -split "`n" | Select-Object -First 1)" ($r.codigo -eq 0 -and $r.resultado.puesto -eq 2)
  $corte = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$h\cuadrilla.ps1" cortar $vivo.id 2>&1 | Out-String
  $r = Terminar $l1
  Esperar { (Vivos $arbol) -eq 0 } 10
  $res = Mesa-LeerJson (Join-Path $datos "trabajos\$($vivo.id)\resultado.json")
  Caso 'cortar mata el árbol' 'CORTADO, interrumpido/cortado y 0 descendientes' "$($corte.Trim()); estado=$($res.estado), causa=$($res.causa), vivos=$(Vivos $arbol)" ($corte -match 'CORTADO' -and $res.estado -eq 'interrumpido' -and $res.causa -eq 'cortado' -and (Vivos $arbol) -eq 0)

  $l2 = Lanzar mudo @('-A', 'agy', '-Encargo', (Encargo-Md 'mudo.md'), '-Dir', $carpeta)
  $arbol = Arbol $l2
  $r = Terminar $l2
  Caso 'falso mudo queda colgado' '124, colgado, 0 descendientes' "codigo=$($r.codigo), estado=$($r.resultado.estado), causa=$($r.resultado.causa), vivos=$(Vivos $arbol)" ($r.codigo -eq 124 -and $r.resultado.estado -eq 'colgado' -and $r.resultado.causa -eq 'colgado' -and (Vivos $arbol) -eq 0)

  $md = Encargo-Md 'matado.md'
  $l3 = Lanzar arbol @('-A', 'codex', '-Encargo', $md, '-Dir', $carpeta)
  $arbol = Arbol $l3; $vivo = Resultado-Vivo codex
  Stop-Process -Id $l3.proceso.Id -Force
  Esperar { (Vivos $arbol) -eq 0 } 10
  $estado = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$h\cuadrilla.ps1" estado 2>&1 | Out-String
  $res = Mesa-LeerJson (Join-Path $datos "trabajos\$($vivo.id)\resultado.json")
  Caso 'lanzador matado' 'estado lo marca interrumpido y 0 descendientes' "estado=$($res.estado), vivos=$(Vivos $arbol)" ($res.estado -eq 'interrumpido' -and (Vivos $arbol) -eq 0 -and $estado -match 'interrumpido')
  $r = Delegar normal @('-A', 'codex', '-Encargo', $md, '-Dir', $carpeta)
  $entrada = [IO.File]::ReadAllText((Join-Path $r.carpeta 'entrada.txt'), $utf8)
  Caso 'reintento con cabecera REINTENTO' "REINTENTO: el intento $($vivo.id) terminó interrumpido" "codigo=$($r.codigo); $(($entrada -split "`n" | Where-Object { $_ -like 'REINTENTO*' }) -join '')" ($r.codigo -eq 0 -and $entrada -match "REINTENTO: el intento $([regex]::Escape($vivo.id)) terminó interrumpido")

  # --- carrera al tomar puestos: cuatro a la vez con dos puestos ---
  $carr = @(1..4 | ForEach-Object { Lanzar lento @('-A', 'agy', '-Encargo', (Encargo-Md "carrera-$_.md"), '-Dir', $carpeta) })
  $rcarr = @($carr | ForEach-Object { Terminar $_ })
  $dentro = @($rcarr | Where-Object codigo -eq 0); $fuera = @($rcarr | Where-Object { $_.codigo -eq 3 -and $_.texto -match 'agy con 2 de 2 puestos ocupados' })
  Caso 'carrera al tomar puestos' 'de 4 lanzados a la vez, 2 entran (puestos 1 y 2) y 2 salen con «2 de 2 puestos ocupados»' "codigos=$(@($rcarr | ForEach-Object codigo) -join ','), puestos=$(@($dentro | ForEach-Object { $_.resultado.puesto }) -join ',')" ($dentro.Count -eq 2 -and $fuera.Count -eq 2 -and (@($dentro | ForEach-Object { $_.resultado.puesto } | Sort-Object) -join ',') -eq '1,2')

  # --- sin cuota con varios puestos: manda el último que terminó, no el último lanzado ---
  $lc = Lanzar cuota-lento @('-A', 'codex', '-Encargo', (Encargo-Md 'cuota-lenta.md'), '-Dir', $carpeta)
  Esperar { (Res-Vivos codex | Where-Object tarea -eq 'cuota-lenta') -or $lc.proceso.HasExited }
  $la = Lanzar arbol @('-A', 'codex', '-Encargo', (Encargo-Md 'largo.md'), '-Dir', $carpeta)
  $arbolA = Arbol $la
  $rc = Terminar $lc
  $r = Delegar normal @('-A', 'codex', '-Encargo', (Encargo-Md 'tras-cuota.md'), '-Dir', $carpeta)
  $estado = Estado
  $regCodex = Join-Path $datos 'trabajos\cuota-codex.txt'
  Caso 'sin cuota bloquea los puestos libres' 'el lento acaba sin-cuota; con otro vivo lanzado después, el siguiente sale 3; estado y cuota-codex.txt lo anotan' "lento: $(($rc.texto -split "`n" | Select-Object -First 1).Trim()) $($rc.error.Trim()); cuota=$($rc.resultado.causa), codigo=$($r.codigo), texto=$($r.texto.Trim()); estado=$(($estado -split "`n" | Select-Object -First 1).Trim())" ($rc.resultado.causa -eq 'sin-cuota' -and $r.codigo -eq 3 -and $r.texto -match 'codex sin cuota hasta 18:57' -and $estado -match 'ChatGPT \(codex\): 1 de 2 ocupados: .*sin cuota hasta 18:57' -and (Test-Path $regCodex) -and ([IO.File]::ReadAllText($regCodex) -match [regex]::Escape($rc.resultado.id)))
  & powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$h\cuadrilla.ps1" cortar (Res-Vivos codex | Select-Object -First 1).id 2>&1 | Out-Null
  Terminar $la | Out-Null
  $f = Join-Path $datos "trabajos\$($rc.resultado.id)\resultado.json"; $res = Mesa-LeerJson $f; $res.hasta = (Get-Date).AddMinutes(-1).ToString('yyyy-MM-ddTHH:mm:sszzz'); Mesa-EscribirJson $f $res

  # --- git ---
  $r = Delegar git @('-A', 'codex', '-Encargo', (Encargo-Md 'encargo-codex-hdr.md' "Objetivo: toca $repo\README.md y $repo\no-existe.txt."), '-Dir', $repo, '-Sandbox')
  $g = Mesa-LeerJson (Join-Path $r.carpeta 'git.json')
  $wt = $r.resultado.worktree
  Caso 'encargo-codex-hdr.md da codex-hdr' "worktree ...\codex-hdr, rama codex/hdr, cwd en el worktree" "wt=$wt, rama=$($r.resultado.rama), cwd=$([IO.File]::ReadAllText((Join-Path $r.carpeta 'cwd.txt')))" ($wt -like '*\.claude\worktrees\codex-hdr' -and $r.resultado.rama -eq 'codex/hdr' -and [IO.File]::ReadAllText((Join-Path $r.carpeta 'cwd.txt')).TrimEnd('\') -eq $wt)
  $entrada = [IO.File]::ReadAllText((Join-Path $r.carpeta 'entrada.txt'), $utf8)
  Caso 'rutas del repo apuntan al worktree' 'README.md al worktree; no-existe.txt sigue en el repo' ($entrada -split "`n" | Select-Object -Last 1) ($entrada -like "*$wt\README.md*" -and $entrada -like "*$repo\no-existe.txt*")
  $argsCodex = @(Mesa-LeerJson (Join-Path $r.carpeta 'argumentos.json'))
  Caso 'codex -Sandbox: limitado al worktree y sin red' '-C <wt> -s workspace-write, sin network_access ni --add-dir general' ($argsCodex -join ' ') ($argsCodex -contains $wt -and $argsCodex -contains 'workspace-write' -and ($argsCodex -join ' ') -notmatch 'network_access' -and $argsCodex -notcontains '--add-dir')
  $headWt = & git -C $wt rev-parse HEAD; $headRepo = & git -C $repo rev-parse HEAD; $remoto = & git -C $bare rev-parse main
  Caso 'commit, push y stash fallan en el CLI' 'los tres con error; HEAD y remoto intactos; salida 0 sin avisos' "commit=$($g.commit), push=$($g.push), stash=$($g.stash), codigo=$($r.codigo), avisos=$($r.resultado.avisos -join ';'); $($g.salida -replace "`n", ' | ')" ($g.commit -ne 0 -and $g.push -ne 0 -and $g.stash -ne 0 -and $headWt -eq $headRepo -and $remoto -eq $headRepo -and $r.codigo -eq 0 -and @($r.resultado.avisos).Count -eq 0)
  $r2 = Delegar normal @('-A', 'codex', '-Encargo', (Join-Path $casos 'encargo-codex-hdr.md'), '-Dir', $repo)
  Caso 'el mismo .md ya hecho se rechaza' '3 con «ya se hizo»' "codigo=$($r2.codigo), texto=$($r2.texto.Trim())" ($r2.codigo -eq 3 -and $r2.texto -match 'ya se hizo')
  $r3 = Delegar normal @('-A', 'codex', '-Encargo', (Encargo-Md 'hdr-correccion.md' 'Objetivo: corrige.'), '-Dir', $repo, '-Tarea', 'hdr')
  Caso '-Tarea corrige en el mismo worktree' 'salida 0 y el mismo worktree' "codigo=$($r3.codigo), wt=$($r3.resultado.worktree)" ($r3.codigo -eq 0 -and $r3.resultado.worktree -eq $wt)
  $candado = [IO.File]::Open((Join-Path $datos 'trabajos\codex.2.lock'), 'OpenOrCreate', 'ReadWrite', 'None')
  try { $limpiar1 = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$h\worktrees.ps1" limpiar 2>&1 | Out-String } finally { $candado.Dispose() }
  $limpiar2 = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$h\worktrees.ps1" limpiar 2>&1 | Out-String
  Caso 'limpiar respeta el worktree con candado' 'con candado se queda; sin candado se quita (integrado y limpio)' "con=$($limpiar1.Trim()); sin=$($limpiar2.Trim())" ($limpiar1 -match 'Se queda \(codex tiene un encargo en marcha\)' -and $limpiar2 -match 'Quitado' -and -not (Test-Path $wt))
  New-Item -ItemType Directory -Force (Join-Path $repo '.claude\worktrees\codex-medio') | Out-Null
  $r = Delegar normal @('-A', 'codex', '-Encargo', (Encargo-Md 'medio.md'), '-Dir', $repo)
  Caso 'carpeta de worktree a medias (sin .git) no se reutiliza' '3 con «quedó a medias»' "codigo=$($r.codigo), texto=$($r.texto.Trim())" ($r.codigo -eq 3 -and $r.texto -match 'quedó a medias')
  Remove-Item -LiteralPath (Join-Path $repo '.claude\worktrees\codex-medio') -Recurse -Force
  # -Dir en un worktree de otra rama: el encargo parte de esa rama, no de main (15-nov: codex arrancó sobre main sin el trabajo).
  $otra = Join-Path $raiz 'repo-otra-rama'
  & git -C $repo worktree add --quiet -b trabajo/rama $otra 2>$null | Out-Null
  [IO.File]::WriteAllText((Join-Path $otra 'solo-en-la-rama.txt'), 'x', $utf8)
  & git -C $otra add solo-en-la-rama.txt 2>$null | Out-Null; & git -C $otra -c user.name=prueba -c user.email=prueba@ejemplo.invalid commit --quiet -m rama 2>$null | Out-Null
  $r = Delegar normal @('-A', 'agy', '-Encargo', (Encargo-Md 'sobre-rama.md'), '-Dir', $otra)
  $wtRama = $r.resultado.worktree
  Caso '-Dir en otra rama: el worktree parte de ella' 'el worktree trae solo-en-la-rama.txt' "codigo=$($r.codigo), wt=$wtRama" ($r.codigo -eq 0 -and $wtRama -and (Test-Path (Join-Path $wtRama 'solo-en-la-rama.txt')))
  Caso '-Dir es un worktree: el del CLI va en la raíz del repo principal' "$repo\.claude\worktrees\agy-sobre-rama, nada anidado en -Dir" "wt=$wtRama, anidado=$(Test-Path (Join-Path $otra '.claude'))" ($wtRama -eq (Join-Path $repo '.claude\worktrees\agy-sobre-rama') -and -not (Test-Path (Join-Path $otra '.claude')))
  $r = Delegar normal @('-A', 'agy', '-Encargo', (Encargo-Md 'otra-desde-main.md'), '-Dir', $repo, '-Tarea', 'sobre-rama')
  Caso 'la misma tarea desde otro -Dir no reutiliza ese worktree' '3 con «ya es de un encargo lanzado desde»' "codigo=$($r.codigo), texto=$($r.texto.Trim())" ($r.codigo -eq 3 -and $r.texto -match 'el worktree agy-sobre-rama ya es de un encargo lanzado desde')

  # --- dos encargos del mismo CLI a la vez sobre el mismo repo ---
  $d1 = Lanzar lento @('-A', 'devin', '-Encargo', (Encargo-Md 'iso-a.md'), '-Dir', $repo)
  $d2 = Lanzar lento @('-A', 'devin', '-Encargo', (Encargo-Md 'iso-b.md'), '-Dir', $repo)
  $ra = Terminar $d1; $rb = Terminar $d2
  $fa = Join-Path $datos "trabajos\$($ra.resultado.id)\final.txt"; $fb = Join-Path $datos "trabajos\$($rb.resultado.id)\final.txt"
  $ta = if (Test-Path $fa) { [IO.File]::ReadAllText($fa, $utf8) } else { '' }; $tb = if (Test-Path $fb) { [IO.File]::ReadAllText($fb, $utf8) } else { '' }
  $aLaVez = $ra.resultado -and $rb.resultado -and [datetime]::Parse($ra.resultado.inicio) -le [datetime]::Parse($rb.resultado.fin) -and [datetime]::Parse($rb.resultado.inicio) -le [datetime]::Parse($ra.resultado.fin)
  Caso 'dos devin a la vez sin pisarse' 'los dos salen 0, a la vez, en puestos, worktrees y final.txt propios' "a=$($ra.codigo) $($ra.resultado.worktree) p$($ra.resultado.puesto); b=$($rb.codigo) $($rb.resultado.worktree) p$($rb.resultado.puesto); a la vez=$aLaVez $($ra.error)$($rb.error)" ($ra.codigo -eq 0 -and $rb.codigo -eq 0 -and $aLaVez -and $ra.resultado.puesto -ne $rb.resultado.puesto -and $ra.resultado.worktree -ne $rb.resultado.worktree -and $ta -match [regex]::Escape("cwd=$($ra.resultado.worktree)") -and $tb -match [regex]::Escape("cwd=$($rb.resultado.worktree)") -and $ta -notmatch [regex]::Escape($rb.resultado.worktree))
  $usoIds = @([IO.File]::ReadAllLines($usoF, $utf8) | Where-Object { $_ } | ForEach-Object { ($_ | ConvertFrom-Json).id })
  Caso 'registro de uso con dos escritores' 'uso.jsonl tiene una línea válida por cada uno de los dos devin' "a=$(@($usoIds -eq $ra.resultado.id).Count), b=$(@($usoIds -eq $rb.resultado.id).Count), líneas=$($usoIds.Count)" (@($usoIds -eq $ra.resultado.id).Count -eq 1 -and @($usoIds -eq $rb.resultado.id).Count -eq 1 -and [IO.File]::ReadAllText($usoF) -notmatch '\{\}')
  $listaJson = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$h\worktrees.ps1" lista -Json 2>$null | Out-String
  $devinWts = @(($listaJson | ConvertFrom-Json) | Where-Object agente -eq 'devin')
  Caso 'worktrees.ps1 lista cuenta uno por encargo' '2 worktrees de devin' "$($devinWts.Count): $(@($devinWts | ForEach-Object rama) -join ', ')" ($devinWts.Count -eq 2)

  # --- lectura ---
  New-Item -ItemType Directory -Force (Join-Path $repo '.entorno') | Out-Null
  $antes = & git -C $repo status --porcelain | Out-String
  $r = Delegar normal @('-A', 'codex', '-Encargo', (Encargo-Md 'lee.md'), '-Dir', $repo, '-Lectura')
  $argsCodex = @(Mesa-LeerJson (Join-Path $r.carpeta 'argumentos.json'))
  Caso '-Lectura: read-only, sin worktree ni --add-dir' 'salida 0, -s read-only, cwd el repo, sin worktree, sin --add-dir aunque exista .entorno' "codigo=$($r.codigo), wt=$($r.resultado.worktree), args=$($argsCodex -join ' ')" ($r.codigo -eq 0 -and -not $r.resultado.worktree -and $argsCodex -contains 'read-only' -and $argsCodex -notcontains '--add-dir' -and -not (Test-Path (Join-Path $repo '.claude\worktrees\codex-*')) -and ((& git -C $repo status --porcelain | Out-String) -eq $antes))
  $r = Delegar normal @('-A', 'agy', '-Encargo', (Encargo-Md 'lee2.md'), '-Dir', $repo, '-Lectura')
  $argsAgy = @(Mesa-LeerJson (Join-Path $r.carpeta 'argumentos.json'))
  Caso 'agy -Lectura va en plan' '--mode plan' ($argsAgy -join ' ') ($r.codigo -eq 0 -and $argsAgy -contains 'plan')
  $pt = [regex]::Match(($argsAgy -join ' '), 'UTF-8 (.+?prompt\.txt)').Groups[1].Value
  Caso '-Lectura deja leer lo que el encargo nombra fuera de -Dir' 'prompt.txt lo permite' $pt ([bool]($pt -and (Test-Path -LiteralPath $pt) -and ([IO.File]::ReadAllText($pt) -match 'que el encargo nombre por ruta absoluta')))
  Caso 'agy -Lectura puede leer prompt.txt' '--add-dir <carpeta del trabajo>' ($argsAgy -join ' ') ([Array]::IndexOf($argsAgy, '--add-dir') -ge 0 -and $argsAgy[[Array]::IndexOf($argsAgy, '--add-dir') + 1] -like '*trabajos*')
  $r = Delegar normal @('-A', 'agy', '-Encargo', (Join-Path $casos 'lee2.md'), '-Dir', $repo, '-Lectura')
  Caso 'el mismo .md ya hecho se repite con -Lectura' 'salida 0 (no hay worktree que proteger)' "codigo=$($r.codigo), texto=$($r.texto.Trim())" ($r.codigo -eq 0)
  $r = Delegar normal @('-A', 'codex', '-Encargo', (Join-Path $casos 'lee.md'), '-Dir', ((Split-Path -Qualifier $repo) + ''), '-Lectura')
  Caso 'una raíz de unidad como -Dir se rechaza' '3 con «raíz de unidad»' "codigo=$($r.codigo), texto=$($r.texto.Trim())" ($r.codigo -eq 3 -and $r.texto -match 'raíz de unidad')
  # Mesa-EscribirJson con otro lector abierto (como ReadAllText de estado): File.Replace reintenta en vez de morir.
  $js = Join-Path $casos 'ocupado.json'; Mesa-EscribirJson $js @{ n = 1 }
  # Otro proceso lo abre con FileShare.Read, avisa con un marcador y lo suelta 120 ms después.
  $marca = "$js.abierto"; $lector = Start-Process powershell.exe -ArgumentList @('-NoProfile', '-Command', "`$f = [IO.File]::Open('$js', 'Open', 'Read', 'Read'); [IO.File]::WriteAllText('$marca', '1'); Start-Sleep -Milliseconds 120; `$f.Dispose()") -WindowStyle Hidden -PassThru
  Esperar { Test-Path -LiteralPath $marca }
  $err = $null; try { Mesa-EscribirJson $js @{ n = 2 } } catch { $err = $_.Exception.Message }; $lector.WaitForExit()
  Caso 'EscribirJson reintenta Replace con el archivo abierto' 'sin error y n=2' "err=$err, n=$((Mesa-LeerJson $js).n)" (-not $err -and (Mesa-LeerJson $js).n -eq 2)
  # Registro de cuota con escritores concurrentes: 4 procesos x 50 líneas, ninguna perdida.
  $reg = Join-Path $casos 'registro.txt'
  $esc = @(1..4 | ForEach-Object { Start-Process powershell.exe -ArgumentList @('-NoProfile', '-Command', ". '$h\comun.ps1'; foreach (`$i in 1..50) { Mesa-Anotar '$reg' ('p$_-' + `$i) }") -WindowStyle Hidden -PassThru })
  foreach ($p in $esc) { [void]$p.WaitForExit(60000) }
  $lineas = @([IO.File]::ReadAllLines($reg) | Where-Object { $_ })
  Caso 'Mesa-Anotar aguanta escritores concurrentes' '200 líneas distintas' "$($lineas.Count) líneas, $(@($lineas | Sort-Object -Unique).Count) distintas" ($lineas.Count -eq 200 -and @($lineas | Sort-Object -Unique).Count -eq 200)

  # --- instalar normaliza un mesa.json de la v1 ---
  Copy-Item -LiteralPath (Join-Path $base 'herramientas\instalar.ps1') -Destination $h
  New-Item -ItemType Directory -Force (Join-Path $raiz 'datos') | Out-Null
  Copy-Item -LiteralPath (Join-Path $base 'datos\mesa.ejemplo.json') -Destination (Join-Path $raiz 'datos')
  $datosV1 = Join-Path $raiz 'datos-v1'; New-Item -ItemType Directory -Force $datosV1 | Out-Null
  [IO.File]::WriteAllText((Join-Path $datosV1 'mesa.json'), '{"topes":{"codex":{"hora":4}},"supervisor":{"relanzar":false},"modelos":{"codex":["mio"],"agy":["mio2"],"claude":["x"]},"limites":{"encargo_min":45,"charla_min":20},"worktrees":{"max_por_agente":2}}', $utf8)
  $env:MESA_DATOS = $datosV1
  $salidaInst = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$h\instalar.ps1" 2>&1 | Out-String
  $env:MESA_DATOS = $datos
  $n = Mesa-LeerJson (Join-Path $datosV1 'mesa.json')
  Caso 'instalar normaliza mesa.json' 'solo las claves del ejemplo (y sus subclaves), con puestos, niveles, pago y el límite de uso apagado; conserva lo propio; añade inactivo_min=20; copia en mesa.v1.json' "claves=$($n.PSObject.Properties.Name -join ','), codex=$($n.modelos.codex), encargo=$($n.limites.encargo_min), inactivo=$($n.limites.inactivo_min), max=$($n.worktrees.max_por_agente); $($salidaInst.Trim())" (($n.PSObject.Properties.Name -join ',') -eq 'modelos,pago,rutas_equivalentes,niveles,precios,limites,limite_uso,worktrees,puestos' -and $n.limite_uso.activo -eq $false -and $n.niveles.alto.codex.modelo -eq 'gpt-6-astra' -and $n.puestos.devin -eq 4 -and $n.puestos.codex -eq 3 -and ($n.modelos.PSObject.Properties.Name -join ',') -eq 'codex,agy,devin' -and ($n.limites.PSObject.Properties.Name -join ',') -eq 'encargo_min,inactivo_min' -and $n.modelos.codex -eq 'mio' -and $n.limites.encargo_min -eq 45 -and $n.limites.inactivo_min -eq 20 -and $n.worktrees.max_por_agente -eq 2 -and (Test-Path (Join-Path $datosV1 'mesa.v1.json')) -and $salidaInst -match 'Normalizado')
} catch {
  $script:fallos++; Write-Host "ERROR de la prueba: $($_.Exception.Message) $($_.InvocationInfo.PositionMessage)"
} finally {
  foreach ($p in $lanzados) { if (-not $p.HasExited) { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue } }
  foreach ($clave in $guardado.Keys) { [Environment]::SetEnvironmentVariable($clave, $guardado[$clave], 'Process') }
  if ($Conservar) { Write-Host "Copia conservada en $raiz" }
  else {
    $destino = [IO.Path]::GetFullPath($raiz)
    if ($destino.StartsWith([IO.Path]::GetFullPath($env:TEMP).TrimEnd('\') + '\mesa-cuadrilla-', [StringComparison]::OrdinalIgnoreCase)) { Start-Sleep -Milliseconds 500; Remove-Item -LiteralPath $destino -Recurse -Force -ErrorAction SilentlyContinue }
  }
}
Write-Host "`nFallos: $script:fallos"
exit $script:fallos
