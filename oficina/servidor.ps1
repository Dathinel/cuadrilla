# Servidor de la Oficina Estrella: solo lectura, solo 127.0.0.1. Sirve el cliente y /api/estado.
# Se cierra solo tras 120 s sin clientes (el navegador renueva su presencia pidiendo el estado)
# o 90 s si nadie abre la página. Ctrl+C o cerrar la consola lo paran por el finally.
param([int]$Puerto = 8765)
. (Join-Path $PSScriptRoot 'estado.ps1')

$listener = [Net.HttpListener]::new()
$listener.Prefixes.Add("http://127.0.0.1:$Puerto/")
try { $listener.Start() } catch {
  Write-Host "No se pudo abrir http://127.0.0.1:$Puerto/ — ¿ya hay una Oficina abierta u otro programa usa el puerto? $($_.Exception.Message)"
  exit 1
}
Write-Host "Oficina Estrella en http://127.0.0.1:$Puerto/ — ábrela en el navegador. Ctrl+C para cerrar."
Write-Host "Se cerrará sola tras 2 minutos sin clientes."

$permitidos = @{ '/' = 'index.html'; '/index.html' = 'index.html'; '/oficina.js' = 'oficina.js'; '/oficina.css' = 'oficina.css'; '/arte-v1.js' = 'arte-v1.js' }
$tipos = @{ '.html' = 'text/html; charset=utf-8'; '.js' = 'application/javascript; charset=utf-8'; '.css' = 'text/css; charset=utf-8' }

$inicio = Get-Date
$ultimaVisita = $inicio
$vistoCliente = $false
$cacheEstado = $null; $cacheJson = $null; $cacheEn = [datetime]::MinValue

try {
  while ($listener.IsListening) {
    $tarea = $listener.GetContextAsync()
    while (-not $tarea.Wait(500)) {
      $ahora = Get-Date
      $sinCliente = if ($vistoCliente) { ($ahora - $ultimaVisita).TotalSeconds -gt 120 } else { ($ahora - $inicio).TotalSeconds -gt 90 }
      if ($sinCliente) { Write-Host 'Sin clientes: cerrando.'; $listener.Stop(); break }
    }
    if (-not $listener.IsListening) { break }
    if (-not $tarea.IsCompleted) { continue }
    $ctx = $tarea.Result
    $req = $ctx.Request; $res = $ctx.Response
    $ultimaVisita = Get-Date; $vistoCliente = $true
    $cuerpo = ''; $tipo = 'text/plain; charset=utf-8'
    try {
      $path = $req.Url.AbsolutePath.TrimEnd('/')
      if ($path -eq '') { $path = '/' }
      if ($req.HttpMethod -ne 'GET') {
        $res.StatusCode = 405; $cuerpo = 'Solo lectura'
      } elseif ($req.Headers['Host'] -notmatch "^(?:127\.0\.0\.1|localhost):$Puerto$") {
        # Sin el Host correcto puede ser rebinding DNS (un dominio apuntando a 127.0.0.1 leería el JSON).
        $res.StatusCode = 403; $cuerpo = 'Host no permitido'
      } elseif ($permitidos.ContainsKey($path)) {
        $cuerpo = [IO.File]::ReadAllText((Join-Path $PSScriptRoot $permitidos[$path]), [Text.Encoding]::UTF8)
        $tipo = $tipos[[IO.Path]::GetExtension($permitidos[$path])]
      } elseif ($path -eq '/api/estado') {
        $ahora = Get-Date
        if (-not $cacheJson -or ($ahora - $cacheEn).TotalSeconds -gt 3) {
          $cacheJson = (Obtener-OficinaEstado) | ConvertTo-Json -Depth 12 -Compress
          $cacheEn = $ahora
        }
        $cuerpo = $cacheJson; $tipo = 'application/json; charset=utf-8'
      } elseif ($path -eq '/api/ping') {
        $cuerpo = '{"ok":true}'; $tipo = 'application/json; charset=utf-8'
      } else {
        $res.StatusCode = 404; $cuerpo = 'No encontrado'
      }
    } catch {
      $res.StatusCode = 500; $cuerpo = '{"error":"No se pudo leer el estado"}'; $tipo = 'application/json; charset=utf-8'
      Write-Warning (Mesa-Ocultar $_.Exception.Message)
    }
    $bytes = [Text.Encoding]::UTF8.GetBytes($cuerpo)
    $res.ContentType = $tipo
    $res.ContentLength64 = $bytes.Length
    $res.Headers['Cache-Control'] = 'no-store'
    $res.Headers['X-Content-Type-Options'] = 'nosniff'
    $res.Headers['Content-Security-Policy'] = "default-src 'self'; style-src 'self' 'unsafe-inline'; script-src 'self'; connect-src 'self'; img-src 'self' data:; frame-ancestors 'none'; form-action 'none'; base-uri 'none'"
    try { $res.OutputStream.Write($bytes, 0, $bytes.Length); $res.OutputStream.Close() } catch {}
  }
} finally {
  try { $listener.Stop() } catch {}
  $listener.Close()
}
