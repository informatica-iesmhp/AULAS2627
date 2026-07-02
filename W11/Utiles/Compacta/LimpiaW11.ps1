#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Limpia Windows 11 para maximizar el espacio libre antes de compactar un VMDK de VMware.

.DESCRIPTION
    Ejecutar dentro de la VM Windows 11 como Administrador.
    Realiza limpieza de temporales, WinSxS, papelera, prefetch, minidumps,
    caches de miniaturas, hiberfil.sys, event logs, puntos de restauracion y
    finalmente rellena el espacio libre con ceros (sdelete64 -z) para que
    vmware-vdiskmanager -k pueda compactar eficientemente.

.NOTES
    Dependencia OBLIGATORIA: sdelete64.exe (Sysinternals).
    El script comprueba al inicio que sdelete64.exe esta disponible y, si no lo
    encuentra, avisa de como instalarlo y ABORTA sin tocar el sistema (no hay
    metodo de respaldo: el zero-fill se hace exclusivamente con sdelete64).
    Instalar con: winget install Microsoft.Sysinternals.SDelete
    O descargar desde: https://learn.microsoft.com/en-us/sysinternals/downloads/sdelete
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'   # continuar aunque falle un bloque individual

# --------------------------------------------------------------------------
# Log: todo lo que hace el script se vuelca a LimpiaW11.YYYYMMDD-HHMMSS.log
# (marca de tiempo de inicio en el nombre) junto al propio script.
# --------------------------------------------------------------------------
$logStamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$logDir   = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
$logFile  = Join-Path $logDir "LimpiaW11.$logStamp.log"
try {
    Start-Transcript -Path $logFile | Out-Null
    Write-Host "Log: $logFile" -ForegroundColor DarkGray
} catch {
    Write-Host "No se pudo iniciar el log en $logFile : $_" -ForegroundColor Yellow
}

# --------------------------------------------------------------------------
# Funciones auxiliares
# --------------------------------------------------------------------------

function Get-FreeSpaceGB {
    param([string]$Drive = 'C:')
    $disk = Get-PSDrive -Name ($Drive.TrimEnd(':')) -ErrorAction SilentlyContinue
    if ($disk) { return [math]::Round($disk.Free / 1GB, 2) }
    return 0
}

function Remove-ItemsSilent {
    <#
    Borra los items indicados sin abortar si alguno esta en uso.
    Devuelve el numero de items eliminados.
    #>
    param([string[]]$Paths)
    $count = 0
    foreach ($p in $Paths) {
        try {
            if (Test-Path $p) {
                Remove-Item -Path $p -Recurse -Force -ErrorAction SilentlyContinue
                $count++
            }
        } catch { }
    }
    return $count
}

function Write-Bloque {
    param([string]$Titulo)
    Write-Host ""
    Write-Host "=== $Titulo ===" -ForegroundColor Cyan
}

function Write-Resultado {
    param([string]$Texto, [string]$Color = 'Green')
    Write-Host "    $Texto" -ForegroundColor $Color
}

function Get-DiscosFijos {
    <#
    Devuelve las letras (ej. 'C:') de TODAS las unidades de disco fijo locales,
    excluyendo USB, unidades de red, CD/DVD y disquetes. Asi el zero-fill cubre
    todos los discos del Windows, no solo C:.
    #>
    $letras = @()
    # DriveType=3 => disco fijo local (excluye removibles, red y CD-ROM)
    $volumenes = Get-CimInstance -ClassName Win32_LogicalDisk -Filter 'DriveType=3' -ErrorAction SilentlyContinue
    foreach ($v in $volumenes) {
        $letra = $v.DeviceID            # 'C:'
        $esUSB = $false
        # Un disco fijo puede estar conectado por USB (DriveType sigue siendo 3):
        # se descarta consultando el bus del disco fisico subyacente.
        try {
            $part = Get-Partition -DriveLetter ($letra.TrimEnd(':')) -ErrorAction SilentlyContinue
            if ($part) {
                $disk = Get-Disk -Number $part.DiskNumber -ErrorAction SilentlyContinue
                if ($disk -and $disk.BusType -eq 'USB') { $esUSB = $true }
            }
        } catch { }
        if ($esUSB) {
            Write-Resultado "Omitida $letra (disco conectado por USB)" 'Gray'
        } else {
            $letras += $letra
        }
    }
    return $letras
}

function Invoke-ZeroFillDrive {
    <#
    Defragmenta (consolidacion) y rellena de ceros el espacio libre de una unidad
    usando exclusivamente sdelete64 ($script:sdeleteExe, garantizado al inicio).
    #>
    param([string]$Drive)

    Write-Host ""
    Write-Host "--- $Drive  defrag de consolidacion (defrag $Drive /X) ---" -ForegroundColor Magenta
    try {
        & defrag.exe $Drive /X /H /U /V
        Write-Resultado "Defrag de consolidacion de $Drive completado"
    } catch {
        Write-Resultado "Aviso ejecutando defrag en $Drive : $_" 'Yellow'
    }

    Write-Host "--- $Drive  zero-fill del espacio libre ---" -ForegroundColor Magenta
    Write-Host "    Ejecutando: $($script:sdeleteExe) -accepteula -z $Drive (puede tardar)" -ForegroundColor Gray
    try {
        & $script:sdeleteExe -accepteula -z $Drive
        Write-Resultado "Zero-fill de $Drive completado."
    } catch {
        Write-Resultado "Error ejecutando sdelete64 en $Drive : $_" 'Red'
    }
}

# --------------------------------------------------------------------------
# Inicio
# --------------------------------------------------------------------------

Write-Host ""
Write-Host "================================================" -ForegroundColor Yellow
Write-Host "  LimpiaW11.ps1 - Preparacion para compactacion" -ForegroundColor Yellow
Write-Host "================================================" -ForegroundColor Yellow

# --------------------------------------------------------------------------
# REQUISITO OBLIGATORIO: sdelete64.exe (Sysinternals)
# El zero-fill se hace SOLO con sdelete64 (no hay metodo de respaldo). Se
# comprueba ANTES de cualquier limpieza: si no esta, se avisa de como
# instalarlo y se aborta sin tocar el sistema.
# --------------------------------------------------------------------------
Write-Host ""
Write-Host "=== Comprobando requisito: sdelete64.exe ===" -ForegroundColor Magenta

$script:sdeleteExe = $null
$candidatos = @(
    'sdelete64.exe',
    "$PSScriptRoot\sdelete64.exe",
    "$env:USERPROFILE\Downloads\sdelete64.exe",
    'C:\Tools\sdelete64.exe',
    'C:\Sysinternals\sdelete64.exe'
)
foreach ($c in $candidatos) {
    if (Get-Command $c -ErrorAction SilentlyContinue) { $script:sdeleteExe = $c; break }
    if (Test-Path $c) { $script:sdeleteExe = $c; break }
}

if (-not $script:sdeleteExe) {
    Write-Host ""
    Write-Host "  ERROR: sdelete64.exe NO encontrado." -ForegroundColor Red
    Write-Host "  Este script necesita sdelete64.exe para rellenar de ceros el espacio" -ForegroundColor Red
    Write-Host "  libre; sin ese paso, vmware-vdiskmanager -k no podra compactar el VMDK." -ForegroundColor Red
    Write-Host ""
    Write-Host "  Instalalo con winget:" -ForegroundColor Yellow
    Write-Host "      winget install Microsoft.Sysinternals.SDelete" -ForegroundColor Cyan
    Write-Host "  O descargalo manualmente desde Sysinternals:" -ForegroundColor Yellow
    Write-Host "      https://learn.microsoft.com/en-us/sysinternals/downloads/sdelete" -ForegroundColor Cyan
    Write-Host "  (descomprime SDelete.zip y deja sdelete64.exe junto a este script," -ForegroundColor Yellow
    Write-Host "   en el PATH, en C:\Tools o en C:\Sysinternals) y vuelve a ejecutar." -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  PROCESO DETENIDO. No se ha realizado ninguna limpieza." -ForegroundColor Red
    try { Stop-Transcript | Out-Null } catch { }
    exit 1
}
Write-Resultado "sdelete64 encontrado en: $($script:sdeleteExe)"

$espacioInicial = Get-FreeSpaceGB -Drive 'C:'
Write-Host ""
Write-Host "Espacio libre inicial en C:  $espacioInicial GB" -ForegroundColor White

# Detectar TODAS las unidades de disco fijo (no USB, no red) para el zero-fill final.
# La limpieza de bloques 1-13 es especifica del sistema (C:); el zero-fill cubre todos.
$discosFijos = @(Get-DiscosFijos)
$espacioInicialPorDisco = @{}
foreach ($d in $discosFijos) { $espacioInicialPorDisco[$d] = Get-FreeSpaceGB -Drive $d }
Write-Host "Unidades de disco fijo detectadas: $($discosFijos -join ', ')" -ForegroundColor White

# --------------------------------------------------------------------------
# BLOQUE 1: Temporales de usuario y sistema
# --------------------------------------------------------------------------
Write-Bloque "1/12  Temporales de usuario y sistema"

$tempPaths = @(
    $env:TEMP,
    $env:TMP,
    'C:\Windows\Temp'
)

# Temporales de todos los perfiles de usuario
$perfiles = Get-ChildItem 'C:\Users' -Directory -ErrorAction SilentlyContinue
foreach ($perfil in $perfiles) {
    $tempPaths += "$($perfil.FullName)\AppData\Local\Temp"
}

$borrados = 0
foreach ($ruta in ($tempPaths | Select-Object -Unique)) {
    if (Test-Path $ruta) {
        $items = Get-ChildItem $ruta -Recurse -Force -ErrorAction SilentlyContinue
        foreach ($item in $items) {
            try { Remove-Item $item.FullName -Force -Recurse -ErrorAction SilentlyContinue; $borrados++ } catch { }
        }
    }
}
Write-Resultado "Elementos procesados en carpetas Temp: $borrados"

# --------------------------------------------------------------------------
# BLOQUE 2: Cache de Windows Update (SoftwareDistribution\Download)
# --------------------------------------------------------------------------
Write-Bloque "2/13  Cache de Windows Update y Delivery Optimization"

# Detener wuauserv Y bits: BITS gestiona las descargas y puede mantener
# ficheros abiertos en SoftwareDistribution que impedirian su borrado.
Write-Resultado "Deteniendo wuauserv y bits..." 'Gray'
Stop-Service -Name wuauserv -Force -ErrorAction SilentlyContinue
Stop-Service -Name bits -Force -ErrorAction SilentlyContinue

$wuDir = 'C:\Windows\SoftwareDistribution\Download'
if (Test-Path $wuDir) {
    $items = Get-ChildItem $wuDir -Recurse -Force -ErrorAction SilentlyContinue
    $total = $items.Count
    foreach ($item in $items) {
        try { Remove-Item $item.FullName -Force -Recurse -ErrorAction SilentlyContinue } catch { }
    }
    Write-Resultado "Elementos procesados en SoftwareDistribution\Download: $total"
} else {
    Write-Resultado "Directorio no encontrado: $wuDir" 'Yellow'
}

# Cache de Delivery Optimization (descargas P2P de actualizaciones): puede
# ocupar varios GB. El cmdlet solo existe en algunas ediciones de Windows.
if (Get-Command Delete-DeliveryOptimizationCache -ErrorAction SilentlyContinue) {
    try {
        Delete-DeliveryOptimizationCache -Force -ErrorAction SilentlyContinue
        Write-Resultado "Cache de Delivery Optimization eliminada"
    } catch {
        Write-Resultado "Aviso al limpiar Delivery Optimization: $_" 'Yellow'
    }
} else {
    Write-Resultado "Cmdlet Delete-DeliveryOptimizationCache no disponible (omitido)" 'Gray'
}

Write-Resultado "Reiniciando wuauserv y bits..." 'Gray'
Start-Service -Name wuauserv -ErrorAction SilentlyContinue
Start-Service -Name bits -ErrorAction SilentlyContinue

# --------------------------------------------------------------------------
# BLOQUE 3: WinSxS / Component Store (DISM)
# --------------------------------------------------------------------------
Write-Bloque "3/13  WinSxS / Component Store (DISM - puede tardar varios minutos)"
Write-Host "    AVISO: /ResetBase es IRREVERSIBLE. Desinstalar actualizaciones no sera posible despues." -ForegroundColor Red
Write-Host "    Ejecutando DISM /StartComponentCleanup /ResetBase ..." -ForegroundColor Gray

try {
    $dismOutput = & DISM.exe /Online /Cleanup-Image /StartComponentCleanup /ResetBase 2>&1
    $exitCode = $LASTEXITCODE
    if ($exitCode -eq 0) {
        Write-Resultado "DISM /ResetBase completado correctamente (exit 0)"
    } else {
        Write-Resultado "DISM /ResetBase termino con codigo $exitCode (puede ser normal si no hay nada que limpiar)" 'Yellow'
    }
} catch {
    Write-Resultado "Error ejecutando DISM /ResetBase: $_" 'Red'
}

# /SPSuperseded: elimina componentes de service packs reemplazados (espacio extra)
Write-Host "    Ejecutando DISM /SPSuperseded ..." -ForegroundColor Gray
try {
    $null = & DISM.exe /Online /Cleanup-Image /SPSuperseded 2>&1
    $exitCode = $LASTEXITCODE
    if ($exitCode -eq 0) {
        Write-Resultado "DISM /SPSuperseded completado correctamente (exit 0)"
    } else {
        Write-Resultado "DISM /SPSuperseded termino con codigo $exitCode (normal si no hay service pack que limpiar)" 'Yellow'
    }
} catch {
    Write-Resultado "Error ejecutando DISM /SPSuperseded: $_" 'Yellow'
}

# --------------------------------------------------------------------------
# BLOQUE 4: Compresion CompactOS de los ficheros del sistema operativo
# --------------------------------------------------------------------------
Write-Bloque "4/13  Compresion CompactOS del sistema operativo"

# compact /compactos:always comprime los binarios del SO con XPRESS4K.
# Ahorro permanente de ~1-2 GB con impacto minimo en rendimiento en una VM.
Write-Host "    Ejecutando compact /compactos:always (puede tardar unos minutos)..." -ForegroundColor Gray
try {
    & compact.exe /compactos:always 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) {
        Write-Resultado "CompactOS activado (ficheros del SO comprimidos)"
    } else {
        Write-Resultado "compact termino con codigo $LASTEXITCODE" 'Yellow'
    }
} catch {
    Write-Resultado "Error ejecutando compact: $_" 'Yellow'
}

# --------------------------------------------------------------------------
# BLOQUE 5: Papelera de reciclaje
# --------------------------------------------------------------------------
Write-Bloque "5/13  Papelera de reciclaje (todos los perfiles)"

try {
    Clear-RecycleBin -Force -ErrorAction SilentlyContinue
    Write-Resultado "Papelera vaciada"
} catch {
    Write-Resultado "Aviso al vaciar papelera: $_" 'Yellow'
}

# --------------------------------------------------------------------------
# BLOQUE 5: Prefetch
# --------------------------------------------------------------------------
Write-Bloque "6/13  Prefetch"

$prefetchDir = 'C:\Windows\Prefetch'
if (Test-Path $prefetchDir) {
    $items = Get-ChildItem $prefetchDir -Force -ErrorAction SilentlyContinue
    $total = $items.Count
    foreach ($item in $items) {
        try { Remove-Item $item.FullName -Force -ErrorAction SilentlyContinue } catch { }
    }
    Write-Resultado "Elementos procesados en Prefetch: $total"
} else {
    Write-Resultado "Directorio Prefetch no encontrado (puede estar desactivado)" 'Yellow'
}

# --------------------------------------------------------------------------
# BLOQUE 6: Minidumps y memory.dmp
# --------------------------------------------------------------------------
Write-Bloque "7/13  Minidumps y volcados de memoria"

$dumpPaths = @(
    'C:\Windows\Minidump',
    'C:\Windows\LiveKernelReports'
)
$dumpFiles = @('C:\Windows\memory.dmp', 'C:\Windows\MEMORY.DMP')

$totalDumps = 0
foreach ($dir in $dumpPaths) {
    if (Test-Path $dir) {
        $items = Get-ChildItem $dir -Recurse -Force -ErrorAction SilentlyContinue
        foreach ($item in $items) {
            try { Remove-Item $item.FullName -Force -ErrorAction SilentlyContinue; $totalDumps++ } catch { }
        }
    }
}
foreach ($f in $dumpFiles) {
    if (Test-Path $f) {
        try { Remove-Item $f -Force -ErrorAction SilentlyContinue; $totalDumps++ } catch { }
    }
}
Write-Resultado "Volcados de memoria eliminados: $totalDumps"

# --------------------------------------------------------------------------
# BLOQUE 7: Thumbnails e Icon cache de todos los perfiles
# --------------------------------------------------------------------------
Write-Bloque "8/13  Thumbnails e Icon cache"

# Detener Explorer para liberar el iconcache
Write-Resultado "Deteniendo explorer.exe para liberar caches..." 'Gray'
Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 2

$totalThumb = 0
foreach ($perfil in $perfiles) {
    $thumbDir  = "$($perfil.FullName)\AppData\Local\Microsoft\Windows\Explorer"
    $iconCache = "$($perfil.FullName)\AppData\Local\IconCache.db"

    if (Test-Path $thumbDir) {
        $items = Get-ChildItem $thumbDir -Filter 'thumbcache_*.db' -Force -ErrorAction SilentlyContinue
        foreach ($item in $items) {
            try { Remove-Item $item.FullName -Force -ErrorAction SilentlyContinue; $totalThumb++ } catch { }
        }
    }
    if (Test-Path $iconCache) {
        try { Remove-Item $iconCache -Force -ErrorAction SilentlyContinue; $totalThumb++ } catch { }
    }
}

# Reiniciar Explorer
Write-Resultado "Reiniciando explorer.exe..." 'Gray'
Start-Process explorer.exe
Write-Resultado "Caches de miniaturas/iconos eliminados: $totalThumb"

# --------------------------------------------------------------------------
# BLOQUE 8: Hibernacion (hiberfil.sys)
# --------------------------------------------------------------------------
Write-Bloque "9/13  Hibernacion"

try {
    & powercfg.exe /h off 2>&1 | Out-Null
    Write-Resultado "Hibernacion desactivada (hiberfil.sys eliminado)"
} catch {
    Write-Resultado "Error desactivando hibernacion: $_" 'Red'
}

# --------------------------------------------------------------------------
# BLOQUE 9: Fichero de paginacion (pagefile.sys)
# --------------------------------------------------------------------------
Write-Bloque "10/13 Fichero de paginacion"

# Solo se reporta el tamano actual; no se elimina automaticamente para
# evitar inestabilidad. El usuario puede decidir reducirlo manualmente.
try {
    $cs = Get-CimInstance -ClassName Win32_ComputerSystem
    if ($cs.AutomaticManagedPagefile) {
        Write-Resultado "Pagefile gestionado automaticamente por Windows (tamano variable)" 'Gray'
    } else {
        $pf = Get-CimInstance -ClassName Win32_PageFileSetting -ErrorAction SilentlyContinue
        if ($pf) {
            foreach ($p in $pf) {
                Write-Resultado "Pagefile: $($p.Name)  Min=$($p.InitialSize)MB  Max=$($p.MaximumSize)MB" 'Gray'
            }
        }
    }
    Write-Resultado "NOTA: Eliminar el pagefile antes del zero-fill libera espacio adicional." 'Yellow'
    Write-Resultado "      Para hacerlo: Panel de control > Sistema > Configuracion avanzada > Rendimiento > Memoria virtual" 'Yellow'
} catch {
    Write-Resultado "No se pudo consultar el pagefile: $_" 'Yellow'
}

# --------------------------------------------------------------------------
# BLOQUE 10: Registros de eventos de Windows
# --------------------------------------------------------------------------
Write-Bloque "11/13 Registros de eventos de Windows"

try {
    $logs = Get-WinEvent -ListLog * -ErrorAction SilentlyContinue | Where-Object { $_.RecordCount -gt 0 }
    $cleared = 0
    foreach ($log in $logs) {
        try {
            [System.Diagnostics.Eventing.Reader.EventLogSession]::GlobalSession.ClearLog($log.LogName)
            $cleared++
        } catch { }
    }
    Write-Resultado "Registros de eventos vaciados: $cleared"
} catch {
    Write-Resultado "Error limpiando event logs: $_" 'Yellow'
}

# --------------------------------------------------------------------------
# BLOQUE 11: Puntos de restauracion del sistema
# --------------------------------------------------------------------------
Write-Bloque "12/13 Puntos de restauracion del sistema"

try {
    # Eliminar todos los puntos de restauracion excepto el mas reciente
    $puntos = Get-ComputerRestorePoint -ErrorAction SilentlyContinue
    if ($puntos -and $puntos.Count -gt 0) {
        $masReciente = ($puntos | Sort-Object CreationTime | Select-Object -Last 1).SequenceNumber
        Write-Resultado "Puntos encontrados: $($puntos.Count). Conservando el mas reciente (seq $masReciente)."
        # Usar vssadmin para eliminar sombras antiguas
        & vssadmin.exe Delete Shadows /For=C: /Oldest /Quiet 2>&1 | Out-Null
        Write-Resultado "Sombras de volumen antiguas eliminadas"
    } else {
        Write-Resultado "No se encontraron puntos de restauracion" 'Gray'
    }
} catch {
    Write-Resultado "Error gestionando puntos de restauracion: $_" 'Yellow'
}

# --------------------------------------------------------------------------
# BLOQUE 12: Cleanmgr (Liberador de espacio en disco)
# --------------------------------------------------------------------------
Write-Bloque "13/13 Cleanmgr (Liberador de espacio en disco)"

# Configurar la clave de registro para sagerun:1 (seleccionar todo)
try {
    $sagePath = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\VolumeCaches'
    $caches = Get-ChildItem $sagePath -ErrorAction SilentlyContinue
    foreach ($cache in $caches) {
        Set-ItemProperty -Path $cache.PSPath -Name 'StateFlags0001' -Value 2 -Type DWord -ErrorAction SilentlyContinue
    }

    Write-Resultado "Ejecutando cleanmgr /sagerun:1 (en segundo plano, esperar hasta 2 min)..." 'Gray'
    $proc = Start-Process -FilePath 'cleanmgr.exe' -ArgumentList '/sagerun:1' -PassThru -WindowStyle Hidden
    $proc.WaitForExit(120000) | Out-Null   # esperar max 2 min
    if (-not $proc.HasExited) {
        Write-Resultado "cleanmgr tardo mas de 2 min; continuando sin esperar" 'Yellow'
        try { $proc.Kill() } catch { }
    } else {
        Write-Resultado "cleanmgr completado (exit $($proc.ExitCode))"
    }
} catch {
    Write-Resultado "Error ejecutando cleanmgr: $_" 'Yellow'
}

# --------------------------------------------------------------------------
# BLOQUE FINAL: DEFRAG + ZERO-FILL de TODAS las unidades de disco fijo
# (imprescindible para que VMware compacte; proporcional al espacio libre)
# --------------------------------------------------------------------------
Write-Host ""
Write-Host "=== ZERO-FILL de todas las unidades de disco fijo (no USB, no red) ===" -ForegroundColor Magenta

if ($discosFijos.Count -eq 0) {
    Write-Resultado "No se detectaron unidades de disco fijo que procesar." 'Yellow'
} else {
    Write-Resultado "Unidades a procesar: $($discosFijos -join ', ')"
    foreach ($drive in $discosFijos) {
        Write-Host ""
        Write-Host "############### Unidad $drive ###############" -ForegroundColor Cyan
        Invoke-ZeroFillDrive -Drive $drive
    }
}

# --------------------------------------------------------------------------
# Resumen final
# --------------------------------------------------------------------------
Write-Host ""
Write-Host "================================================" -ForegroundColor Yellow
Write-Host "  RESUMEN (por unidad de disco fijo)" -ForegroundColor Yellow
Write-Host "================================================" -ForegroundColor Yellow
foreach ($d in $discosFijos) {
    $ini = if ($espacioInicialPorDisco.ContainsKey($d)) { $espacioInicialPorDisco[$d] } else { 0 }
    $fin = Get-FreeSpaceGB -Drive $d
    $dif = [math]::Round($fin - $ini, 2)
    $linea = "  {0}  inicial: {1} GB   final: {2} GB   diferencia: {3} GB" -f $d, $ini, $fin, $dif
    if ($dif -ge 0) {
        Write-Host $linea -ForegroundColor Green
    } else {
        Write-Host "$linea (normal si el zero-fill lleno el disco)" -ForegroundColor Yellow
    }
}
Write-Host ""
Write-Host "  Siguiente paso: APAGAR la VM (shutdown completo, NO suspender)" -ForegroundColor Cyan
Write-Host "  Luego desde el host Linux: bash CompactaW11.sh <ruta/a/VM.vmx>" -ForegroundColor Cyan
Write-Host "================================================" -ForegroundColor Yellow
Write-Host ""

try { Stop-Transcript | Out-Null } catch { }
