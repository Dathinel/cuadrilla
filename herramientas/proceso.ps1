# Los callbacks nativos no tienen runspace: encolan las líneas y la consola las pinta desde PowerShell.
if (-not ('Mesa.Proceso' -as [type])) {
  Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Text;
using System.Diagnostics;
using System.Collections.Concurrent;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Threading;
using System.Threading.Tasks;

namespace Mesa {
  public sealed class Proceso : IDisposable {
    [StructLayout(LayoutKind.Sequential)] struct Limites {
      public long TiempoProceso, TiempoJob;
      public uint Banderas;
      public UIntPtr Minimo, Maximo;
      public uint Procesos;
      public UIntPtr Afinidad;
      public uint Prioridad, Planificacion;
    }
    [StructLayout(LayoutKind.Sequential)] struct Contadores {
      public ulong Lecturas, Escrituras, Otros, BytesLectura, BytesEscritura, BytesOtros;
    }
    [StructLayout(LayoutKind.Sequential)] struct LimitesExtendidos {
      public Limites Basicos;
      public Contadores IO;
      public UIntPtr MemoriaProceso, MemoriaJob, PicoProceso, PicoJob;
    }
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern IntPtr CreateJobObject(IntPtr seguridad, string nombre);
    [DllImport("kernel32.dll", SetLastError=true)] static extern bool SetInformationJobObject(IntPtr job, int clase, ref LimitesExtendidos info, uint tamano);
    [DllImport("kernel32.dll", SetLastError=true)] static extern bool AssignProcessToJobObject(IntPtr job, IntPtr proceso);
    [DllImport("kernel32.dll", SetLastError=true)] static extern bool TerminateJobObject(IntPtr job, uint codigo);
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr handle);
    readonly Process proceso = new Process();
    readonly object cerrojo = new object();
    readonly ConcurrentQueue<string> lineas = new ConcurrentQueue<string>();
    readonly ManualResetEvent salidaFin = new ManualResetEvent(false), errorFin = new ManualResetEvent(false);
    StreamWriter log;
    IntPtr job;
    Task entrada;
    bool ver, cerrado;
    public bool EntradaAbierta;
    string fallo;
    public int Id { get; private set; }
    public string Inicio { get; private set; }
    public string Nombre { get; private set; }
    public bool Terminado { get { return proceso.HasExited; } }
    public int Codigo { get { return proceso.ExitCode; } }
    public string Fallo { get { return fallo; } }
    public DateTime UltimaLinea { get; private set; }

    public static string Citar(string valor) {
      StringBuilder s = new StringBuilder("\"");
      int barras = 0;
      foreach (char c in valor) {
        if (c == '\\') { barras++; continue; }
        if (c == '"') { s.Append('\\', barras * 2 + 1); s.Append(c); }
        else { s.Append('\\', barras); s.Append(c); }
        barras = 0;
      }
      s.Append('\\', barras * 2); s.Append('"'); return s.ToString();
    }
    // Los mismos patrones de Mesa-Ocultar: un secreto impreso por el CLI no debe quedar en log.jsonl.
    static readonly System.Text.RegularExpressions.Regex[] filtrosSecreto = new[] {
      new System.Text.RegularExpressions.Regex(@"(?i)(?:ghp_|github_pat_|sk-|AIza)[A-Za-z0-9_\-]+"),
      new System.Text.RegularExpressions.Regex(@"(?i)(Bearer\s+)[^\s""';,}]+"),
      new System.Text.RegularExpressions.Regex(@"(?i)(X-[\w-]*Token\s*[=:]\s*)[^\s""';,}]+"),
      new System.Text.RegularExpressions.Regex(@"(?i)((?:api[_-]?key|password|secret|access[_-]?token)\s*[=:]\s*[""']?)[^\s""';,}]+"),
    };
    System.Text.RegularExpressions.Regex filtroRutas;
    string Ocultar(string linea) {
      string s = linea;
      s = filtrosSecreto[0].Replace(s, "<OCULTO>");
      s = filtrosSecreto[1].Replace(s, "$1<OCULTO>");
      s = filtrosSecreto[2].Replace(s, "$1<OCULTO>");
      s = filtrosSecreto[3].Replace(s, "$1<OCULTO>");
      if (filtroRutas != null) s = filtroRutas.Replace(s, "<RUTA EXCLUIDA>");
      return s;
    }
    void Guardar(string linea) {
      if (linea == null) return;
      linea = Ocultar(linea);
      lock (cerrojo) {
        if (cerrado) return;
        try { log.WriteLine(linea); UltimaLinea = DateTime.UtcNow; if (ver) lineas.Enqueue(linea); }
        catch (Exception e) { fallo = e.Message; }
      }
    }
    public string Siguiente() { string linea; return lineas.TryDequeue(out linea) ? linea : null; }
    public void Iniciar(string ejecutable, string argumentos, string directorio, string archivoLog, string texto, bool mostrar, string rutasExcluidas) {
      if (!string.IsNullOrEmpty(rutasExcluidas)) filtroRutas = new System.Text.RegularExpressions.Regex(rutasExcluidas + @"[^\s""']*");
      ver = mostrar;
      log = new StreamWriter(archivoLog, false, new UTF8Encoding(false)); log.AutoFlush = true;
      job = CreateJobObject(IntPtr.Zero, null);
      if (job == IntPtr.Zero) throw new Win32Exception();
      var limites = new LimitesExtendidos(); limites.Basicos.Banderas = 0x2000; // KILL_ON_JOB_CLOSE mata todo el árbol al cerrar el Job.
      if (!SetInformationJobObject(job, 9, ref limites, (uint)Marshal.SizeOf(limites))) throw new Win32Exception();
      var info = new ProcessStartInfo(ejecutable, argumentos);
      info.WorkingDirectory = directorio; info.UseShellExecute = false; info.CreateNoWindow = true;
      info.RedirectStandardInput = true; info.RedirectStandardOutput = true; info.RedirectStandardError = true;
      info.StandardOutputEncoding = new UTF8Encoding(false); info.StandardErrorEncoding = new UTF8Encoding(false);
      proceso.StartInfo = info;
      UltimaLinea = DateTime.UtcNow;
      proceso.OutputDataReceived += (s,e) => { if (e.Data == null) salidaFin.Set(); else Guardar(e.Data); };
      proceso.ErrorDataReceived += (s,e) => { if (e.Data == null) errorFin.Set(); else Guardar(e.Data); };
      proceso.Start();
      proceso.BeginOutputReadLine(); proceso.BeginErrorReadLine();
      Id = proceso.Id;
      // Un CLI puede morir antes de consultar sus metadatos. Su salida ya se está leyendo.
      try { Inicio = proceso.StartTime.ToUniversalTime().ToString("o"); } catch (InvalidOperationException) {} catch (Win32Exception) {}
      try { Nombre = proceso.ProcessName; } catch (InvalidOperationException) {} catch (Win32Exception) {}
      if (!AssignProcessToJobObject(job, proceso.Handle)) {
        int error = Marshal.GetLastWin32Error();
        if (!proceso.HasExited) { proceso.Kill(); throw new Win32Exception(error); }
      }
      entrada = Task.Run(() => {
        try {
          byte[] bytes = new UTF8Encoding(false).GetBytes(texto ?? "");
          proceso.StandardInput.BaseStream.Write(bytes, 0, bytes.Length);
          proceso.StandardInput.BaseStream.Flush();
        } catch (Exception e) { Guardar("AVISO stdin: " + e.Message); }
        finally { if (!EntradaAbierta) try { proceso.StandardInput.Close(); } catch (Exception e) { Guardar("AVISO stdin al cerrar: " + e.Message); } }
      });
    }
    public void Cortar() {
      if (job != IntPtr.Zero && !TerminateJobObject(job, 124)) throw new Win32Exception();
    }
    public bool CortarPorTiempo() {
      // Decide después de consultar de nuevo el estado, no con el del bucle anterior.
      if (proceso.HasExited) return false;
      Cortar(); return true;
    }
    public void Drenar() {
      // Un descendiente puede retener stdout aun después de morir el CLI.
      Cortar();
      if (!proceso.WaitForExit(5000)) throw new TimeoutException("El árbol no terminó.");
      if (!salidaFin.WaitOne(5000) || !errorFin.WaitOne(5000)) throw new TimeoutException("No se cerraron las tuberías del CLI.");
      if (entrada != null) entrada.Wait(2000);
    }
    public void Dispose() {
      if (job != IntPtr.Zero) { CloseHandle(job); job = IntPtr.Zero; }
      lock (cerrojo) { cerrado = true; if (log != null) log.Dispose(); }
      proceso.Dispose();
      // Los callbacks pueden estar terminando si falló Iniciar; sus eventos siguen siendo válidos.
    }
  }
}
'@
}

# Última escritura de un archivo bajo una carpeta, sin .git ni salidas de compilación (bin y obj: un build en bucle no cuenta como avance).
function Ultima-Escritura([string]$Carpeta) {
  $max = [DateTime]::MinValue
  $pila = New-Object 'System.Collections.Generic.Stack[string]'; $pila.Push($Carpeta)
  while ($pila.Count) {
    $d = $pila.Pop()
    try {
      foreach ($f in [IO.Directory]::EnumerateFiles($d)) { $t = [IO.File]::GetLastWriteTimeUtc($f); if ($t -gt $max) { $max = $t } }
      foreach ($s in [IO.Directory]::EnumerateDirectories($d)) { if ([IO.Path]::GetFileName($s) -notin '.git', 'bin', 'obj', 'node_modules', '.entorno') { $pila.Push($s) } }
    } catch { }
  }
  $max
}
# CPU de cada descendiente de un PID (sin él), por PID: compilar o repetir pruebas no escribe fuera de bin y obj, pero gasta CPU.
function Cpu-Descendientes([int]$Raiz) {
  $hijos = @{}
  foreach ($p in Get-CimInstance Win32_Process -Property ProcessId, ParentProcessId -ErrorAction SilentlyContinue) {
    if (-not $hijos.ContainsKey([int]$p.ParentProcessId)) { $hijos[[int]$p.ParentProcessId] = New-Object 'System.Collections.Generic.List[int]' }
    $hijos[[int]$p.ParentProcessId].Add([int]$p.ProcessId)
  }
  $cpu = @{}; $pila = New-Object 'System.Collections.Generic.Stack[int]'; $pila.Push($Raiz); $vistos = @{ $Raiz = $true }
  while ($pila.Count) {
    $id = $pila.Pop()
    if (-not $hijos.ContainsKey($id)) { continue }
    foreach ($h in $hijos[$id]) {
      if ($vistos.ContainsKey($h)) { continue }
      $vistos[$h] = $true; $pila.Push($h)
      try { $cpu[$h] = (Get-Process -Id $h -ErrorAction Stop).TotalProcessorTime.TotalSeconds } catch { }
    }
  }
  $cpu
}
# Segundos de CPU gastados entre dos muestras; un proceso nuevo cuenta entero (un bucle de pruebas abre uno por vuelta).
function Cpu-Gastada($Antes, $Ahora) {
  $s = 0.0
  foreach ($k in $Ahora.Keys) { $s += $Ahora[$k] - $(if ($Antes.ContainsKey($k)) { $Antes[$k] } else { 0 }) }
  $s
}
function Invocar-ProcesoMesa {
  param([string]$Ejecutable, [string[]]$Argumentos = @(), [string]$Entrada = '', [string]$Directorio,
    [string]$Log, [double]$Segundos = 5400, [double]$Inactivo = 0, [switch]$Ver, [scriptblock]$AlIniciar, [string]$Hasta, [switch]$Latido)
  $ruta = (Get-Command $Ejecutable -ErrorAction Stop | Select-Object -First 1).Source
  $shimCodex = Join-Path (Split-Path -Parent $ruta) 'node_modules\@openai\codex\bin\codex.js'
  if ([IO.Path]::GetFileNameWithoutExtension($ruta) -eq 'codex' -and [IO.Path]::GetExtension($ruta) -in @('.ps1', '.cmd') -and (Test-Path -LiteralPath $shimCodex)) {
    $nodeLocal = Join-Path (Split-Path -Parent $ruta) 'node.exe'
    $ruta = if (Test-Path -LiteralPath $nodeLocal) { $nodeLocal } else { (Get-Command node.exe -ErrorAction Stop).Source }
    $Argumentos = @($shimCodex) + $Argumentos
  }
  if ([IO.Path]::GetExtension($ruta) -in @('.cmd', '.bat')) {
    # Los shims npm tienen un .ps1 hermano: evita una segunda interpretación de cmd.exe (% y metacaracteres).
    $hermano = [IO.Path]::ChangeExtension($ruta, '.ps1')
    if (-not (Test-Path -LiteralPath $hermano)) { throw "El lanzador requiere el shim .ps1 junto a $ruta" }
    $ruta = $hermano
  }
  if ([IO.Path]::GetExtension($ruta) -eq '.ps1') {
    $literales = @($ruta) + @($Argumentos) | ForEach-Object { "'" + $_.Replace("'", "''") + "'" }
    $orden = '$ProgressPreference = "SilentlyContinue"; $OutputEncoding = [Console]::OutputEncoding = New-Object Text.UTF8Encoding $false; & ' + ($literales -join ' ')
    $orden += '; if ($null -ne $LASTEXITCODE) { exit $LASTEXITCODE }'
    $ruta = (Get-Command powershell.exe -ErrorAction Stop).Source
    $Argumentos = @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($orden)))
  }
  $argsTexto = (@($Argumentos | ForEach-Object { [Mesa.Proceso]::Citar($_) }) -join ' ')
  $proceso = New-Object Mesa.Proceso
  $reloj = [Diagnostics.Stopwatch]::StartNew()
  $tiempo = $false; $colgado = $false
  $latidoMirado = [DateTime]::MinValue; $latidoArchivo = [DateTime]::MinValue; $cpuAntes = $null; $cpuMirado = [DateTime]::MinValue; $cpuActivo = [DateTime]::MinValue
  $identidadGuardada = -not $AlIniciar
  $siguienteIntento = 0.0
  try {
    # -Hasta <regex>: para servidores por stdio (codex app-server); la entrada queda abierta y se corta al llegar la línea esperada.
    $proceso.EntradaAbierta = [bool]$Hasta
    $proceso.Iniciar($ruta, $argsTexto, $Directorio, $Log, $Entrada, [bool]$Ver, "$Global:Mesa_Excluidos")
    $identidad = [pscustomobject]@{ cli_pid = $proceso.Id; cli_inicio = $proceso.Inicio; cli_nombre = $proceso.Nombre }
    while (-not $proceso.Terminado) {
      if ($reloj.Elapsed.TotalSeconds -ge $Segundos) { $tiempo = $proceso.CortarPorTiempo(); break }
      # Un CLI mudo (agy se quedó 90 min con un log de 63 bytes) se corta como si venciera el tiempo.
      # -Latido, cada minuto: uno que compila o prueba en bucle no escribe nada, pero sus hijos gastan CPU (Devin, 16 y
      # 17-nov: cuatro cortes así). El tope total sigue cortando lo que no acaba.
      if ($Latido -and $Inactivo -gt 0 -and ([DateTime]::UtcNow - $cpuMirado).TotalSeconds -ge 60) {
        $cpuMirado = [DateTime]::UtcNow; $cpu = Cpu-Descendientes $proceso.Id
        if ($cpuAntes -and (Cpu-Gastada $cpuAntes $cpu) -ge 5) { $cpuActivo = $cpuMirado }
        $cpuAntes = $cpu
      }
      if ($Inactivo -gt 0 -and ([DateTime]::UtcNow - $proceso.UltimaLinea).TotalSeconds -ge $Inactivo) {
        # -Latido: un CLI que escribe archivos sin decir nada (Devin calló 20 min con 2400 líneas hechas) no está colgado.
        if ($Latido -and ([DateTime]::UtcNow - $latidoMirado).TotalSeconds -ge 60) { $latidoMirado = [DateTime]::UtcNow; $latidoArchivo = Ultima-Escritura $Directorio }
        $vivo = [DateTime]$(if ($cpuActivo -gt $latidoArchivo) { $cpuActivo } else { $latidoArchivo })
        if (-not $Latido -or ([DateTime]::UtcNow - $vivo).TotalSeconds -ge $Inactivo) { $colgado = $proceso.CortarPorTiempo(); break }
      }
      if (-not $identidadGuardada -and $reloj.Elapsed.TotalSeconds -ge $siguienteIntento) {
        try { $identidadGuardada = (& $AlIniciar $identidad) -ne $false } catch { $identidadGuardada = $false }
        $siguienteIntento = $reloj.Elapsed.TotalSeconds + 1
      }
      if ($Ver) { while ($null -ne ($linea = $proceso.Siguiente())) { Mostrar-Linea $linea } }
      if ($Hasta -and (Select-String -LiteralPath $Log -Pattern $Hasta -Quiet)) { [void]$proceso.CortarPorTiempo(); break }
      Start-Sleep -Milliseconds $(if ($Hasta) { 100 } else { 500 })
    }
    $proceso.Drenar()
    if (-not $identidadGuardada) { try { & $AlIniciar $identidad | Out-Null } catch {} }
    if ($Ver) { while ($null -ne ($linea = $proceso.Siguiente())) { Mostrar-Linea $linea } }
    $codigo = if ($tiempo -or $colgado) { 124 } else { $proceso.Codigo }
    if ($proceso.Fallo -and -not $tiempo -and -not $colgado -and $codigo -eq 0) {
      [IO.File]::AppendAllText($Log, "ERROR: $($proceso.Fallo)`n", (New-Object Text.UTF8Encoding $false)); $codigo = 1
    }
    return [pscustomobject]@{ salida = $codigo; causa = $(if ($tiempo) { 'tiempo' } elseif ($colgado) { 'colgado' } else { $null }); identidad = $identidad }
  } finally { $proceso.Dispose() }
}
