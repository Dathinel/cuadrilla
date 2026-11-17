# Un worktree por agente y tarea, con la misma regla en todos los repos: <repo principal>\.claude\worktrees\<agente>-<tarea>
# (aunque -Dir sea ya un worktree: no se anidan),
# rama <agente>/<tarea>, creado desde la rama principal actualizada. Solo en carpetas que son repositorios git.
# Uso:
#   worktrees.ps1 crear -Dir <carpeta del repo> -Agente codex -Tarea <id>     (escribe la ruta del worktree)
#   worktrees.ps1 lista [-Json]                                              (los de la mesa en los repos de la carpeta de trabajo)
#   worktrees.ps1 limpiar                                                    (quita solo los integrados y limpios; lista los demás)
param(
  [Parameter(Position = 0, Mandatory = $true)][ValidateSet('crear', 'lista', 'limpiar')][string]$Comando,
  [string]$Dir,
  [string]$Agente,
  [string]$Tarea,
  [switch]$Json
)
# Continue y no Stop (aunque lo herede de quien llama): en PowerShell 5.1 el stderr de git, aunque vaya a $null, se volvería una excepción.
$ErrorActionPreference = 'Continue'
. "$PSScriptRoot\comun.ps1"

function Raiz-Repo($d) { $r = (& git -C $d rev-parse --show-toplevel 2>$null); if ($LASTEXITCODE -eq 0 -and $r) { [IO.Path]::GetFullPath($r) } }
function Rama-Principal($repo) {
  $r = (& git -C $repo symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>$null)
  if ($r) { return $r }
  foreach ($c in 'origin/main', 'origin/master', 'main', 'master') { & git -C $repo rev-parse --verify --quiet $c 2>$null | Out-Null; if ($LASTEXITCODE -eq 0) { return $c } }
  'HEAD'
}
# Los worktrees de la mesa: los de .claude\worktrees con rama claude/, codex/, agy/ o devin/. Los demás (de otras herramientas) no se tocan.
function Worktrees-Mesa($repo) {
  $actual = $null
  foreach ($l in @(& git -C $repo worktree list --porcelain 2>$null) + '') {
    if ($l -like 'worktree *') { $actual = @{ ruta = [IO.Path]::GetFullPath($l.Substring(9)) } }
    elseif ($l -like 'branch refs/heads/*') { $actual.rama = $l.Substring(18) }
    elseif (-not $l -and $actual) {
      if ($actual.rama -match '^(claude|codex|agy|devin)/(.+)$' -and $actual.ruta -like "*\.claude\worktrees\*") {
        $sucio = @(& git -C $actual.ruta status --porcelain 2>$null).Count
        $principal = Rama-Principal $repo
        & git -C $repo merge-base --is-ancestor $actual.rama $principal 2>$null; $integrada = $LASTEXITCODE -eq 0
        [pscustomobject]@{ repo = $repo; ruta = $actual.ruta; rama = $actual.rama; agente = $Matches[1]; tarea = $Matches[2]; sin_confirmar = $sucio; integrada = $integrada }
      }
      $actual = $null
    }
  }
}
# A dos niveles: los repos agrupados en una subcarpeta (<trabajo>\grupo\repo) también cuentan para lista, limpiar y el tope.
function Repos { @(Get-ChildItem -LiteralPath $Global:Mesa_DefaultDir -Directory -Depth 1 -ErrorAction SilentlyContinue | Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName '.git') } | ForEach-Object FullName) }
# Agente con algún encargo en marcha: uno de sus puestos datos\trabajos\<agente>.<n>.lock está tomado.
# shortcut: con un puesto ocupado se respetan todos los worktrees de ese agente; si estorba, mirar el worktree de cada resultado vivo.
function Ocupado($agente) {
  foreach ($f in @(Get-ChildItem -LiteralPath (Join-Path $Global:Mesa_Raiz 'trabajos') -Filter "$agente.*lock" -File -ErrorAction SilentlyContinue)) {
    try { [IO.File]::Open($f.FullName, 'Open', 'ReadWrite', 'None').Dispose() } catch { return $true }
  }
  $false
}

switch ($Comando) {
  'crear' {
    if (-not $Dir -or -not $Agente -or -not $Tarea) { throw 'Uso: worktrees.ps1 crear -Dir <repo> -Agente <agente> -Tarea <id>' }
    if ($Tarea -notmatch '^[a-z0-9][a-z0-9-]*$') { throw 'Tarea: solo minúsculas, cifras y guiones.' }
    $repo = Raiz-Repo $Dir
    if (-not $repo) { throw "$Dir no es un repositorio git: se trabaja con reclamos, sin worktree." }
    $cfg = Mesa-LeerJson (Mesa-ConfigPath)
    # El tope nunca baja de los puestos: con 4 encargos de Devin a la vez hacen falta 4 worktrees.
    $max = [Math]::Max([int]$(if ($cfg.worktrees.max_por_agente) { $cfg.worktrees.max_por_agente } else { 3 }), (Mesa-Puestos $Agente $cfg))
    # Los worktrees de un mismo repo salen una vez por cada carpeta suya que esté en la carpeta de trabajo: se cuentan por ruta (15-nov: uno contaba como 8).
    $vivos = @(@(Repos) + $repo | Select-Object -Unique | ForEach-Object { Worktrees-Mesa $_ } | Where-Object { $_.agente -eq $Agente } | Sort-Object ruta -Unique)
    # -Dir puede ser un worktree: el del CLI va en la raíz del repo principal (rutas cortas); la rama de partida sigue saliendo de -Dir.
    $principal = Mesa-RaizPrincipal $repo
    $ruta = Join-Path $principal ".claude\worktrees\$Agente-$Tarea"
    if (Test-Path -LiteralPath $ruta) {
      # Un apagón a mitad de git worktree add deja la carpeta sin su .git: no se arranca un CLI sobre un árbol a medias.
      if (-not (Test-Path -LiteralPath (Join-Path $ruta '.git'))) { throw "$ruta existe pero no es un worktree (quedó a medias): bórralo y ejecuta git worktree prune en el repo" }
      # Ni una carpeta ajena con .git ni el mismo worktree en otra rama: se exige que Git lo registre aquí y con la rama prevista.
      $rutaGit = $ruta -replace '\\', '/'
      $registrados = & git -C $repo worktree list --porcelain 2>$null | Select-String -SimpleMatch "worktree $rutaGit"
      $ramaReal = & git -C $ruta rev-parse --abbrev-ref HEAD 2>$null
      if (-not $registrados) { throw "$ruta tiene .git pero Git no lo registra como worktree de este repo: revísalo" }
      if ($ramaReal -ne "$Agente/$Tarea") { throw "$ruta es un worktree pero en rama $ramaReal (esperada $Agente/$Tarea): revísalo" }
      Write-Output $ruta; return
    }
    if ($vivos.Count -ge $max) { throw "$Agente ya tiene $($vivos.Count) worktrees vivos (tope $max): $(@($vivos | ForEach-Object rama) -join ', '). Intégralos o límpialos antes." }
    # Que .claude\worktrees no aparezca como cambio del repo: exclusión local, sin tocar su .gitignore.
    $excl = Join-Path $principal '.git\info\exclude'
    & git -C $principal check-ignore -q '.claude/worktrees/x' 2>$null
    if ($LASTEXITCODE -ne 0 -and (Test-Path -LiteralPath (Split-Path $excl))) { Add-Content -LiteralPath $excl -Value '/.claude/worktrees/' -Encoding ASCII }
    & git -C $repo fetch --quiet origin 2>$null
    # Si -Dir está en otra rama (un worktree de trabajo), el encargo es sobre esa rama: se parte de ella, no de main (15-nov).
    $base = Rama-Principal $repo
    $enDir = & git -C $repo rev-parse --abbrev-ref HEAD 2>$null
    if ($LASTEXITCODE -eq 0 -and $enDir -and $enDir -ne 'HEAD' -and $enDir -notin @('main', 'master') -and $enDir -ne ($base -replace '^origin/', '')) { $base = $enDir }
    $rama = "$Agente/$Tarea"
    # Dos delegar a la vez sobre el mismo repo (codex y agy) chocan en los candados de git: se reintenta.
    $error_ = ''
    foreach ($intento in 1..3) {
      & git -C $repo show-ref --verify --quiet "refs/heads/$rama" 2>$null
      $error_ = if ($LASTEXITCODE -eq 0) { & git -C $repo worktree add --quiet $ruta $rama 2>&1 | Out-String } else { & git -C $repo worktree add --quiet -b $rama $ruta $base 2>&1 | Out-String }
      # Éxito solo con código cero y el .git del worktree en su sitio: la carpeta sola puede quedar a medias.
      if ($LASTEXITCODE -eq 0 -and (Test-Path -LiteralPath (Join-Path $ruta '.git'))) { break }
      Start-Sleep -Seconds (2 * $intento)
    }
    if (-not (Test-Path -LiteralPath (Join-Path $ruta '.git'))) { throw "git worktree add falló en $repo ($rama desde $base): $($error_.Trim())" }
    # Un worktree nace sin los submódulos : el CLI se paraba al no encontrar sus scripts. Necesita red; si falla, se avisa y sigue.
    if (Test-Path -LiteralPath (Join-Path $ruta '.gitmodules')) {
      $sub = & git -C $ruta submodule update --init --depth 1 2>&1 | Out-String
      if ($LASTEXITCODE -ne 0) { Write-Warning "submódulos sin inicializar en $ruta (¿sin red?): $($sub.Trim())" }
    }
    Write-Output $ruta
  }
  'lista' {
    $items = @(Repos | ForEach-Object { Worktrees-Mesa $_ } | Sort-Object ruta -Unique)
    if ($Json) { ConvertTo-Json -InputObject $items -Depth 3 } elseif (-not $items.Count) { '(sin worktrees de la mesa)' }
    else { $items | Format-Table agente, rama, sin_confirmar, integrada, ruta -AutoSize | Out-String -Width 220 }
  }
  'limpiar' {
    foreach ($w in @(Repos | ForEach-Object { Worktrees-Mesa $_ } | Sort-Object ruta -Unique)) {
      # Nunca se borra trabajo: con cambios sin confirmar o sin integrar, decide la persona. Uno recién creado está «integrado y limpio»: se respeta mientras el agente trabaja.
      if (Ocupado $w.agente) { "Se queda ($($w.agente) tiene un encargo en marcha): $($w.ruta)"; continue }
      if ($w.integrada -and $w.sin_confirmar -eq 0) {
        & git -C $w.repo worktree remove $w.ruta 2>&1 | Out-Null
        # Git no quita sin --force un worktree con submódulos inicializados; ya se comprobó que está limpio e integrado.
        if ($LASTEXITCODE -ne 0 -and (Test-Path -LiteralPath (Join-Path $w.ruta '.gitmodules'))) { & git -C $w.repo worktree remove --force $w.ruta 2>&1 | Out-Null }
        if ($LASTEXITCODE -eq 0) { & git -C $w.repo branch -d $w.rama 2>&1 | Out-Null; "Quitado (integrado y limpio): $($w.rama)" } else { "No se pudo quitar: $($w.ruta)" }
      } else {
        "Se queda para que decidas: $($w.rama) en $($w.ruta) ($(if ($w.sin_confirmar) { "$($w.sin_confirmar) cambios sin confirmar" } else { 'sin cambios pendientes' }), $(if ($w.integrada) { 'integrada' } else { 'sin integrar' }))"
      }
    }
  }
}
