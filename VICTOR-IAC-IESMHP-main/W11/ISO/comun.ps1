#Requires -Version 5.1
<#
  comun.ps1  -  Funciones y constantes compartidas de IAC-IESMHP (Windows 11)
  ============================================================================
  Unica fuente de verdad (equivalente Windows de Ubuntu/ISO/26.04/comun.sh) de:

    - Rutas del proyecto (RAIZ, carpeta ISO, Tiempos.log, clave de registro).
    - LOGGING "al lado de cada script": cada fichero escribe su log junto a si
      mismo con el mismo nombre + .log  (p. ej. 1-Setup.ps1 -> 1-Setup.ps1.log).
    - CONTROL DE TIEMPOS centralizado en Tiempos.log: marca de inicio de la
      instalacion de Windows (T0), duracion de cada fase y total al finalizar.
    - Utilidades de ORQUESTACION que sobreviven a los reinicios de Windows
      Update: fase del pipeline (registro), autologon (re-armar / apagar) y la
      tarea programada de reanudacion.

  Lo cargan (dot-source) 1-Setup.ps1, 2-Aplicaciones.ps1, 3-Particionado.ps1 y,
  tras clonar el repo, 0b-GitHub.ps1:

      . (Join-Path $PSScriptRoot 'comun.ps1')

  Para cambiar una ruta o el usuario de autologon, editar SOLO este fichero.
  ============================================================================
#>

# --- Rutas del proyecto ----------------------------------------------------
$Global:IAC_ROOT    = 'C:\Program Files\IAC-IESMHP'
$Global:IAC_ISO_DIR = Join-Path $IAC_ROOT 'W11\ISO'
$Global:IAC_TIEMPOS = Join-Path $IAC_ISO_DIR 'Tiempos.log'
$Global:IAC_REGKEY  = 'HKLM:\SOFTWARE\IAC-IESMHP'

# Cuenta de autologon de la ISO (definida en autounattend.xml). Se usa para
# RE-ARMAR el autologon entre reinicios de Windows Update y poder reanudar el
# pipeline en una sesion VISIBLE. Se BORRA al finalizar (pantalla de login).
$Global:IAC_AUTOLOGON_USER = 'usuario'
$Global:IAC_AUTOLOGON_PASS = 'usuario@1'

# ===========================================================================
#  LOGGING — un fichero <script>.ps1.log junto a cada script (req 0)
# ===========================================================================
function Initialize-Log {
  # Fija el log de ESTE script: misma ruta y nombre + ".log".
  param([Parameter(Mandatory)][string]$ScriptPath)
  $Global:IAC_LOG = "$ScriptPath.log"
  $dir = Split-Path $Global:IAC_LOG -Parent
  if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
}

function Log {
  param([string]$Msg)
  $line = '{0}  {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Msg
  Write-Host $line
  if ($Global:IAC_LOG) {
    try { Add-Content -Path $Global:IAC_LOG -Value $line -Encoding UTF8 } catch {}
  }
}

# ===========================================================================
#  CONTROL DE TIEMPOS — Tiempos.log (req 1)
# ===========================================================================
function Format-Dur {
  # Formatea un TimeSpan como HH:MM:SS (admite > 24 h).
  param([TimeSpan]$d)
  return ('{0:00}:{1:00}:{2:00}' -f [math]::Floor($d.TotalHours), $d.Minutes, $d.Seconds)
}

function Get-InstallStart {
  # T0 = instante en que se instalo Windows (referencia para el tiempo total).
  # Fuente fiable e independiente del idioma: Win32_OperatingSystem.InstallDate,
  # espejo del registro HKLM\...\CurrentVersion\InstallDate (epoch Unix, UTC).
  try {
    return (Get-CimInstance Win32_OperatingSystem -ErrorAction Stop).InstallDate
  } catch {
    try {
      $secs = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -Name InstallDate -ErrorAction Stop).InstallDate
      return ([DateTimeOffset]::FromUnixTimeSeconds([int64]$secs)).LocalDateTime
    } catch { return $null }
  }
}

function Add-Tiempo {
  # Anota una fase en Tiempos.log (y un resumen en el log del script).
  param(
    [Parameter(Mandatory)][string]$Fase,
    [datetime]$Inicio,
    [datetime]$Fin = (Get-Date)
  )
  if (-not $Inicio) { $Inicio = $Fin }
  $dur = $Fin - $Inicio
  $linea = '{0} | {1,-24} | inicio {2:yyyy-MM-dd HH:mm:ss} | fin {3:yyyy-MM-dd HH:mm:ss} | duracion {4}' -f `
           (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Fase, $Inicio, $Fin, (Format-Dur $dur)
  try { Add-Content -Path $IAC_TIEMPOS -Value $linea -Encoding UTF8 } catch {}
  Log "TIEMPO [$Fase] = $(Format-Dur $dur)"
}

function Write-TiempoTotal {
  # Linea final de Tiempos.log: desde la instalacion de Windows (T0) hasta ahora.
  $t0  = Get-InstallStart
  $now = Get-Date
  if (-not $t0) { return }
  $dur = $now - $t0
  $linea = '{0} | {1,-24} | inicio {2:yyyy-MM-dd HH:mm:ss} | fin {3:yyyy-MM-dd HH:mm:ss} | duracion {4}' -f `
           $now.ToString('yyyy-MM-dd HH:mm:ss'), 'TOTAL (desde install)', $t0, $now, (Format-Dur $dur)
  try { Add-Content -Path $IAC_TIEMPOS -Value $linea -Encoding UTF8 } catch {}
  Log "TIEMPO TOTAL desde la instalacion de Windows: $(Format-Dur $dur)"
}

# ===========================================================================
#  ESTADO DEL PIPELINE — fase y marcas de inicio (sobreviven a los reinicios)
# ===========================================================================
function Get-Fase {
  try { return (Get-ItemProperty -Path $IAC_REGKEY -Name Fase -ErrorAction Stop).Fase } catch { return $null }
}
function Set-Fase {
  param([Parameter(Mandatory)][string]$Fase)
  if (-not (Test-Path $IAC_REGKEY)) { New-Item -Path $IAC_REGKEY -Force | Out-Null }
  New-ItemProperty -Path $IAC_REGKEY -Name Fase -Value $Fase -PropertyType String -Force | Out-Null
}
function Clear-Fase { try { Remove-ItemProperty -Path $IAC_REGKEY -Name Fase -ErrorAction SilentlyContinue } catch {} }

function Set-Marca {
  # Guarda una marca de tiempo (ISO 8601) que sobrevive a reinicios.
  param([Parameter(Mandatory)][string]$Nombre, [datetime]$Cuando = (Get-Date))
  if (-not (Test-Path $IAC_REGKEY)) { New-Item -Path $IAC_REGKEY -Force | Out-Null }
  New-ItemProperty -Path $IAC_REGKEY -Name "Marca_$Nombre" -Value $Cuando.ToString('o') -PropertyType String -Force | Out-Null
}
function Get-Marca {
  param([Parameter(Mandatory)][string]$Nombre)
  try { return [datetime]::Parse((Get-ItemProperty -Path $IAC_REGKEY -Name "Marca_$Nombre" -ErrorAction Stop)."Marca_$Nombre") } catch { return $null }
}

# ===========================================================================
#  AUTOLOGON — re-armar entre reinicios / apagar al finalizar (pantalla login)
# ===========================================================================
$Global:IAC_WINLOGON = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'

function Enable-Autologon {
  # Re-arma el autologon (usuario/clave de la ISO) para que, tras cada reinicio
  # de Windows Update, "usuario" inicie sesion solo y la tarea de reanudacion
  # continue el pipeline en una sesion VISIBLE.
  Set-ItemProperty -Path $IAC_WINLOGON -Name AutoAdminLogon  -Value '1'                  -ErrorAction SilentlyContinue
  Set-ItemProperty -Path $IAC_WINLOGON -Name DefaultUserName -Value $IAC_AUTOLOGON_USER  -ErrorAction SilentlyContinue
  Set-ItemProperty -Path $IAC_WINLOGON -Name DefaultPassword -Value $IAC_AUTOLOGON_PASS  -ErrorAction SilentlyContinue
  Remove-ItemProperty -Path $IAC_WINLOGON -Name AutoLogonCount -ErrorAction SilentlyContinue
}

function Disable-Autologon {
  # Apaga el autologon -> en el siguiente arranque aparece la PANTALLA DE INICIO
  # DE SESION (req 2 / "bloqueo por defecto de usuario"). Borra la clave en claro.
  Set-ItemProperty -Path $IAC_WINLOGON -Name AutoAdminLogon -Value '0' -ErrorAction SilentlyContinue
  Remove-ItemProperty -Path $IAC_WINLOGON -Name DefaultPassword -ErrorAction SilentlyContinue
  Remove-ItemProperty -Path $IAC_WINLOGON -Name AutoLogonCount  -ErrorAction SilentlyContinue
}

# ===========================================================================
#  TAREA DE REANUDACION — relanza 1-Setup.ps1 -Reanudar tras cada reinicio
# ===========================================================================
$Global:IAC_TASK = 'IAC-IESMHP-Reanudar'

function Register-Resume {
  # Crea (idempotente) una tarea programada que, al iniciar sesion "usuario",
  # relanza 1-Setup.ps1 -Reanudar en una ventana VISIBLE. Combinada con el
  # autologon re-armado, sobrevive a los reinicios de Windows Update.
  $setup   = Join-Path $IAC_ISO_DIR '1-Setup.ps1'
  $action  = New-ScheduledTaskAction  -Execute 'powershell.exe' `
             -Argument ('-NoProfile -ExecutionPolicy Bypass -WindowStyle Normal -File "{0}" -Reanudar' -f $setup)
  $trigger = New-ScheduledTaskTrigger -AtLogOn -User $IAC_AUTOLOGON_USER
  $princ   = New-ScheduledTaskPrincipal -UserId $IAC_AUTOLOGON_USER -LogonType Interactive -RunLevel Highest
  $set     = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable
  Register-ScheduledTask -TaskName $IAC_TASK -Action $action -Trigger $trigger -Principal $princ -Settings $set -Force | Out-Null
}

function Unregister-Resume {
  Unregister-ScheduledTask -TaskName $IAC_TASK -Confirm:$false -ErrorAction SilentlyContinue
}
