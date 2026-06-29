# Crear una ISO de Windows 11 personalizada que ejecuta un script de GitHub (sin activar la licencia)

## 0. Cómo funciona (visión general)

El mecanismo oficial de Microsoft para instalaciones desatendidas es un **fichero de respuesta** llamado `autounattend.xml`. Si lo colocas en la **raíz** del medio de instalación (ISO/USB), Windows Setup lo lee automáticamente y responde solo a todas las pantallas.

Arquitectura de tu caso:

1. **Windows Setup + `autounattend.xml`** -> instala el sistema operativo de forma desatendida (idioma, particionado, edición, cuenta local, *sin clave*).
2. **`FirstLogonCommands`** -> en el primer inicio de sesión, una línea de PowerShell **descarga tu script desde GitHub y lo ejecuta**. Ese script hace toda la post-instalación (apps, configuración, etc.).

> El SO lo instala Setup; el script de GitHub hace la personalización posterior. Un script no puede instalar el SO desde cero.

El `autounattend.xml` es **idéntico** se construya la ISO donde se construya. Lo único que cambia según tu sistema es **cómo reempaquetas la ISO**: en Windows con `oscdimg` (Paso 6) o en Linux con `xorriso` (Sección 11).

---

## 1. Requisitos

Según dónde vayas a **construir** la ISO:

**Si construyes en Windows:**

- **Windows ADK** (Assessment and Deployment Kit). Solo necesitas el componente **Deployment Tools**, que incluye `oscdimg.exe` para reempaquetar la ISO como booteable.
  Descarga oficial: https://learn.microsoft.com/en-us/windows-hardware/get-started/adk-install
- **7-Zip** (o montar la ISO) para extraer el contenido de la ISO original.

**Si construyes en Linux (Ubuntu):**

- `xorriso` y `wimtools`: `sudo apt install xorriso wimtools`
- No extraes los ~8 GB: se **monta** la ISO en solo-lectura y se reconstruye (necesita `sudo` para montar).
- Script todo-en-uno: `0-CreaIsoW11.sh` (adjunto).

**En ambos casos:**

- Una **máquina virtual** (Hyper-V, VirtualBox, VMware, virt-manager...) para probar antes de usar hardware real. **Imprescindible.**
- La **ISO oficial de Windows 11** descargada de Microsoft (tu punto de partida).
- Un **repositorio de GitHub** con tu script (p. ej. `install.ps1`). Usa la URL **raw**:
  `https://raw.githubusercontent.com/USUARIO/REPO/main/install.ps1`

---

## 2. Paso 1 — Extraer el contenido de la ISO

> Este paso (extraer a una carpeta) solo es necesario para el método de Windows (`oscdimg`). En Linux el método recomendado **monta** la ISO original en solo-lectura y la reconstruye sin extraerla (ver Sección 11), así que **puedes saltártelo**.

Crea una carpeta de trabajo, p. ej. `C:\win11build\iso` (Windows) o `~/win11build/iso` (Linux), y vuelca ahí todo el contenido de la ISO original:

- En Windows con 7-Zip: clic derecho sobre la ISO -> *7-Zip -> Extraer en "iso\\"*.
- En Windows: montar la ISO (doble clic) y copiar todos los archivos.
- En Linux: `7z x Win11.iso -oiso/`  o  `mkdir m && sudo mount -o loop Win11.iso m && cp -a m/. iso/ && sudo umount m`

Al terminar debes ver carpetas como `boot`, `efi`, `sources`, etc.

> No edites nada dentro de `sources/install.wim` salvo que quieras inyectar drivers/quitar apps (offline servicing). Para lo que pides no hace falta.

---

## 3. Paso 2 — Generar el `autounattend.xml`

Tienes dos opciones. **Recomiendo la A** por fiabilidad.

### Opción A (recomendada): generador de Schneegans

Web: https://schneegans.de/windows/unattend-generator/ (soporta Windows 10/11, incluidas 24H2 y 25H2).

Opciones clave a marcar en el formulario:

- **Region/Language**: español de España, teclado español.
- **Computer name / Partitioning**: deja el particionado automático para disco GPT/UEFI.
- **Bypass Windows 11 requirements check**: actívalo si vas a instalar en hardware sin TPM 2.0 / Secure Boot (típico en equipos antiguos del centro).
- **User accounts**: crea una **cuenta local** de administrador (evita el inicio de sesión con cuenta Microsoft del OOBE).
- **Autologon**: actívalo para esa cuenta. *Es necesario para que se ejecute el script de GitHub* (ver Paso 3).
- **Product key / Edition**: elige **"Do not enter a product key"** y selecciona la **edición** que quieres instalar (p. ej. *Windows 11 Pro* o *Education*). Esto deja Windows **sin activar** (ver Paso 4 para los matices).
- **Scripts**: en la sección de scripts puedes pegar directamente la línea que descarga y ejecuta el script (ver Paso 3), o hacerlo a mano sobre el XML descargado.

Descarga el `autounattend.xml` resultante.

### Opción B: usar la plantilla de ejemplo

Usa el fichero `autounattend.xml` de esta carpeta. Está completo y comentado, pero **debes** revisar/editar: contraseña, nombre de edición, idioma y disco destino. Y **probarlo en VM**.

> **Flujo real de este proyecto (IAC-IESMHP).** El `autounattend.xml` ya
> incorporado en esta carpeta NO descarga el script de GitHub en el primer
> arranque: crea la cuenta `usuario`/`usuario@1`, habilita el Escritorio Remoto
> seguro (RDP + NLA), instala **git** con winget y ejecuta
> `C:\Windows\Setup\Scripts\0b-GitHub.ps1`, que va **embebido en la ISO** (vía
> `$OEM$`, lo coloca `0-CreaIsoW11.sh`). Ese script clona el repo con
> sparse-checkout (solo raíz + `W11`) y lanza `1-Setup.ps1`. Las secciones de
> abajo sobre `Invoke-WebRequest`/`install.ps1` son el método **genérico**
> (descargar de GitHub) que se conserva como referencia. Ver
> [`CLAUDE.md`](CLAUDE.md) para el detalle del flujo de este proyecto.

---

## 4. Paso 3 — Bloque que descarga y ejecuta el script de GitHub

Dentro del paso (`pass`) **`oobeSystem`**, componente `Microsoft-Windows-Shell-Setup`, va el bloque `FirstLogonCommands`:

```xml
<FirstLogonCommands>
  <SynchronousCommand wcm:action="add">
    <Order>1</Order>
    <CommandLine>powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12; Invoke-WebRequest -Uri 'https://raw.githubusercontent.com/USUARIO/REPO/main/install.ps1' -OutFile 'C:\Windows\Temp\install.ps1'; powershell.exe -NoProfile -ExecutionPolicy Bypass -File 'C:\Windows\Temp\install.ps1'"</CommandLine>
    <Description>Descargar y ejecutar script de instalacion desde GitHub</Description>
    <RequiresUserInput>false</RequiresUserInput>
  </SynchronousCommand>
</FirstLogonCommands>
```

Sustituye `USUARIO/REPO/main/install.ps1` por tu ruta raw real.

Notas importantes:

- **`FirstLogonCommands` requiere autologon** (o un primer inicio de sesión manual) para dispararse. Por eso en el Paso 2 se activa autologon.
- **Hace falta red en ese primer inicio.** Si el equipo va por **cable, DHCP funciona solo** y la descarga irá bien. Si solo hay Wi-Fi y has saltado la pantalla de red, no habrá internet y la descarga fallará -> en ese caso, mejor **incrustar el script en la ISO** (alternativa `$OEM$`, ver Paso 5).
- Alternativa más directa de PowerShell: `iex (irm 'https://raw.githubusercontent.com/.../install.ps1')` (descarga y ejecuta en memoria).

---

## 5. Paso 4 — Instalar SIN activar la licencia

En el paso **`windowsPE`**, componente `Microsoft-Windows-Setup`:

- Deja la **clave de producto en blanco** y selecciona la **edición** por su nombre, para que Setup sepa qué edición instalar del `install.wim`:

```xml
<UserData>
  <ProductKey>
    <Key />
    <WillShowUI>OnError</WillShowUI>
  </ProductKey>
  <AcceptEula>true</AcceptEula>
</UserData>
...
<ImageInstall>
  <OSImage>
    <InstallTo><DiskID>0</DiskID><PartitionID>3</PartitionID></InstallTo>
    <InstallFrom>
      <MetaData wcm:action="add">
        <Key>/IMAGE/NAME</Key>
        <Value>Windows 11 Pro</Value>
      </MetaData>
    </InstallFrom>
  </OSImage>
</ImageInstall>
```

Cambia `Windows 11 Pro` por la edición exacta presente en tu ISO. Para ver los nombres disponibles:

- En Windows: `dism /Get-WimInfo /WimFile:C:\win11build\iso\sources\install.wim`
- En Linux:   `wiminfo sources/install.wim`   (paquete `wimtools`)

(usa el campo *Name* exacto que devuelva).

### Matices honestos sobre la activación

- Con clave en blanco + edición seleccionada, Windows queda **sin activar** ("No se encontró ninguna clave de producto en el dispositivo").
- **Pero** si el equipo tiene una **clave OEM en el firmware (UEFI)** o una **licencia digital** asociada al hardware, Windows puede **autoactivarse** al conectarse a internet, sin que tú pongas nada. Esto es comportamiento de Windows, no del XML.
- No uses una **clave genérica/KMS client** si quieres garantizar que no se active: en una red con servidor KMS (posible en un centro educativo) esa clave **sí activaría**. La clave en blanco evita ese caso.
- Si necesitas garantizar 0 activación incluso con firmware OEM, mantén el equipo **sin red** hasta haber decidido la licencia, o aplica luego la licencia que corresponda a tu canal (p. ej. licencia por volumen del centro).

---

## 6. Paso 5 — Colocar el `autounattend.xml` (y opcional `$OEM$`)

El `autounattend.xml` debe quedar en la **raíz** de la ISO, con ese nombre exacto (Setup lo busca por nombre en medios extraíbles y en la raíz).

- **Método Windows** (trabajas sobre la carpeta extraída): copia el fichero a la raíz de esa carpeta, p. ej. `C:\win11build\iso\autounattend.xml`.
- **Linux** (método recomendado de la Sección 11): no copias nada a la ISO a mano; el fichero se mete en una carpeta `add/` aparte y `xorriso` lo coloca en la raíz al reconstruir. El script `0-CreaIsoW11.sh` lo hace solo.

### (Opcional) Incrustar el script en lugar de descargarlo de GitHub

Si prefieres no depender de la red en el primer arranque, usa la estructura `$OEM$` para copiar el script al disco durante la instalación. Coloca el script en:

```
sources/$OEM$/$$/Setup/Scripts/install.ps1
```

Lo que pongas en `$OEM$/$$/` acaba en `C:\Windows\`, así que el script quedará en `C:\Windows\Setup\Scripts\install.ps1` y puedes ejecutarlo desde `FirstLogonCommands` apuntando a esa ruta local (sin `Invoke-WebRequest`). Es lo más robusto cuando no hay garantía de red.

> En Linux puedes inyectar también el `$OEM$` colocándolo dentro de la carpeta
> `add/` que pasas a `xorriso` (p. ej. `/tmp/add/sources/$OEM$/...`); al
> reconstruir queda en `/sources/$OEM$` de la ISO.

---

## 7. Paso 6 — Reempaquetar la ISO booteable (Windows, con `oscdimg`)

> ¿Trabajas en Linux? Sáltate este paso y ve a la **Sección 11** (`xorriso`).

Abre el acceso directo **"Deployment and Imaging Tools Environment"** (lo instala el ADK) **como administrador**. Esto deja `oscdimg.exe` en el PATH.

Comando para una ISO **arrancable tanto en UEFI como en BIOS heredado**:

```cmd
oscdimg.exe -m -o -u2 -udfver102 -bootdata:2#p0,e,bC:\win11build\iso\boot\etfsboot.com#pEF,e,bC:\win11build\iso\efi\microsoft\boot\efisys.bin C:\win11build\iso C:\win11build\Win11_custom.iso
```

Significado de los parámetros (referencia oficial más abajo):

- `-m` ignora el límite de tamaño de imagen.
- `-o` deduplica ficheros idénticos (reduce tamaño).
- `-u2` sistema de ficheros UDF; `-udfver102` versión 1.02.
- `-bootdata:2#...#...` define **dos** sectores de arranque: BIOS (`etfsboot.com`) y UEFI (`efisys.bin`).

> **Arranque sin "Press any key to boot from CD".** Para un arranque totalmente automático en VM, sustituye `efisys.bin` por `efisys_noprompt.bin` (misma carpeta `efi\microsoft\boot\`). Así no espera a que pulses una tecla.

Resultado: `C:\win11build\Win11_custom.iso`.

---

## 8. Paso 7 — Probar en máquina virtual

1. Crea una VM nueva (tipo Windows 11, UEFI/Secure Boot según tu caso, TPM virtual si lo tienes).
2. Arranca desde `Win11_custom.iso`.
3. Verifica que: no pide nada, particiona, instala la edición correcta, crea la cuenta local, hace autologon y **ejecuta el script de GitHub** en el primer inicio.
4. Comprueba el estado de activación: *Configuración -> Sistema -> Activación* debe indicar que **no está activado**.

> Si usas **Rufus** o **Ventoy** para hacer el USB, **desactiva** sus propias opciones de "instalación desatendida": crean su propio `autounattend.xml` y pisarían el tuyo.

---

## 9. Avisos y buenas prácticas

- **Idempotencia del script.** `FirstLogonCommands` se ejecuta una vez por usuario nuevo. Diseña tu `install.ps1` para que pueda relanzarse sin romper nada (comprueba si ya hizo cada paso).
- **TLS.** Windows 11 ya usa TLS 1.2+, pero dejar la línea `SecurityProtocol=Tls12` no estorba.
- **Particionado destruye datos.** `WillWipeDisk=true` sobre `DiskID 0` borra el disco. Asegúrate del número de disco correcto en el equipo destino.
- **Contraseña en claro.** En el XML la contraseña va en texto plano; trátalo como secreto. El generador de Schneegans permite ofuscarla.
- **Versiona el `autounattend.xml`** junto al script (y el `0-CreaIsoW11.sh`) en tu repo de GitHub para tener trazabilidad.

---

## 10. Referencias oficiales (Microsoft Learn)

- Instalar el Windows ADK: https://learn.microsoft.com/en-us/windows-hardware/get-started/adk-install
- Ficheros de respuesta (answer files) y cómo crearlos: https://learn.microsoft.com/en-us/windows-hardware/manufacture/desktop/update-windows-settings-and-scripts-create-your-own-answer-file-sxs
- Dónde busca Setup el `autounattend.xml` (orden de búsqueda implícito): https://learn.microsoft.com/en-us/windows-hardware/manufacture/desktop/windows-setup-automation-overview
- Referencia de `Microsoft-Windows-Shell-Setup | FirstLogonCommands`: https://learn.microsoft.com/en-us/windows-hardware/customize/desktop/unattend/microsoft-windows-shell-setup-firstlogoncommands
- Opciones de línea de comandos de `oscdimg`: https://learn.microsoft.com/en-us/windows-hardware/manufacture/desktop/oscdimg-command-line-options
- Estructura `$OEM$`: https://learn.microsoft.com/en-us/windows-hardware/manufacture/desktop/windows-setup-supported-platforms-and-cross-platform-deployments

---

## 11. Construir la ISO en Linux con `xorriso` (alternativa a `oscdimg`)

Si trabajas en Ubuntu no necesitas Windows ADK. Los pasos 2–6 (generar el `autounattend.xml`, el bloque de GitHub, la no-activación, el `$OEM$`) son los mismos; aquí solo cambia **cómo metes el fichero en la ISO y cómo la regeneras**.

Dependencias: `sudo apt install xorriso wimtools`

### Método recomendado — montar la ISO y reconstruirla con `xorriso -as mkisofs`

Es el método que usa el script y el único fiable con las ISOs de Windows 11 **24H2/25H2**. No extraes los ~8 GB: montas la ISO original en **solo-lectura** y `xorriso` la reconstruye leyendo del montaje, añadiendo el `autounattend.xml` y conservando el arranque BIOS+UEFI.

```bash
ISO=~/Descargas/Win11_original.iso
OUT=~/Descargas/Win11_custom.iso
AUTO=./autounattend.xml

rm -f "$OUT"
sudo mount -o loop,ro -t udf "$ISO" /tmp/m 2>/dev/null || sudo mount -o loop,ro "$ISO" /tmp/m
mkdir -p /tmp/add && cp "$AUTO" /tmp/add/autounattend.xml

# Si install.wim > 4 GiB hay que trocearlo (limite de fichero de ISO 9660):
#   mkdir -p /tmp/add/sources
#   wimlib-imagex split /tmp/m/sources/install.wim /tmp/add/sources/install.swm 3800
#   ...y añade  -m install.wim  al comando de abajo para excluir el original.

xorriso -as mkisofs \
  -iso-level 4 -rock -disable-deep-relocation -untranslated-filenames \
  -V "CCCOMA_X64FRE_ES-ES_DV9" -volset "CCCOMA_X64FRE_ES-ES_DV9" \
  -publisher "MICROSOFT CORPORATION" \
  -A "CDIMAGE 2.56 (01/01/2005 TM)" \
  -b boot/etfsboot.com -no-emul-boot -boot-load-size 8 \
  -eltorito-alt-boot -eltorito-platform efi \
  -b efi/microsoft/boot/efisys_noprompt.bin \
  -o "$OUT" /tmp/m /tmp/add
sudo umount /tmp/m
```

Notas:

- **No uses `-udf`**: la emulación `mkisofs` de `xorriso` no lo soporta (`Unsupported option '-udf'`). El límite de 4 GB de `install.wim` se resuelve troceándolo en `.swm`, no con UDF.
- **Volume ID**: arriba va a fuego `CCCOMA_X64FRE_ES-ES_DV9`. El real de tu ISO lo sacas con `xorriso -indev "$ISO" -toc 2>/dev/null | grep -i "Volume id"`. El script lo detecta solo.
- **`efisys_noprompt.bin`** evita el "Press any key to boot from CD/DVD" (ideal para desatendido). Si tu ISO no lo trae, usa `efisys.bin`.

#### Por qué NO el método nativo (`replay` / `keep`)

El modo nativo `xorriso -indev ORIG -outdev SALIDA -boot_image any replay -map ...` (más cómodo, sin montar) **no funciona** con las ISOs de Win11 24H2/25H2:

- `replay` falla con `SORRY : Cannot enable EL Torito boot image #N ... not a data file in the ISO filesystem`, porque esas ISOs ocultan las imágenes El Torito (bug de xorriso ≤ 1.5.6, corregido en 1.5.7).
- `keep` no da error y conserva el arranque, **pero** escribiendo a un fichero distinto solo vuelca una sesión incremental: te queda una ISO de **pocos KB sin los datos** (8 GB perdidos).

Por eso se reconstruye con `-as mkisofs` desde el montaje.

### `install.wim` mayor de 4 GB (la pega habitual en Linux)

ISO 9660 tiene un **límite de 4 GB por fichero**; por eso la ISO de Microsoft usa UDF. Como `xorriso` no escribe UDF, si tu `install.wim` supera 4 GB hay que **trocearlo en `.swm`** (<4 GB); Windows Setup los recompone solo:

```bash
stat -c%s /tmp/m/sources/install.wim               # tamaño en bytes
wimlib-imagex split /tmp/m/sources/install.wim \
                    /tmp/add/sources/install.swm 3800   # trocear (<3800 MB/parte)
```

Luego añade `-m install.wim` al comando `xorriso` para excluir el original (los `.swm` van en `/tmp/add/sources/`). El script `0-CreaIsoW11.sh` hace todo esto solo.

### Script todo-en-uno

`0-CreaIsoW11.sh` automatiza el método recomendado: monta la ISO, detecta el Volume ID, añade el `autounattend.xml`, trocea `install.wim` **solo si supera 4 GiB** (o si fuerzas `--split`) y reconstruye la ISO. Necesita `sudo` para montar.

```bash
sudo apt install xorriso wimtools
chmod +x 0-CreaIsoW11.sh

./0-CreaIsoW11.sh -i Win11_original.iso -a autounattend.xml -o Win11_custom.iso
# forzar el troceo de install.wim aunque no llegue a 4 GiB:
./0-CreaIsoW11.sh -i Win11_original.iso -a autounattend.xml -o Win11_custom.iso --split
```

### Verificar la ISO resultante

```bash
xorriso -indev Win11_custom.iso -report_el_torito plain   # arranque BIOS+UEFI conservado
xorriso -indev Win11_custom.iso -find /autounattend.xml   # fichero en la raíz
```

### Grabar a USB / probar

La ISO ya es **híbrida**; grábala con `dd` o úsala directa en la VM:

```bash
sudo dd if=Win11_custom.iso of=/dev/sdX bs=4M status=progress conv=fsync
```

(Con Ventoy/Rufus, desactiva su instalación desatendida para que no añadan su propio `autounattend.xml`.)

### Referencias (Linux)

- `xorriso` (proyecto GNU), manual completo: https://www.gnu.org/software/xorriso/man_1_xorriso.html
- `wimlib` (manejo de imágenes WIM en Linux): https://wimlib.net/

---

## 12. Nota sobre la licencia (legal)

Instalar Windows sin activar es habitual en escenarios de *imaging*/despliegue y evaluación, pero el uso continuado de Windows requiere una licencia válida según los Términos de licencia del software de Microsoft. Aplica la licencia que corresponda a tu canal de adquisición (p. ej. licencia por volumen del centro educativo). Términos de licencia oficiales de Microsoft: https://www.microsoft.com/en-us/useterms (selecciona el producto y canal que corresponda).
