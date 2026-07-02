#Requires -Version 5.1
<#
  3-Particionado.ps1  -  Discos de datos + ubicacion de perfiles (D:\Users)
  ============================================================================
  Lo lanza 1-Setup.ps1 (4o paso de la cadena). Prepara los discos de DATOS del
  equipo (no el de sistema) y mueve la carpeta de perfiles por defecto a D:.

  Pasos:
    1) Si hay lector CD/DVD, lo mueve a R:.  Las unidades USB (extraibles) se
       reasignan a continuacion: S, T, U...
    2) Lista las unidades SIN FORMATEAR (disco crudo / sin particiones), NUNCA
       el disco de sistema ni discos USB. Las ordena por tipo:
           1o NVMe   2o SSD (SATA)   3o SATA/HDD
       y, dentro de cada tipo, de MAYOR a MENOR tamano.
    3) Las inicializa (GPT), crea una particion que ocupa todo el disco, la
       formatea como NTFS y les asigna letras CONSECUTIVAS a partir de la D
       (D, E, F, G...), saltando las letras ya en uso.
    4) Si existe la unidad D:, fija la carpeta de perfiles por defecto en
       D:\Users (afecta a los usuarios NUEVOS; el perfil existente de 'usuario'
       permanece en C:\Users).

  SEGURIDAD: solo toca discos CRUDOS / sin particiones que NO sean de sistema ni
  USB. En una VM de un solo disco no hay discos objetivo -> no hace nada (seguro).
  Tolerante a fallos. Log al lado del script (req 0).
  ============================================================================
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Continue'

# --- comun.ps1 (logging) ---------------------------------------------------
$Here  = $PSScriptRoot
if (-not $Here) { $Here = Split-Path -Parent $MyInvocation.MyCommand.Path }
$Comun = Join-Path $Here 'comun.ps1'
if (Test-Path $Comun) { . $Comun; Initialize-Log $PSCommandPath }
else {
  $Global:IAC_LOG = "$PSCommandPath.log"
  function Log { param([string]$m) $l='{0}  {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'),$m; Write-Host $l; try { Add-Content -Path $Global:IAC_LOG -Value $l -Encoding UTF8 } catch {} }
}

Log "===== 3-Particionado.ps1 inicio ====="

# ===========================================================================
#  Utilidades de letras de unidad
# ===========================================================================
function Get-LetrasUsadas {
  $used = @()
  foreach ($v in (Get-Volume -ErrorAction SilentlyContinue)) {
    if ($v.DriveLetter) { $used += ([string]$v.DriveLetter).ToUpper() }
  }
  foreach ($p in (Get-Partition -ErrorAction SilentlyContinue)) {
    if ($p.DriveLetter) { $used += ([string]$p.DriveLetter).ToUpper() }
  }
  return @($used | Select-Object -Unique)
}

function Get-LetraLibre {
  # Primera letra libre >= $Desde (ascendente) o <= $Desde (descendente).
  param([char]$Desde = 'D', [switch]$Descendente)
  $used = Get-LetrasUsadas
  if ($Descendente) {
    for ($c = [byte][char]$Desde; $c -ge [byte][char]'D'; $c--) {
      $L = [string][char]$c
      if ($used -notcontains $L) { return [char]$c }
    }
  } else {
    for ($c = [byte][char]$Desde; $c -le [byte][char]'Z'; $c++) {
      $L = [string][char]$c
      if ($used -notcontains $L) { return [char]$c }
    }
  }
  return $null
}

function Set-LetraVolumen {
  # Reasigna la letra de un Win32_Volume (vale para CD/DVD y extraibles).
  param($vol, [char]$Letra)
  $actual = if ($vol.DriveLetter) { ([string]$vol.DriveLetter).ToUpper().TrimEnd(':') } else { '' }
  if ($actual -eq [string]$Letra) { Log "  $($vol.DriveLetter) ya esta en $($Letra):; no se mueve."; return $true }
  try {
    Set-CimInstance -InputObject $vol -Property @{ DriveLetter = "$($Letra):" } -ErrorAction Stop
    Log "  $($vol.DriveLetter) '$($vol.Label)' -> $($Letra):"
    return $true
  } catch {
    Log "  no pude asignar $($Letra): (origen $($vol.DriveLetter) '$($vol.Label)'): $($_.Exception.Message)"
    return $false
  }
}

# ===========================================================================
#  PASO 1 — CD/DVD -> R: ; USB extraibles -> S, T, U...
# ===========================================================================
Log "Paso 1/4: reasignando lectores opticos (R:) y unidades USB (S, T...)."

# Opticos (DriveType=5): el primero a R:, extras descendiendo (Q, P...).
$opticos = @(Get-CimInstance -ClassName Win32_Volume -Filter 'DriveType=5' -ErrorAction SilentlyContinue)
$letraOpt = [char]'R'
foreach ($cd in $opticos) {
  $libre = $letraOpt
  # si R esta ocupada por otra cosa, busca descendente
  if ((Get-LetrasUsadas) -contains [string]$letraOpt -and (([string]$cd.DriveLetter).ToUpper().TrimEnd(':') -ne [string]$letraOpt)) {
    $libre = Get-LetraLibre -Desde 'R' -Descendente
  }
  if ($libre) { Set-LetraVolumen -vol $cd -Letra $libre | Out-Null; $letraOpt = [char]([byte][char]$libre - 1) }
}
if ($opticos.Count -eq 0) { Log "  no hay lectores CD/DVD." }

# USB extraibles (DriveType=2): S, T, U... ascendente.
$usb = @(Get-CimInstance -ClassName Win32_Volume -Filter 'DriveType=2' -ErrorAction SilentlyContinue)
$letraUsb = [char]'S'
foreach ($u in $usb) {
  $libre = Get-LetraLibre -Desde $letraUsb
  if ($libre) { Set-LetraVolumen -vol $u -Letra $libre | Out-Null; $letraUsb = [char]([byte][char]$libre + 1) }
}
if ($usb.Count -eq 0) { Log "  no hay unidades USB extraibles." }

# ===========================================================================
#  PASO 2 — Clasificar discos SIN FORMATEAR (NVMe -> SSD -> SATA, mayor->menor)
# ===========================================================================
Log "Paso 2/4: detectando discos sin formatear (no sistema, no USB)."

function Get-CategoriaDisco {
  # 0 = NVMe, 1 = SSD (SATA), 2 = SATA/HDD/otros.
  param($busType, $mediaType)
  if ($busType -eq 'NVMe')   { return 0 }
  if ($mediaType -eq 'SSD')  { return 1 }
  return 2
}
$catNombre = @('NVMe', 'SSD', 'SATA/HDD')

$objetivos = New-Object System.Collections.Generic.List[object]
foreach ($d in (Get-Disk -ErrorAction SilentlyContinue)) {
  # Excluir sistema/arranque
  if ($d.IsBoot -or $d.IsSystem) { continue }
  # Excluir USB
  if ($d.BusType -eq 'USB') { continue }
  # Solo discos CRUDOS / sin particiones (sin formatear)
  $vacio = ($d.PartitionStyle -eq 'RAW') -or ($d.NumberOfPartitions -eq 0)
  if (-not $vacio) {
    Log "  disco #$($d.Number) ya tiene particiones/datos ($($d.PartitionStyle), $($d.NumberOfPartitions) part.); se omite."
    continue
  }
  $phys = Get-PhysicalDisk -ErrorAction SilentlyContinue | Where-Object { $_.DeviceId -eq $d.Number } | Select-Object -First 1
  $bus  = if ($phys) { $phys.BusType }   else { $d.BusType }
  $med  = if ($phys) { $phys.MediaType } else { 'Unspecified' }
  $cat  = Get-CategoriaDisco $bus $med
  $objetivos.Add([pscustomobject]@{
    Number = $d.Number; Size = $d.Size; BusType = $bus; MediaType = $med
    Categoria = $cat; CatNombre = $catNombre[$cat]
  }) | Out-Null
  Log "  candidato: disco #$($d.Number)  $([math]::Round($d.Size/1GB,1)) GB  bus=$bus media=$med -> $($catNombre[$cat])"
}

if ($objetivos.Count -eq 0) {
  Log "No hay discos sin formatear que preparar. (Normal en una VM de un solo disco.)"
} else {
  # Orden: categoria asc (NVMe<SSD<SATA), luego tamano DESC.
  $ordenados = $objetivos | Sort-Object @{Expression='Categoria';Ascending=$true}, @{Expression='Size';Ascending=$false}

  # =========================================================================
  #  PASO 3 — Formatear NTFS y asignar letras D, E, F...
  # =========================================================================
  Log "Paso 3/4: formateando NTFS y asignando letras desde D:."
  $idx = 1
  foreach ($o in $ordenados) {
    $letra = Get-LetraLibre -Desde 'D'
    if (-not $letra) { Log "  sin letras libres a partir de D:; me detengo."; break }
    Log "  disco #$($o.Number) [$($o.CatNombre), $([math]::Round($o.Size/1GB,1)) GB] -> $($letra):"
    try {
      if ((Get-Disk -Number $o.Number).PartitionStyle -eq 'RAW') {
        Initialize-Disk -Number $o.Number -PartitionStyle GPT -ErrorAction Stop | Out-Null
      }
      $part = New-Partition -DiskNumber $o.Number -UseMaximumSize -DriveLetter $letra -ErrorAction Stop
      Format-Volume -DriveLetter $letra -FileSystem NTFS -NewFileSystemLabel ("Datos{0}" -f $idx) `
                    -Confirm:$false -Force -ErrorAction Stop | Out-Null
      Log "  OK disco #$($o.Number) formateado NTFS en $($letra): (etiqueta Datos$idx)."
      $idx++
    } catch {
      Log "  FALLO preparando disco #$($o.Number): $($_.Exception.Message); continuo."
    }
  }
}

# ===========================================================================
#  PASO 4 — Carpeta de perfiles por defecto en D:\Users (si existe D:)
# ===========================================================================
Log "Paso 4/4: ubicacion de perfiles por defecto."
$volD = Get-Volume -DriveLetter 'D' -ErrorAction SilentlyContinue
if ($volD -and $volD.DriveType -eq 'Fixed') {
  try {
    $dUsers = 'D:\Users'
    if (-not (Test-Path $dUsers)) { New-Item -ItemType Directory -Force -Path $dUsers | Out-Null }
    $pl = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList'
    New-ItemProperty -Path $pl -Name ProfilesDirectory -Value $dUsers -PropertyType ExpandString -Force | Out-Null
    Log "Perfiles por defecto -> $dUsers (solo afecta a usuarios NUEVOS; 'usuario' sigue en C:\Users)."
  } catch { Log "ERROR fijando ProfilesDirectory en D:\Users: $($_.Exception.Message)" }
} else {
  Log "No existe una unidad D: fija; NO se cambia la carpeta de perfiles (se deja en C:\Users)."
}

Log "===== 3-Particionado.ps1 fin ====="
