#Requires -Version 5.1
<#
  1-Setup.ps1  -  Orquestador de configuracion del W11 instalado (post-clonado)
  ============================================================================
  Lo lanza 0b-GitHub.ps1 tras clonar el repo, desde
  C:\Program Files\IAC-IESMHP\W11\ISO\1-Setup.ps1  (corre como administrador,
  en una VENTANA PowerShell VISIBLE para poder seguir el proceso, req 2).

  Conduce TODO el aprovisionamiento, en este orden (decidido con el usuario):

      1) Config basica  : nombre + IP estatica (macs.csv), OpenSSH, ENERGIA
                          "Alto rendimiento" (imita el rol Ansible homonimo).
      2) 2-Aplicaciones.ps1  : winget + chocolatey.
      3) 3-Particionado.ps1  : discos de datos + perfiles en D:\Users.
      4) Windows Update completo (PSWindowsUpdate). Como suele exigir VARIOS
         reinicios que romperian la cadena de FirstLogon, se REANUDA solo:
           - se re-arma el autologon de "usuario",
           - una tarea programada (IAC-IESMHP-Reanudar) relanza este script con
             -Reanudar en una ventana visible tras cada reinicio,
           - la FASE se guarda en HKLM\SOFTWARE\IAC-IESMHP para continuar donde
             se quedo.
      5) Compactado = LimpiaW11.ps1 (limpieza + zero-fill DENTRO de Windows).
         OJO: CompactaW11.sh es un script Bash del HOST Linux (vmware-vdiskmanager
         con la VM apagada); NO se ejecuta aqui.
      6) Finalizar: se APAGA el autologon -> el equipo arranca en la PANTALLA DE
         INICIO DE SESION (req 2 / "bloqueo por defecto de usuario"), se borra la
         tarea de reanudacion y se escribe el TIEMPO TOTAL.

  Tiempos: cada fase se anota en Tiempos.log (comun.ps1). Cada script escribe
  ademas su propio <script>.ps1.log a su lado (req 0).

  Idempotente y tolerante a fallos. Log: ...\1-Setup.ps1.log
  ============================================================================
#>
[CmdletBinding()]
param(
  # Lo pasa la tarea programada IAC-IESMHP-Reanudar tras cada reinicio de WU.
  [switch]$Reanudar
)

$ErrorActionPreference = 'Continue'

# --- Cargar comun.ps1 (logging, tiempos, fase, autologon, reanudacion) ------
$Here = $PSScriptRoot
if (-not $Here) { $Here = Split-Path -Parent $MyInvocation.MyCommand.Path }
$Comun = Join-Path $Here 'comun.ps1'
if (-not (Test-Path $Comun)) {
  Write-Host "ERROR: no encuentro comun.ps1 junto a 1-Setup.ps1 ($Comun)."
  Write-Host "comun.ps1 es un fichero del repo: hay que hacer commit+push a 'main' antes de arrancar la ISO."
  exit 1
}
. $Comun
Initialize-Log $PSCommandPath

# --- Rutas del repo --------------------------------------------------------
$RepoRoot = Split-Path (Split-Path $Here -Parent) -Parent   # ...\IAC-IESMHP
$CsvFile  = Join-Path $RepoRoot 'macs.csv'
$AuthSrc  = Join-Path $RepoRoot 'Autorizados.txt'

# ===========================================================================
#  Utilidades
# ===========================================================================
function ConvertTo-NormMac {
  param([string]$s)
  $h = (($s -replace '[^0-9A-Fa-f]', '')).ToLower()
  if ($h.Length -ne 12) { return $null }
  return (($h -split '(.{2})' | Where-Object { $_ }) -join ':')
}

function Invoke-Script {
  # Ejecuta un script hijo en la MISMA consola visible (su salida se ve) y como
  # proceso aparte (cada hijo carga comun.ps1 y escribe su propio .log).
  param([string]$Nombre)
  $ruta = Join-Path $Here $Nombre
  if (-not (Test-Path $ruta)) { Log "AVISO: no existe $ruta; me lo salto."; return }
  Log ">>> Ejecutando $Nombre ..."
  & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $ruta
  Log "<<< $Nombre termino con codigo $LASTEXITCODE"
}

# ===========================================================================
#  FASE 1 — Config basica: nombre + IP (macs.csv), OpenSSH, ENERGIA
# ===========================================================================
function Set-EnergiaAltoRendimiento {
  # Imita el rol Ansible energiaAltoRendimiento: activa el plan integrado "Alto
  # rendimiento" (GUID fijo, independiente del idioma) solo si no esta ya activo,
  # y desactiva la suspension del equipo (standby-timeout -ac y -dc = 0).
  $guid = '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c'
  try {
    $activo = (& powercfg /getactivescheme) 2>&1 | Out-String
    if ($activo -notmatch $guid) {
      & powercfg /setactive $guid | Out-Null
      Log "Energia: plan 'Alto rendimiento' activado ($guid)."
    } else {
      Log "Energia: 'Alto rendimiento' ya estaba activo."
    }
    & powercfg /change standby-timeout-ac 0 | Out-Null
    & powercfg /change standby-timeout-dc 0 | Out-Null
    Log "Energia: suspension desactivada (standby-timeout-ac/dc = 0)."
  } catch { Log "ERROR en energia: $($_.Exception.Message)" }
}

function Invoke-ConfigBasica {
  # ---- 1a) MAC -> nombre + IP estatica ----
  try {
    if (-not (Test-Path $CsvFile)) {
      Log "AVISO: no encuentro $CsvFile; me salto el renombrado/IP."
    } else {
      $macRe = '([0-9A-Fa-f]{2}[:-]){5}[0-9A-Fa-f]{2}'
      $map = @{}
      foreach ($line in Get-Content -Path $CsvFile) {
        $t = $line.Trim()
        if ($t -eq '' -or $t.StartsWith('#')) { continue }
        $f = $t -split ','
        if ($f.Count -lt 3) { continue }
        $rawMac = $f[0].Trim()
        if ($rawMac -notmatch ('^' + $macRe + '$')) { continue }   # cabecera/otras
        $mac = ConvertTo-NormMac $rawMac
        if (-not $mac) { continue }
        $name  = $f[1].Trim()
        $octet = $f[2].Trim()
        if ($name -eq '' -or $octet -notmatch '^\d{1,3}$') { continue }
        $map[$mac] = [pscustomobject]@{ Name = $name; Octet = [int]$octet }
      }
      Log "macs.csv: $($map.Count) equipos en el listado."

      $entry = $null; $adapter = $null
      foreach ($a in (Get-NetAdapter -ErrorAction SilentlyContinue)) {
        $nmac = ConvertTo-NormMac $a.MacAddress
        if ($nmac -and $map.ContainsKey($nmac)) { $entry = $map[$nmac]; $adapter = $a; break }
      }

      if (-not $entry) {
        Log "Ninguna MAC del equipo esta en macs.csv; no se cambia nombre ni IP."
      } else {
        Log "Coincide '$($adapter.Name)' (MAC $($adapter.MacAddress)) -> Equipo=$($entry.Name) octeto=$($entry.Octet)"

        if ($env:COMPUTERNAME -ieq $entry.Name) {
          Log "El equipo ya se llama $($entry.Name); no se renombra."
        } else {
          try {
            Rename-Computer -NewName $entry.Name -Force -ErrorAction Stop
            Log "Renombrado a $($entry.Name) (efectivo tras el proximo reinicio; lo hara Windows Update)."
          } catch { Log "ERROR al renombrar: $($_.Exception.Message)" }
        }

        $idx = $adapter.ifIndex
        $cfg = Get-NetIPConfiguration -InterfaceIndex $idx -ErrorAction SilentlyContinue
        $ipObj = Get-NetIPAddress -InterfaceIndex $idx -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                 Where-Object { $_.IPAddress -notlike '169.254*' -and $_.IPAddress -ne '127.0.0.1' } |
                 Select-Object -First 1

        if (-not $ipObj) {
          Log "AVISO: la NIC no tiene IPv4 valida (sin lease DHCP?); no se fija IP estatica."
        } else {
          $curIP  = $ipObj.IPAddress
          $prefix = [int]$ipObj.PrefixLength
          $gw     = $null
          if ($cfg -and $cfg.IPv4DefaultGateway) { $gw = ($cfg.IPv4DefaultGateway | Select-Object -First 1).NextHop }
          $dns    = @((Get-DnsClientServerAddress -InterfaceIndex $idx -AddressFamily IPv4 -ErrorAction SilentlyContinue).ServerAddresses)

          $oct = $curIP.Split('.')
          $newIP = '{0}.{1}.{2}.{3}' -f $oct[0], $oct[1], $oct[2], $entry.Octet
          Log "IP actual=$curIP/$prefix gw=$gw dns=$($dns -join ',') -> nueva estatica=$newIP"

          try {
            Set-NetIPInterface -InterfaceIndex $idx -AddressFamily IPv4 -Dhcp Disabled -ErrorAction SilentlyContinue
            Get-NetRoute -InterfaceIndex $idx -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
              Remove-NetRoute -Confirm:$false -ErrorAction SilentlyContinue
            Get-NetIPAddress -InterfaceIndex $idx -AddressFamily IPv4 -ErrorAction SilentlyContinue |
              Remove-NetIPAddress -Confirm:$false -ErrorAction SilentlyContinue

            if ($gw) {
              New-NetIPAddress -InterfaceIndex $idx -IPAddress $newIP -PrefixLength $prefix -DefaultGateway $gw -ErrorAction Stop | Out-Null
            } else {
              New-NetIPAddress -InterfaceIndex $idx -IPAddress $newIP -PrefixLength $prefix -ErrorAction Stop | Out-Null
            }
            if ($dns -and $dns.Count -gt 0) {
              Set-DnsClientServerAddress -InterfaceIndex $idx -ServerAddresses $dns -ErrorAction SilentlyContinue
            }
            Log "IP estatica $newIP/$prefix aplicada en '$($adapter.Name)'."
          } catch { Log "ERROR al fijar la IP estatica: $($_.Exception.Message)" }
        }
      }
    }
  } catch { Log "ERROR en el bloque 1a (MAC/nombre/IP): $($_.Exception.Message)" }

  # ---- 1b) OpenSSH (cliente+servidor) + claves autorizadas ----
  try {
    Log "OpenSSH: instalando capacidades (si faltan)..."
    foreach ($cap in 'OpenSSH.Client', 'OpenSSH.Server') {
      $c = Get-WindowsCapability -Online -Name "$cap*" -ErrorAction SilentlyContinue | Select-Object -First 1
      if ($c -and $c.State -ne 'Installed') {
        try { Add-WindowsCapability -Online -Name $c.Name -ErrorAction Stop | Out-Null; Log "  + $($c.Name) instalado." }
        catch { Log "  ERROR instalando $cap : $($_.Exception.Message)" }
      } else {
        Log "  $cap ya instalado."
      }
    }

    Set-Service -Name sshd -StartupType Automatic -ErrorAction SilentlyContinue
    Start-Service sshd -ErrorAction SilentlyContinue
    Log "OpenSSH: servicio sshd en automatico e iniciado."

    $fwName = 'OpenSSH-Server-In-TCP'
    if (Get-NetFirewallRule -Name $fwName -ErrorAction SilentlyContinue) {
      Set-NetFirewallRule -Name $fwName -Enabled True -Action Allow -Profile Any -ErrorAction SilentlyContinue
      Log "OpenSSH: regla de firewall '$fwName' existente -> habilitada (Allow, todos los perfiles)."
    } else {
      New-NetFirewallRule -Name $fwName -DisplayName 'OpenSSH Server (sshd)' `
        -Enabled True -Direction Inbound -Protocol TCP -Action Allow -LocalPort 22 -Profile Any `
        -ErrorAction SilentlyContinue | Out-Null
      Log "OpenSSH: regla de firewall '$fwName' creada (puerto 22, todos los perfiles)."
    }

    if (-not (Test-Path 'HKLM:\SOFTWARE\OpenSSH')) { New-Item -Path 'HKLM:\SOFTWARE\OpenSSH' -Force | Out-Null }
    New-ItemProperty -Path 'HKLM:\SOFTWARE\OpenSSH' -Name DefaultShell `
      -Value 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe' -PropertyType String -Force | Out-Null
    Log "OpenSSH: DefaultShell = powershell.exe"

    $sshDir   = Join-Path $env:ProgramData 'ssh'
    $authFile = Join-Path $sshDir 'administrators_authorized_keys'
    if (-not (Test-Path $sshDir)) { New-Item -ItemType Directory -Force -Path $sshDir | Out-Null }

    if (-not (Test-Path $AuthSrc)) {
      Log "AVISO: no encuentro $AuthSrc; no se anaden claves."
    } else {
      $nuevas = Get-Content -Path $AuthSrc | Where-Object { $_.Trim() -ne '' -and -not $_.Trim().StartsWith('#') }
      $exist  = @()
      if (Test-Path $authFile) { $exist = Get-Content -Path $authFile | Where-Object { $_.Trim() -ne '' } }
      $add = 0
      foreach ($k in $nuevas) {
        $kk = $k.Trim()
        if ($exist -notcontains $kk) {
          Add-Content -Path $authFile -Value $kk -Encoding Ascii
          $exist += $kk; $add++
        }
      }
      Log "OpenSSH: $add clave(s) nueva(s) anadida(s) a administrators_authorized_keys."

      & icacls $authFile /inheritance:r            | Out-Null
      & icacls $authFile /grant '*S-1-5-18:F'      | Out-Null   # SYSTEM
      & icacls $authFile /grant '*S-1-5-32-544:F'  | Out-Null   # Administradores (cualquier idioma)
      Log "OpenSSH: permisos (icacls) aplicados a $authFile."
    }
  } catch { Log "ERROR en el bloque 1b (OpenSSH): $($_.Exception.Message)" }

  # ---- 1c) Energia "Alto rendimiento" ----
  Set-EnergiaAltoRendimiento
}

# ===========================================================================
#  FASE 4 — Windows Update (con reanudacion tras reinicios)
# ===========================================================================
function Get-WUReinicios {
  try { return [int](Get-ItemProperty -Path $IAC_REGKEY -Name WUReinicios -ErrorAction Stop).WUReinicios } catch { return 0 }
}
function Set-WUReinicios {
  param([int]$n)
  if (-not (Test-Path $IAC_REGKEY)) { New-Item -Path $IAC_REGKEY -Force | Out-Null }
  New-ItemProperty -Path $IAC_REGKEY -Name WUReinicios -Value $n -PropertyType DWord -Force | Out-Null
}

function Initialize-PSWindowsUpdate {
  if (Get-Module -ListAvailable -Name PSWindowsUpdate) { return $true }
  try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Log "Windows Update: instalando el modulo PSWindowsUpdate (NuGet + PSGallery)..."
    Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -ErrorAction SilentlyContinue | Out-Null
    if (Get-Command Set-PSRepository -ErrorAction SilentlyContinue) {
      Set-PSRepository -Name PSGallery -InstallationPolicy Trusted -ErrorAction SilentlyContinue
    }
    Install-Module -Name PSWindowsUpdate -Force -Scope AllUsers -AllowClobber -ErrorAction Stop
    return [bool](Get-Module -ListAvailable -Name PSWindowsUpdate)
  } catch {
    Log "ERROR instalando PSWindowsUpdate: $($_.Exception.Message)"
    return $false
  }
}

function Invoke-WindowsUpdatePass {
  # Instala todas las actualizaciones disponibles. Devuelve:
  #   $true  -> hace falta REINICIAR (el llamador reinicia; la tarea reanuda).
  #   $false -> Windows Update ha terminado (no quedan updates ni reinicio).
  if (-not (Initialize-PSWindowsUpdate)) {
    Log "Sin PSWindowsUpdate disponible; me salto Windows Update."
    return $false
  }
  Import-Module PSWindowsUpdate -ErrorAction SilentlyContinue

  for ($i = 1; $i -le 10; $i++) {
    $pend = @()
    try { $pend = @(Get-WindowsUpdate -ErrorAction SilentlyContinue) } catch { Log "Get-WindowsUpdate fallo: $($_.Exception.Message)" }
    if ($pend.Count -eq 0) { Log "Windows Update: no quedan actualizaciones pendientes."; return $false }

    Log "Windows Update: $($pend.Count) actualizacion(es) pendiente(s); instalando..."
    try {
      Get-WindowsUpdate -Install -AcceptAll -IgnoreReboot -ErrorAction SilentlyContinue |
        ForEach-Object { Log ("  WU: {0} {1}" -f $_.KB, $_.Title) }
    } catch { Log "Windows Update: la instalacion devolvio error: $($_.Exception.Message)" }

    $reboot = $false
    try { $reboot = [bool](Get-WURebootStatus -Silent) } catch {}
    if ($reboot) { return $true }
    # Sin reinicio pendiente: vuelve a comprobar por si han aparecido mas.
  }
  Log "Windows Update: limite de pasadas en este arranque; continuo."
  return $false
}

# ===========================================================================
#  FASE 5 — Compactado (LimpiaW11.ps1) DENTRO de Windows
# ===========================================================================
function Invoke-Compactado {
  # El compactado real del VMDK lo hace CompactaW11.sh en el HOST Linux (con la
  # VM apagada). Dentro de Windows ejecutamos su contraparte LimpiaW11.ps1
  # (limpieza + zero-fill) para dejar el disco listo para esa compactacion.
  $limpia = Join-Path $RepoRoot 'W11\Utiles\Compacta\LimpiaW11.ps1'
  if (-not (Test-Path $limpia)) { Log "AVISO: no existe $limpia; me salto el compactado."; return }

  # LimpiaW11.ps1 ABORTA si no encuentra sdelete64.exe (el zero-fill se hace solo
  # con esa herramienta). Lo aseguramos por winget antes de llamarla (best-effort).
  try {
    $env:Path = [Environment]::GetEnvironmentVariable('Path','Machine') + ';' +
                [Environment]::GetEnvironmentVariable('Path','User') + ';' +
                (Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps')
    $wg = Get-Command winget.exe -ErrorAction SilentlyContinue
    if ($wg -and -not (Get-Command sdelete64.exe -ErrorAction SilentlyContinue)) {
      Log "Instalando SDelete (Sysinternals) para el zero-fill de LimpiaW11..."
      & $wg.Source install --id Microsoft.Sysinternals.SDelete -e `
          --accept-package-agreements --accept-source-agreements --silent
    }
  } catch { Log "AVISO: no pude asegurar SDelete: $($_.Exception.Message)" }

  Log ">>> Ejecutando LimpiaW11.ps1 (limpieza + zero-fill)..."
  & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $limpia
  Log "<<< LimpiaW11.ps1 termino con codigo $LASTEXITCODE"
}

# ===========================================================================
#  PROGRAMA PRINCIPAL — maquina de estados con reanudacion tras reinicios
# ===========================================================================
Log "===== 1-Setup.ps1 inicio (Reanudar=$Reanudar) ====="
$t0 = Get-InstallStart
if ($t0) { Log "Windows instalado (T0 de referencia): $t0" }
$fase = Get-Fase
Log "Fase actual: $(if ($fase) { $fase } else { '(ninguna: primera pasada)' })"

# ---- PRIMERA PASADA: config + apps + particionado (sin reinicios) ----------
if (-not $Reanudar -and -not $fase) {
  $st = Get-Date; Invoke-ConfigBasica;            Add-Tiempo -Fase 'setup (nombre/IP/SSH/energia)' -Inicio $st
  $st = Get-Date; Invoke-Script '2-Aplicaciones.ps1'; Add-Tiempo -Fase 'aplicaciones'              -Inicio $st
  $st = Get-Date; Invoke-Script '3-Particionado.ps1'; Add-Tiempo -Fase 'particionado'             -Inicio $st

  # Preparar Windows Update (puede reiniciar varias veces): armar reanudacion.
  Set-WUReinicios 0
  Set-Marca 'winupdate'
  Set-Fase  'winupdate'
  Enable-Autologon
  Register-Resume
  Log "Reanudacion preparada (autologon re-armado + tarea $IAC_TASK)."
}

# ---- FASE WINDOWS UPDATE (entrada normal o reanudada tras reinicio) --------
if ((Get-Fase) -eq 'winupdate') {
  if (Invoke-WindowsUpdatePass) {
    $n = (Get-WUReinicios) + 1
    Set-WUReinicios $n
    Log "Windows Update requiere reinicio (#$n). Reiniciando; la tarea $IAC_TASK reanudara..."
    Start-Sleep -Seconds 3
    Restart-Computer -Force
    exit 0
  }
  Add-Tiempo -Fase 'windows update' -Inicio (Get-Marca 'winupdate')
  Set-Fase 'compactado'
}

# ---- FASE COMPACTADO -------------------------------------------------------
if ((Get-Fase) -eq 'compactado') {
  $st = Get-Date
  Invoke-Compactado
  Add-Tiempo -Fase 'compactado (LimpiaW11)' -Inicio $st
  Set-Fase 'finalizar'
}

# ---- FASE FINALIZAR: pantalla de login + limpieza + tiempo total -----------
if ((Get-Fase) -eq 'finalizar') {
  Unregister-Resume
  Disable-Autologon
  Log "Autologon desactivado: el equipo arrancara en la PANTALLA DE INICIO DE SESION."
  Write-TiempoTotal
  Clear-Fase
  Log "===== 1-Setup.ps1 FIN (configuracion completa) ====="
}
