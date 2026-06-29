#Requires -Version 5.1
<#
  0b-GitHub.ps1  -  Bootstrap de IAC-IESMHP en Windows 11
  ============================================================================
  Lo lanza el autounattend.xml (FirstLogonCommands) en el primer inicio de
  sesion. Va embebido en la ISO via $OEM$\$1 y, desde el principio, vive en su
  ubicacion DEFINITIVA:

      C:\Program Files\IAC-IESMHP\W11\ISO\0b-GitHub.ps1   (lo coloca 0-CreaIsoW11.sh)

  Hace:
    1. Localiza git (lo instala Order 2 del autounattend; si aun no esta en el
       PATH lo busca en rutas conocidas; como ultimo recurso lo instala con
       winget o por descarga directa).
    2. Clona https://github.com/victormuelacarriles/IAC-IESMHP.git en
       "C:\Program Files\IAC-IESMHP" con sparse-checkout en modo cono, dejando
       SOLO los ficheros de la raiz y la subcarpeta W11. Como la carpeta destino
       YA contiene este propio script, NO se puede usar 'git clone' (exige dir
       vacio): se clona IN-PLACE con init + fetch + checkout, machacando este
       0b-GitHub.ps1 con la version de GitHub (queda "actualizado" sin moverse).
    3. Carga comun.ps1 (ya clonado), anota el tiempo de clonado en Tiempos.log y
       ejecuta "C:\Program Files\IAC-IESMHP\W11\ISO\1-Setup.ps1" en una VENTANA
       VISIBLE.

  Equivalente Windows de 0b-Github.sh (Ubuntu). Idempotente: se puede relanzar.
  Log (al lado del script, req 0): C:\Program Files\IAC-IESMHP\W11\ISO\0b-GitHub.ps1.log
  ============================================================================
#>
[CmdletBinding()]
param(
  [string]$RepoUrl  = 'https://github.com/victormuelacarriles/IAC-IESMHP.git',
  [string]$Dest     = 'C:\Program Files\IAC-IESMHP',
  [string]$Subdir   = 'W11',                 # subcarpeta a conservar (+ raiz)
  [string]$Branch   = 'main'
)

$ErrorActionPreference = 'Stop'

# --- Log: junto al propio script, <nombre>.ps1.log (req 0) -----------------
$SelfPath = $PSCommandPath
if (-not $SelfPath) { $SelfPath = $MyInvocation.MyCommand.Path }
$SelfDir  = Split-Path -Parent $SelfPath
$LogFile  = "$SelfPath.log"
if (-not (Test-Path $SelfDir)) { New-Item -ItemType Directory -Force -Path $SelfDir | Out-Null }

function Log {
  param([string]$Msg)
  $line = '{0}  {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Msg
  Write-Host $line
  try { Add-Content -Path $LogFile -Value $line -Encoding UTF8 } catch {}
}

Log "===== 0b-GitHub.ps1 inicio ====="
Log "Repo=$RepoUrl  Dest=$Dest  Subdir=$Subdir  Branch=$Branch"
Log "Script (definitivo) en: $SelfPath"
$StartClone = Get-Date

# --- Helpers ---------------------------------------------------------------
function Sync-ProcessPath {
  # Reconstruye el PATH del proceso desde Maquina + Usuario e incluye
  # explicitamente WindowsApps, donde vive el ALIAS de ejecucion winget.exe.
  # En el primer inicio de sesion ese alias puede no estar aun en el PATH.
  $env:Path = [Environment]::GetEnvironmentVariable('Path','Machine') + ';' +
              [Environment]::GetEnvironmentVariable('Path','User') + ';' +
              (Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps')
}

function Find-Git {
  Sync-ProcessPath
  $g = Get-Command git.exe -ErrorAction SilentlyContinue
  if ($g) { return $g.Source }
  foreach ($p in @(
      "$env:ProgramFiles\Git\cmd\git.exe",
      "${env:ProgramFiles(x86)}\Git\cmd\git.exe",
      "$env:LOCALAPPDATA\Programs\Git\cmd\git.exe")) {
    if (Test-Path $p) { return $p }
  }
  return $null
}

function Find-Winget {
  Sync-ProcessPath
  $w = Get-Command winget.exe -ErrorAction SilentlyContinue
  if ($w) { return $w.Source }
  $alias = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\winget.exe'
  if (Test-Path $alias) { return $alias }
  return $null
}

function Install-GitViaWinget {
  # CAUSA DEL FALLO ORIGINAL: en el primer inicio de sesion del usuario recien
  # creado, winget (App Installer, paquete MSIX) aun NO esta registrado para
  # ese usuario -> 'winget' no se reconoce. Se registra unos segundos despues.
  # Por eso esperamos a que aparezca (hasta ~60 s) en lugar de rendirnos.
  $winget = $null
  for ($i = 1; $i -le 12; $i++) {
    $winget = Find-Winget
    if ($winget) { break }
    Log "winget aun no registrado, espero ($i/12)..."
    Start-Sleep -Seconds 5
  }
  if (-not $winget) { Log "winget no aparecio; paso a descarga directa."; return $false }
  Log "winget = $winget ; instalando Git.Git..."
  try {
    & $winget install --id Git.Git -e --source winget `
        --accept-package-agreements --accept-source-agreements --silent
    return ($LASTEXITCODE -eq 0)
  } catch { Log "winget fallo: $($_.Exception.Message)"; return $false }
}

function Install-GitViaDownload {
  # PLAN B (no depende de winget/MSIX): descarga el instalador oficial de Git
  # para Windows desde GitHub y lo ejecuta en silencio. Solo necesita red.
  try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $api = 'https://api.github.com/repos/git-for-windows/git/releases/latest'
    Log "Descarga directa: consultando $api ..."
    $rel   = Invoke-RestMethod -Uri $api -Headers @{ 'User-Agent' = 'IAC-IESMHP' }
    $asset = $rel.assets |
             Where-Object { $_.name -match 'Git-.*-64-bit\.exe$' } |
             Select-Object -First 1
    if (-not $asset) { Log "No encuentro instalador Git 64-bit en la release."; return $false }
    $exe = Join-Path $env:TEMP $asset.name
    Log "Descargando $($asset.name) ..."
    Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $exe -UseBasicParsing
    Log "Instalando Git en silencio ..."
    $p = Start-Process -FilePath $exe `
           -ArgumentList '/VERYSILENT','/NORESTART','/SUPPRESSMSGBOXES','/NOCANCEL','/SP-' `
           -Wait -PassThru
    Log "Instalador Git termino con codigo $($p.ExitCode)"
    return ($p.ExitCode -eq 0)
  } catch { Log "Descarga/instalacion directa de Git fallo: $($_.Exception.Message)"; return $false }
}

# --- Esperar a que haya red (necesaria para instalar git y clonar) ---------
$online = $false
for ($i = 1; $i -le 12; $i++) {
  if (Test-Connection -ComputerName 'github.com' -Count 1 -Quiet) { $online = $true; break }
  Log "Sin red, reintento $i/12..."
  Start-Sleep -Seconds 5
}
if (-not $online) { Log "AVISO: sin conectividad ICMP con github.com; intento continuar igualmente." }

# --- Asegurar git: PATH -> winget (con espera) -> descarga directa ----------
$Git = Find-Git
if (-not $Git) {
  Log "git no encontrado; intento instalarlo con winget..."
  if (Install-GitViaWinget) { $Git = Find-Git }
}
if (-not $Git) {
  Log "git sigue sin estar; intento descarga directa del instalador..."
  if (Install-GitViaDownload) { $Git = Find-Git }
}
if (-not $Git) {
  Log "ERROR: git sigue sin estar disponible. Abortando."
  exit 1
}
Log "git = $Git"

# --- "dubious ownership": marcar el repo como seguro -----------------------
# La carpeta C:\Program Files\IAC-IESMHP la crea Windows Setup ($OEM$) como
# SYSTEM/TrustedInstaller, no como 'usuario'; git (>=2.35.2) rechaza operar en
# repos cuyo propietario no coincide con quien lo ejecuta ("detected dubious
# ownership"). La marcamos como segura para el usuario actual antes de clonar.
try {
  & $Git config --global --add safe.directory '*'
  & $Git config --global --add safe.directory ($Dest -replace '\\','/')
  Log "git safe.directory configurado para $Dest (y '*')."
} catch { Log "AVISO: no pude fijar safe.directory: $($_.Exception.Message)" }

# --- Clonar / actualizar con sparse-checkout (cono => raiz + $Subdir) ------
# La carpeta $Dest YA EXISTE (contiene este 0b-GitHub.ps1 puesto por $OEM$), asi
# que NO se usa 'git clone' (exige dir vacio): se clona IN-PLACE.
#
# IMPORTANTE (Windows PowerShell 5.1): git escribe MUCHA informacion en stderr
# (progreso, "No such remote", etc.). Con $ErrorActionPreference='Stop', esa
# salida -sobre todo si se redirige con 2>$null/2>&1- se convierte en un error
# TERMINANTE que aborta el script. Por eso aqui:
#   - bajamos a 'Continue' mientras corre git,
#   - NUNCA redirigimos stderr de git,
#   - comprobamos los fallos REALES a mano con $LASTEXITCODE.
$gitDir = Join-Path $Dest '.git'
$prevEAP = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
$cloneOK = $true
try {
  if (Test-Path $gitDir) {
    Log "El repo ya existe; actualizando (sparse + fetch + reset)..."
    & $Git -C $Dest sparse-checkout set $Subdir
    & $Git -C $Dest fetch --depth 1 origin $Branch
    if ($LASTEXITCODE -ne 0) { throw "git fetch fallo (code $LASTEXITCODE)" }
    # FETCH_HEAD apunta SIEMPRE a lo recien traido (no dependemos de que exista
    # el ref remoto origin/$Branch, que 'fetch <remote> <branch>' no garantiza).
    & $Git -C $Dest checkout -f -B $Branch FETCH_HEAD
    if ($LASTEXITCODE -ne 0) { throw "git checkout fallo (code $LASTEXITCODE)" }
    & $Git -C $Dest reset --hard FETCH_HEAD
  } else {
    if (-not (Test-Path $Dest)) { New-Item -ItemType Directory -Force -Path $Dest | Out-Null }

    Log "Clonado IN-PLACE (init + fetch + checkout, sin blobs)..."
    & $Git -C $Dest init
    if ($LASTEXITCODE -ne 0) { throw "git init fallo (code $LASTEXITCODE)" }

    # Alta del remoto 'origin' idempotente SIN redirigir stderr (un
    # 'remote remove origin' cuando no existe escribe "No such remote" y, con
    # 2>$null+Stop, abortaba el script).
    $remotes = & $Git -C $Dest remote
    if ($remotes -contains 'origin') { & $Git -C $Dest remote set-url origin $RepoUrl }
    else                             { & $Git -C $Dest remote add    origin $RepoUrl }

    # Modo cono: incluye SIEMPRE los ficheros de la raiz + las carpetas dadas.
    Log "sparse-checkout (cono) -> solo raiz + $Subdir"
    & $Git -C $Dest sparse-checkout init --cone
    & $Git -C $Dest sparse-checkout set $Subdir
    & $Git -C $Dest fetch --depth 1 origin $Branch
    if ($LASTEXITCODE -ne 0) { throw "git fetch fallo (code $LASTEXITCODE)" }

    # El UNICO fichero sin rastrear que colisiona con uno del repo es este propio
    # 0b-GitHub.ps1 (lo coloco $OEM$). git checkout abortaria por "untracked
    # working tree files would be overwritten"; lo borramos antes (en Windows un
    # .ps1 en ejecucion NO esta bloqueado: ya esta leido en memoria). Los .log y
    # Tiempos.log no colisionan (el repo no los rastrea) y se conservan.
    $self = Join-Path $Dest 'W11\ISO\0b-GitHub.ps1'
    if (Test-Path $self) { Remove-Item -Force $self -ErrorAction SilentlyContinue }

    & $Git -C $Dest checkout -f -B $Branch FETCH_HEAD
    if ($LASTEXITCODE -ne 0) { throw "git checkout fallo (code $LASTEXITCODE)" }
  }
} catch {
  Log "ERROR al clonar/actualizar: $($_.Exception.Message)"
  $cloneOK = $false
} finally {
  $ErrorActionPreference = $prevEAP
}
if (-not $cloneOK) { exit 1 }
Log "Repo listo en $Dest"

# --- Anotar el tiempo de clonado en Tiempos.log (ya disponible comun.ps1) ---
$Comun = Join-Path $Dest 'W11\ISO\comun.ps1'
if (Test-Path $Comun) {
  try {
    . $Comun
    $Global:IAC_LOG = $LogFile          # que Add-Tiempo escriba en este mismo log
    Add-Tiempo -Fase 'github (clonado)' -Inicio $StartClone
  } catch { Log "AVISO: no se pudo cargar comun.ps1 para los tiempos: $($_.Exception.Message)" }
} else {
  Log "AVISO: no encuentro $Comun (no se anota el tiempo de clonado)."
}

# --- Lanzar 1-Setup.ps1 EN UNA VENTANA VISIBLE (req 2) ---------------------
$Setup = Join-Path $Dest 'W11\ISO\1-Setup.ps1'
if (Test-Path $Setup) {
  Log "Ejecutando $Setup en una ventana PowerShell visible..."
  # OJO (PS 5.1): con -ArgumentList COMO ARRAY, Start-Process NO entrecomilla los
  # elementos con espacios -> la ruta "C:\Program Files\..." se parte y powershell
  # no encuentra el .ps1 (sale con codigo -196608 sin ejecutar nada). Pasamos un
  # UNICO string con la ruta entre comillas (igual que la tarea de reanudacion).
  $argLine = '-NoProfile -ExecutionPolicy Bypass -File "{0}"' -f $Setup
  $p = Start-Process -FilePath 'powershell.exe' -ArgumentList $argLine `
        -WindowStyle Normal -PassThru -Wait
  Log "1-Setup.ps1 termino con codigo $($p.ExitCode)"
} else {
  Log "AVISO: no existe $Setup (aun). Nada que ejecutar."
}

Log "===== 0b-GitHub.ps1 fin ====="
