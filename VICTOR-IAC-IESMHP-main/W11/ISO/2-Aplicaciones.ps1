#Requires -Version 5.1
<#
  2-Aplicaciones.ps1  -  Instalacion de software del W11 (winget + chocolatey)
  ============================================================================
  Lo lanza 1-Setup.ps1 (3er paso de la cadena). Instala el MISMO software que el
  playbook de Ansible W11/ansible/roles.yaml, pero en local, sin Ansible.

  Dos listas EDITABLES (una por gestor), cada una con Nombre / Id / Version /
  Args opcionales. Dos bucles las recorren:
    - PREFERENTEMENTE winget (lista $Winget).
    - chocolatey SOLO para lo que no esta bien en winget (lista $Choco): veyon,
      basex (y vmware-workstation, comentado igual que en roles.yaml).

  Para cada aplicacion se MIDE el tiempo de instalacion y se registra en el log
  de este script (...\2-Aplicaciones.ps1.log). Si una falla, se anota el error y
  se CONTINUA con la siguiente (nunca aborta). El tiempo TOTAL de esta fase lo
  anota 1-Setup.ps1 en Tiempos.log.

  Versiones: por defecto vacias ('' = ultima version). Para fijar una version,
  rellenar el campo Version (winget: '--version X'; choco: '--version X'). Las
  versiones de referencia del aula estan en W11/ansible/CLAUDE.md.

  Idempotente: winget/choco no reinstalan lo ya presente. Log al lado (req 0).
  ============================================================================
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Continue'

# --- comun.ps1 (logging + tiempos) -----------------------------------------
$Here  = $PSScriptRoot
if (-not $Here) { $Here = Split-Path -Parent $MyInvocation.MyCommand.Path }
$Comun = Join-Path $Here 'comun.ps1'
if (Test-Path $Comun) { . $Comun; Initialize-Log $PSCommandPath }
else {
  # Respaldo minimo si se ejecuta suelto sin comun.ps1.
  $Global:IAC_LOG = "$PSCommandPath.log"
  function Log { param([string]$m) $l='{0}  {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'),$m; Write-Host $l; try { Add-Content -Path $Global:IAC_LOG -Value $l -Encoding UTF8 } catch {} }
  function Format-Dur { param([TimeSpan]$d) ('{0:00}:{1:00}:{2:00}' -f [math]::Floor($d.TotalHours),$d.Minutes,$d.Seconds) }
}

Log "===== 2-Aplicaciones.ps1 inicio ====="

# ===========================================================================
#  LISTAS DE APLICACIONES (editar aqui)  -  Nombre / Id / Version / Args
# ===========================================================================

# --- winget (preferente) ---------------------------------------------------
$Winget = @(
  [pscustomobject]@{ Nombre='Google Chrome';            Id='Google.Chrome';                      Version=''; Args=@() }
  [pscustomobject]@{ Nombre='OBS Studio';               Id='OBSProject.OBSStudio';               Version=''; Args=@() }
  [pscustomobject]@{ Nombre='OpenShot';                 Id='OpenShot.OpenShot';                  Version=''; Args=@() }
  [pscustomobject]@{ Nombre='GIMP';                     Id='GIMP.GIMP';                          Version=''; Args=@() }
  [pscustomobject]@{ Nombre='ZoomIt (Sysinternals)';    Id='Microsoft.Sysinternals.ZoomIt';      Version=''; Args=@() }
  [pscustomobject]@{ Nombre='Visual Studio Code';       Id='Microsoft.VisualStudioCode';         Version=''; Args=@('--scope','machine') }
  [pscustomobject]@{ Nombre='Vagrant';                  Id='Hashicorp.Vagrant';                  Version=''; Args=@() }
  [pscustomobject]@{ Nombre='Notepad++';                Id='Notepad++.Notepad++';                Version=''; Args=@() }
  [pscustomobject]@{ Nombre='AWS CLI v2';               Id='Amazon.AWSCLI';                      Version=''; Args=@() }
  [pscustomobject]@{ Nombre='Visual Studio Community';  Id='Microsoft.VisualStudio.2022.Community'; Version=''; Args=@() }
  [pscustomobject]@{ Nombre='Oracle VirtualBox';        Id='Oracle.VirtualBox';                  Version=''; Args=@() }
  [pscustomobject]@{ Nombre='Microsoft 365 (Office)';   Id='Microsoft.Office';                   Version=''; Args=@() }
)

# --- chocolatey (solo lo que no esta bien en winget) -----------------------
$Choco = @(
  [pscustomobject]@{ Nombre='Veyon';                    Id='veyon';                              Version=''; Args=@() }
  [pscustomobject]@{ Nombre='BaseX';                    Id='basex';                              Version=''; Args=@() }
  # [pscustomobject]@{ Nombre='VMware Workstation';     Id='vmware-workstation';                 Version=''; Args=@() }  # COMENTADO (igual que roles.yaml: el paquete Choco falla)
)

# ===========================================================================
#  Helpers
# ===========================================================================
function Find-Winget {
  $env:Path = [Environment]::GetEnvironmentVariable('Path','Machine') + ';' +
              [Environment]::GetEnvironmentVariable('Path','User') + ';' +
              (Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps')
  $w = Get-Command winget.exe -ErrorAction SilentlyContinue
  if ($w) { return $w.Source }
  $alias = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\winget.exe'
  if (Test-Path $alias) { return $alias }
  return $null
}

function Initialize-Choco {
  # Devuelve la ruta de choco.exe, instalandolo si falta (script oficial).
  $c = Get-Command choco.exe -ErrorAction SilentlyContinue
  if ($c) { return $c.Source }
  $def = 'C:\ProgramData\chocolatey\bin\choco.exe'
  if (Test-Path $def) { return $def }
  try {
    Log "Chocolatey no encontrado; instalandolo (script oficial)..."
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Invoke-Expression ((New-Object Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1'))
  } catch { Log "ERROR instalando Chocolatey: $($_.Exception.Message)"; return $null }
  if (Test-Path $def) { return $def }
  $c = Get-Command choco.exe -ErrorAction SilentlyContinue
  if ($c) { return $c.Source }
  return $null
}

# Resultados para el resumen final
$Resultados = New-Object System.Collections.Generic.List[object]
function Add-Resultado {
  param([string]$Gestor, [string]$Nombre, [bool]$Ok, [TimeSpan]$Dur, [string]$Detalle)
  $Resultados.Add([pscustomobject]@{ Gestor=$Gestor; Nombre=$Nombre; Ok=$Ok; Dur=$Dur; Detalle=$Detalle }) | Out-Null
}

function Install-ConWinget {
  param($wingetExe, $app)
  $argl = @('install','--id',$app.Id,'-e','--source','winget',
            '--accept-package-agreements','--accept-source-agreements','--silent')
  if ($app.Version) { $argl += @('--version', $app.Version) }
  if ($app.Args)    { $argl += $app.Args }
  Log "winget: instalando '$($app.Nombre)' (Id=$($app.Id) $(if($app.Version){"v$($app.Version)"}else{'ultima'}))"
  $ini = Get-Date
  try {
    & $wingetExe @argl
    $code = $LASTEXITCODE
  } catch { Log "  EXCEPCION winget '$($app.Nombre)': $($_.Exception.Message)"; $code = -1 }
  $dur = (Get-Date) - $ini
  # 0 = OK; -1978335189 (0x8A15002B) = ya instalado / sin actualizacion aplicable.
  $ok = ($code -eq 0 -or $code -eq -1978335189)
  if ($ok) { Log "  OK '$($app.Nombre)' (code=$code) en $(Format-Dur $dur)" }
  else     { Log "  FALLO '$($app.Nombre)' (code=$code) tras $(Format-Dur $dur); continuo." }
  Add-Resultado 'winget' $app.Nombre $ok $dur "code=$code"
  return $ok
}

function Install-ConChoco {
  param($chocoExe, $app)
  $argl = @('install', $app.Id, '-y', '--no-progress')
  if ($app.Version) { $argl += @('--version', $app.Version) }
  if ($app.Args)    { $argl += $app.Args }
  Log "choco: instalando '$($app.Nombre)' (Id=$($app.Id) $(if($app.Version){"v$($app.Version)"}else{'ultima'}))"
  $ini = Get-Date
  try {
    & $chocoExe @argl
    $code = $LASTEXITCODE
  } catch { Log "  EXCEPCION choco '$($app.Nombre)': $($_.Exception.Message)"; $code = -1 }
  $dur = (Get-Date) - $ini
  # 0 = OK; 3010 = OK pero requiere reinicio; 1641 = OK con reinicio iniciado.
  $ok = ($code -eq 0 -or $code -eq 3010 -or $code -eq 1641)
  if ($ok) { Log "  OK '$($app.Nombre)' (code=$code) en $(Format-Dur $dur)" }
  else     { Log "  FALLO '$($app.Nombre)' (code=$code) tras $(Format-Dur $dur); continuo." }
  Add-Resultado 'choco' $app.Nombre $ok $dur "code=$code"
  return $ok
}

# ===========================================================================
#  BUCLE 1 — winget
# ===========================================================================
$wingetExe = Find-Winget
if (-not $wingetExe) {
  Log "AVISO: winget no disponible; me salto la lista winget ($($Winget.Count) apps)."
} else {
  Log "winget = $wingetExe ; $($Winget.Count) aplicacion(es) en la lista."
  foreach ($app in $Winget) { Install-ConWinget $wingetExe $app | Out-Null }
}

# ===========================================================================
#  BUCLE 2 — chocolatey
# ===========================================================================
if ($Choco.Count -eq 0) {
  Log "Lista chocolatey vacia; nada que instalar por choco."
} else {
  $chocoExe = Initialize-Choco
  if (-not $chocoExe) {
    Log "AVISO: chocolatey no disponible; me salto la lista choco ($($Choco.Count) apps)."
  } else {
    Log "choco = $chocoExe ; $($Choco.Count) aplicacion(es) en la lista."
    foreach ($app in $Choco) { Install-ConChoco $chocoExe $app | Out-Null }
  }
}

# ===========================================================================
#  Resumen
# ===========================================================================
$okN  = @($Resultados | Where-Object { $_.Ok }).Count
$badN = @($Resultados | Where-Object { -not $_.Ok }).Count
Log "----------------------------------------------------------------"
Log "RESUMEN aplicaciones:  OK=$okN   FALLOS=$badN   TOTAL=$($Resultados.Count)"
foreach ($r in $Resultados) {
  $estado = if ($r.Ok) { 'OK   ' } else { 'FALLO' }
  Log ("  [{0}] {1,-7} {2,-28} {3,8}  ({4})" -f $estado, $r.Gestor, $r.Nombre, (Format-Dur $r.Dur), $r.Detalle)
}
if ($badN -gt 0) {
  Log "Aplicaciones con error (revisar): $((@($Resultados | Where-Object { -not $_.Ok } | ForEach-Object { $_.Nombre })) -join ', ')"
}
Log "===== 2-Aplicaciones.ps1 fin ====="
