# CLAUDE.md — W11/Compacta

Herramientas para liberar espacio en disco y compactar máquinas virtuales Windows 11
alojadas en VMware Workstation desde un host Linux Ubuntu Desktop.

---

## Propósito

Las máquinas virtuales VMware con disco dinámico (VMDK thin-provisioned) crecen con
el uso pero **no se reducen automáticamente** cuando se borran ficheros dentro de la
VM. Para recuperar espacio real en el host hay que:

1. **Dentro de la VM (Windows 11)**: borrar todo lo que sobra para que el espacio
   libre del disco virtual sea máximo.
2. **Desde el host (Linux)**: defragmentar el VMDK y luego compactarlo para que
   VMware libere los bloques vacíos al sistema de ficheros del host.

Estos dos pasos los cubren los dos scripts de esta carpeta.

---

## Scripts

### 1. `LimpiaW11.ps1`
**Entorno**: PowerShell como Administrador dentro de la propia VM Windows 11.
**Objetivo**: maximizar el espacio libre del disco virtual antes de la compactación.

> **Invocación automática**: además de ejecutarse a mano, este script lo lanza
> ahora la cadena de la ISO como **paso de "compactado"** (último paso de
> `W11/ISO/1-Setup.ps1`, tras Windows Update). Esa es la contraparta **dentro de
> Windows** del compactado; el recorte real del VMDK sigue siendo `CompactaW11.sh`
> en el **host Linux** con la VM apagada. Requisito vigente: `sdelete64.exe`.

Tareas previstas (13 bloques, por orden de ejecución):

| # | Bloque | Acción |
|---|--------|--------|
| 1 | Limpieza de temp | `%TEMP%`/`%TMP%`, `C:\Windows\Temp` y `AppData\Local\Temp` de todos los perfiles |
| 2 | Windows Update + Delivery Optimization | Para `wuauserv` **y `bits`**, vacía `SoftwareDistribution\Download` y `Delete-DeliveryOptimizationCache`, reinicia ambos servicios |
| 3 | WinSxS / Component Store | `DISM /Online /Cleanup-Image /StartComponentCleanup /ResetBase` **+ `/SPSuperseded`** |
| 4 | CompactOS | `compact /compactos:always` (comprime los binarios del SO con XPRESS4K; ahorro permanente ~1–2 GB) |
| 5 | Papelera | Vaciar todas las papeleras de todos los perfiles |
| 6 | Prefetch | `C:\Windows\Prefetch\*` |
| 7 | Minidumps | `C:\Windows\Minidump\*`, `LiveKernelReports` y `memory.dmp` |
| 8 | Thumbnails / Icon cache | Bases de datos de miniaturas e iconos de todos los perfiles (detiene/reinicia Explorer) |
| 9 | Hibernación | `powercfg /h off` (elimina `hiberfil.sys`) |
| 10 | Pagefile | Informa del tamaño actual; sugiere desactivarlo manualmente (no lo elimina por seguridad) |
| 11 | Event logs | Limpiar todos los registros de eventos con `RecordCount > 0` |
| 12 | Puntos de restauración | Eliminar todos salvo el más reciente (o todos si se indica) |
| 13 | Cleanmgr | Ejecutar `cleanmgr /sagerun:1` en modo silencioso para limpieza adicional |
| — | Defrag + zero-fill **de todas las unidades de disco fijo** | Para **cada** unidad de disco fijo local (no USB, no red): `defrag X: /X /H /U /V` (consolida el hueco) seguido de `sdelete64.exe -accepteula -z X:` (rellena de ceros). **No hay fallback**: el zero-fill se hace exclusivamente con `sdelete64.exe`. La detección de unidades usa `Win32_LogicalDisk DriveType=3` y descarta los discos cuyo `BusType` es `USB` |

**Detección de unidades**: solo se procesan unidades de **disco fijo local**
(`DriveType=3`), excluyendo USB (incl. discos fijos conectados por bus USB),
unidades de red y CD/DVD. La limpieza de los bloques 1–13 sigue siendo específica
del sistema (`C:`); el defrag+zero-fill se aplica a **todas** las unidades fijas.

**Log**: cada ejecución abre un `Start-Transcript` en
`LimpiaW11.YYYYMMDD-HHMMSS.log` (marca de tiempo de inicio en el nombre, junto al
script) que registra toda la salida. El resumen final muestra espacio
inicial/final por unidad.

**Requisito externo OBLIGATORIO**: `sdelete64.exe` de Sysinternals (descargado
manualmente o con `winget install Microsoft.Sysinternals.SDelete`). El script lo
comprueba **al inicio**, antes de cualquier limpieza: si no lo encuentra, avisa de
cómo instalarlo y **aborta** (`exit 1`) sin tocar el sistema. No hay método de
respaldo: el zero-fill se hace exclusivamente con `sdelete64.exe`.

**Salida**: resumen por pantalla del espacio liberado en cada bloque y espacio libre
total antes/después.

---

### 2. `CompactaW11.sh`
**Entorno**: Bash en Ubuntu Desktop (host Linux) con VMware Workstation instalado.
**Objetivo**: defragmentar y compactar los VMDK de la VM Windows 11 para liberar
espacio real en el sistema de ficheros del host.

Tareas previstas (por orden de ejecución):

| Bloque | Acción |
|--------|--------|
| Localizar VM | El script recibe como argumento la ruta al `.vmx` (o la busca con `find` bajo un directorio indicado). En modo directorio también localiza las `.iso` |
| Analizar ISOs | Las imágenes `.iso` (ISO 9660/UDF) son de solo lectura: el script informa de su tamaño, indica que **no son comprimibles** y continúa sin tocarlas |
| Verificar estado | `vmrun list` para confirmar que la VM está **apagada**; abortar si está corriendo o suspendida |
| Localizar VMDKs | Extraer las rutas de los `.vmdk` declarados en el `.vmx` (solo discos, no snapshots intermedios) |
| Espacio previo | Mostrar tamaño real de cada VMDK en el host antes de la operación |
| Defragmentar | `vmware-vdiskmanager -d <disco.vmdk>` (reordena bloques dentro del VMDK) |
| Compactar | `vmware-vdiskmanager -k <disco.vmdk>` (libera bloques de ceros al host) |
| Espacio posterior | Mostrar tamaño real de cada VMDK tras la operación y ahorro conseguido |

**Dependencias**:
- `vmware-vdiskmanager` — incluido con VMware Workstation en `/usr/bin/` o `/usr/lib/vmware/bin/`
- `vmrun` — incluido con VMware Workstation

**Uso previsto**:
```bash
# Compactar una VM concreta
bash CompactaW11.sh /ruta/a/MiVM.vmx

# Analizar una ISO (informa de que no es comprimible)
bash CompactaW11.sh /ruta/a/imagen.iso

# Buscar y compactar todas las VMs (y analizar ISOs) bajo un directorio
bash CompactaW11.sh /ruta/a/carpeta-de-vms/
```

**Log**: cada ejecución redirige stdout/stderr (vía `tee`) a
`CompactaW11.YYYYMMDD-HHMMSS.log` (marca de tiempo de inicio en el nombre, junto al
script), conservando la salida en pantalla.

---

## Flujo completo de uso

```
1. Arrancar la VM Windows 11
2. Dentro de la VM: ejecutar LimpiaW11.ps1 como Administrador
   └── Al terminar: apagar la VM (shutdown completo, no suspender)
3. Desde el host Linux: ejecutar CompactaW11.sh apuntando al .vmx
   └── Resultado: VMDK más pequeño → más espacio libre en el host
```

---

## Decisiones de diseño

- **Zero-fill obligatorio (solo sdelete)**: sin rellenar con ceros el espacio libre
  (paso `sdelete -z`), `vmware-vdiskmanager -k` no puede distinguir bloques vacíos de
  bloques usados y no libera nada. Por eso `LimpiaW11.ps1` termina siempre con ese
  paso. El zero-fill se hace **exclusivamente con `sdelete64.exe`** (no hay fallback
  nativo): si la herramienta no está instalada, el script aborta al inicio antes de
  limpiar nada e indica cómo descargarla. Se eliminó el respaldo por bucle de
  PowerShell porque era mucho más lento y no tocaba los clusters ya liberados de la MFT.
- **Defrag dentro de la VM antes del zero-fill**: `LimpiaW11.ps1` ejecuta
  `defrag C: /X` (consolidación del espacio libre) justo antes del zero-fill para
  agrupar el hueco al final del volumen y maximizar lo que luego recorta
  `vmware-vdiskmanager -k`.
- **CompactOS**: `compact /compactos:always` comprime los binarios del SO con XPRESS4K
  (ahorro permanente ~1–2 GB, impacto de rendimiento despreciable en una VM). Se hace
  antes del defrag/zero-fill para que el hueco liberado entre en la compactación.
- **Defrag antes de compactar (en el host)**: `vmware-vdiskmanager -d` consolida los
  datos hacia el principio del disco antes de que `-k` recorte la cola vacía; omitirlo
  reduce el ahorro obtenido.
- **Comprobación de estado de la VM**: operar sobre un VMDK mientras la VM corre
  puede corromper el disco; la comprobación con `vmrun list` es obligatoria y el
  script aborta si la VM aparece en la lista.
- **Sin snapshots durante la compactación**: si la VM tiene snapshots activos,
  `vmware-vdiskmanager` rechaza la operación. El script avisará de esta situación
  y dará instrucciones.
- **Una única dependencia externa, obligatoria**: la limpieza (bloques 1–13) usa solo
  cmdlets y herramientas nativas de Windows (PowerShell 5+, DISM, compact, defrag,
  cleanmgr, vssadmin). El zero-fill final requiere `sdelete64.exe` (Sysinternals), que
  **sí es imprescindible**: el script lo comprueba al arrancar y aborta si no está,
  porque sin el zero-fill la compactación posterior no recupera espacio.

---

## Ficheros de la carpeta

| Fichero | Descripción |
|---------|-------------|
| `CLAUDE.MD` | Este fichero: descripción del proyecto para Claude Code |
| `LimpiaW11.ps1` | Script PowerShell de limpieza (ejecutar dentro de la VM) |
| `CompactaW11.sh` | Script Bash de defrag+compactación (ejecutar en el host Linux) |

---

## Issues conocidos / limitaciones previstas

- `DISM /ResetBase` es irreversible y puede tardar varios minutos; se incluirá con
  advertencia explícita al usuario.
- `sdelete -z` puede tardar mucho tiempo proporcional al tamaño del disco libre;
  el script mostrará progreso.
- Algunos ficheros de `%TEMP%` pueden estar en uso y no borrarse; el script
  continuará sin abortar.
- La compactación no funciona con discos VMDK de tipo "pre-allocated" (thick); el
  script detectará el tipo y avisará.
