# CLAUDE.md — ISO desatendida de Windows 11 (IAC-IESMHP)

> ⛔ **git**: no ejecutes operaciones de git que modifiquen el repo/remoto
> (`add`/`commit`/`push`/`reset`/cambios de rama). El propietario sube SIEMPRE él
> mismo los cambios a GitHub. Solo crea/edita ficheros y déjalos sin commitear.
> Ver la regla completa en el [`CLAUDE.md` raíz](../../CLAUDE.md).


Generación de una **ISO de Windows 11 personalizada** que instala el SO sin
intervención y, en el primer inicio de sesión, prepara el equipo de principio a
fin: lo engancha al repo de configuración, instala software, prepara los discos,
actualiza Windows y deja la máquina lista. Es el equivalente Windows de
`Ubuntu/ISO/26.04/`.

> A diferencia de la versión anterior, la **instalación de software** (Office,
> Chrome, VS Code…) **sí** la hace ya esta cadena, en local, mediante
> `2-Aplicaciones.ps1` (winget + chocolatey) replicando `W11/ansible/roles.yaml`.
> Ansible por SSH sigue disponible como vía alternativa/mantenimiento desde el
> equipo de control (ver [`../ansible/CLAUDE.md`](../ansible/CLAUDE.md)).

---

## Cadena de ejecución

```
0-CreaIsoW11.sh        ← en Linux (Ubuntu): inserta autounattend.xml + embebe
  │                       0b-GitHub.ps1 (vía $OEM$\$1) y reconstruye la ISO
  └── [ISO bootea → Windows Setup lee autounattend.xml de la raíz]
       │   · Bypass requisitos W11 (TPM/SecureBoot/RAM/CPU/disco)
       │   · Particiona disco 0 (EFI+MSR+C:) e instala la edición elegida
       │   · Crea la cuenta administradora  usuario / usuario@1  + autologon
       └── [primer inicio de sesión → FirstLogonCommands]
            ├─ 1) Escritorio Remoto SEGURO (RDP + NLA + firewall)
            ├─ 2) winget install Git.Git (acepta licencia y fuente)
            └─ 3) "C:\Program Files\IAC-IESMHP\W11\ISO\0b-GitHub.ps1"  (embebido)
                 └── clona el repo (sparse: raíz + W11) SOBRE esa misma carpeta
                     └── lanza 1-Setup.ps1 EN UNA VENTANA VISIBLE, que orquesta:
                          ├─ 1-Setup   : nombre/IP (macs.csv) + OpenSSH + ENERGÍA
                          ├─ 2-Aplicaciones : winget + chocolatey
                          ├─ 3-Particionado : discos de datos + perfiles en D:\
                          ├─ Windows Update completo  ⟲ (reinicios + reanudación)
                          ├─ Compactado = LimpiaW11.ps1 (limpieza + zero-fill)
                          └─ Finalizar : pantalla de login + tiempo total
```

`1-Setup.ps1` es una **máquina de estados** que **sobrevive a los reinicios de
Windows Update**: re-arma el autologon, registra la tarea programada
`IAC-IESMHP-Reanudar` (que relanza `1-Setup.ps1 -Reanudar` en una ventana visible
en cada arranque) y guarda la fase en `HKLM\SOFTWARE\IAC-IESMHP`. Al **finalizar**
desactiva el autologon → el equipo arranca en la **pantalla de inicio de sesión**.

---

## Ficheros de esta carpeta

| Fichero | Dónde corre | Qué hace |
|---------|-------------|----------|
| `0-CreaIsoW11.sh` | Linux (build) | Monta la ISO original, añade `autounattend.xml` a la raíz, embebe `0b-GitHub.ps1` en `$OEM$\$1\Program Files\IAC-IESMHP\W11\ISO`, trocea `install.wim` si >4 GiB y reconstruye con `xorriso`. |
| `autounattend.xml` | Windows Setup | Answer file: bypass requisitos, particionado disco 0, edición sin clave, cuenta `usuario`/`usuario@1` + autologon y `FirstLogonCommands` (RDP seguro, git, lanzar `0b-GitHub.ps1`). |
| `comun.ps1` | Windows | **Fuente única de verdad** (equivalente de `comun.sh`): rutas del proyecto, **logging al lado de cada script** (req 0), **control de tiempos** (`Tiempos.log`, T0 = instalación de Windows), y utilidades de orquestación (fase, autologon, tarea de reanudación). Lo cargan (`dot-source`) 1/2/3 y, tras clonar, 0b. |
| `0b-GitHub.ps1` | Windows (1er login) | Localiza git, clona el repo **in-place** (la carpeta ya contiene este script) con **sparse-checkout cono** (raíz + `W11`) en `C:\Program Files\IAC-IESMHP` y lanza `1-Setup.ps1` en ventana visible. Embebido por el build en su ubicación definitiva `…\W11\ISO\`. Log a su lado. |
| `1-Setup.ps1` | Windows (orquestador) | Config local + orquesta toda la cadena (ver abajo). Log a su lado. |
| `2-Aplicaciones.ps1` | Windows (3er paso) | Instala el software de `roles.yaml` con **winget** (preferente) + **chocolatey** (lo que no está bien en winget). Dos listas editables, dos bucles, tiempo por app, continúa si una falla. Log a su lado. |
| `3-Particionado.ps1` | Windows (4º paso) | CD/DVD→`R:`, USB→`S,T…`; clasifica discos **sin formatear** (NVMe→SSD→SATA, mayor→menor), los formatea NTFS y les da letras `D,E,F…`; fija perfiles por defecto en `D:\Users`. Log a su lado. |
| `tutorial-iso-windows11-autounattend.md` | — | Tutorial largo (teoría + métodos Windows `oscdimg` y Linux `xorriso`). |

---

## Logs y tiempos

- **Logs (req 0)**: cada script escribe su log **a su lado**, con el mismo nombre
  + `.log` (p. ej. `…\W11\ISO\1-Setup.ps1.log`, `…\2-Aplicaciones.ps1.log`). Los
  `Tiempos.log` también viven en `…\W11\ISO\`.
  - `LimpiaW11.ps1` / `CompactaW11.sh` conservan su propia convención (log con
    marca de tiempo en el nombre, `Limpia/CompactaW11.YYYYMMDD-HHMMSS.log`, junto
    al script), ya documentada en `W11/Utiles/Compacta/CLAUDE.md`.
- **`Tiempos.log` (req 1)**: además de los logs individuales, **un fichero único**
  `…\W11\ISO\Tiempos.log` acumula una línea por fase con `inicio | fin | duración`
  y, al final, una línea **TOTAL** medida desde **T0 = instalación de Windows**.
  - **T0** se obtiene de `Win32_OperatingSystem.InstallDate` (espejo del registro
    `HKLM\…\CurrentVersion\InstallDate`, epoch Unix). Es la marca fiable e
    independiente del idioma de "cuándo se instaló Windows".
  - El detalle **por aplicación** (winget/choco) vive en `2-Aplicaciones.ps1.log`;
    `Tiempos.log` guarda solo el total de la fase `aplicaciones`.

---

## `1-Setup.ps1` — orquestador (detalle)

Lo lanza `0b-GitHub.ps1` en una **ventana PowerShell visible** (req 2: poder ver
el proceso). Conduce la cadena con una **máquina de estados** (fase en
`HKLM\SOFTWARE\IAC-IESMHP`):

1. **Config básica** (primera pasada):
   - **MAC → nombre + IP estática** (equivalente a `NombreIP.sh` de Ubuntu):
     parsea `macs.csv` de la raíz (`MAC, Equipo, IPf, Comentario`, separado por
     comas), `Rename-Computer` **sin** reiniciar (el cambio lo aplica el reinicio
     de Windows Update) y conversión a IP estática conservando máscara/gw/DNS y
     cambiando solo el último octeto por `IPf`.
   - **OpenSSH** (cliente+servidor, sshd auto, firewall `Any`,
     `DefaultShell=powershell`) + claves de `Autorizados.txt`.
   - **Energía "Alto rendimiento"**: imita el rol Ansible
     [`energiaAltoRendimiento`](../ansible/roles/energiaAltoRendimiento/CLAUDE.md):
     `powercfg /setactive 8c5e7fda-…` (GUID fijo, idempotente) +
     `standby-timeout-ac/dc 0` (sin suspensión).
2. **`2-Aplicaciones.ps1`** y **3) `3-Particionado.ps1`** (procesos aparte; salida
   en la misma ventana; cada uno con su propio `.log`).
4. **Windows Update completo** con el módulo **PSWindowsUpdate** (se autoinstala:
   NuGet + PSGallery). Como suele exigir **varios reinicios**:
   - re-arma el **autologon** de `usuario` (`comun.ps1: Enable-Autologon`),
   - registra la tarea **`IAC-IESMHP-Reanudar`** (al iniciar sesión relanza
     `1-Setup.ps1 -Reanudar` en ventana visible),
   - en cada arranque instala lo pendiente y, si hay reinicio pendiente,
     `Restart-Computer`; al reanudar continúa donde estaba (fase `winupdate`).
5. **Compactado = `LimpiaW11.ps1`** (limpieza + zero-fill **dentro de Windows**).
   ⚠️ `CompactaW11.sh` **NO** se ejecuta aquí: es un script **Bash del HOST Linux**
   (`vmware-vdiskmanager` con la VM apagada). `LimpiaW11.ps1` deja el disco listo
   para que, tras apagar la VM, el host la compacte con `CompactaW11.sh`.
6. **Finalizar**: desactiva el autologon → **pantalla de inicio de sesión** en los
   arranques posteriores ("bloqueo por defecto de usuario"), borra la tarea de
   reanudación, escribe el **tiempo total** y limpia la fase.

**Reanudación tras reinicios** = autologon re-armado + tarea `AtLogOn` con
`RunLevel Highest`. La combinación garantiza que, tras cada reinicio de WU,
`usuario` entra solo y el pipeline continúa **en una ventana visible** sin
intervención. El triple borrado final (tarea + autologon + fase) deja el equipo
en estado "normal" (login con contraseña).

---

## `2-Aplicaciones.ps1` — software (winget + chocolatey)

- **Dos listas editables** (`$Winget` y `$Choco`), cada entrada con
  **Nombre / Id / Version / Args**. Por defecto `Version=''` (última); rellenar
  para fijar versión (winget `--version`, choco `--version`). Versiones de
  referencia del aula: `W11/ansible/CLAUDE.md`.
- **Preferencia winget**; chocolatey solo para lo que no está bien en winget
  (`veyon`, `basex`; `vmware-workstation` **comentado**, igual que `roles.yaml`).
- **Dos bucles** recorren las listas, **miden el tiempo** de cada instalación (en
  `2-Aplicaciones.ps1.log`), y **continúan si una falla** (se anota el error y el
  resumen final lista las que fallaron). Chocolatey se autoinstala si falta.
- Mapa winget aplicado: Chrome `Google.Chrome`, OBS `OBSProject.OBSStudio`,
  OpenShot `OpenShot.OpenShot`, GIMP `GIMP.GIMP`, ZoomIt
  `Microsoft.Sysinternals.ZoomIt`, VS Code `Microsoft.VisualStudioCode`, Vagrant
  `Hashicorp.Vagrant`, Notepad++ `Notepad++.Notepad++`, AWS CLI `Amazon.AWSCLI`,
  VS Community `Microsoft.VisualStudio.2022.Community`, VirtualBox
  `Oracle.VirtualBox`, Office/M365 `Microsoft.Office`.

---

## `3-Particionado.ps1` — discos de datos + perfiles

1. **CD/DVD → `R:`**; **USB extraíbles → `S, T, U…`** (`Win32_Volume` por
   `DriveType` 5 y 2). Se hacen **antes** de formatear datos para liberar `D,E…`.
2. **Discos sin formatear** (RAW o sin particiones), **excluyendo** el de
   **sistema/arranque** y los **USB**. Se clasifican: **NVMe → SSD → SATA/HDD**
   (vía `Get-PhysicalDisk` `BusType`/`MediaType`) y, dentro de cada tipo, de
   **mayor a menor tamaño**.
3. Se **inicializan (GPT)**, se crea una partición de tamaño máximo, se **formatea
   NTFS** y se asignan letras **consecutivas desde `D:`** (saltando las usadas).
4. Si existe `D:` (disco fijo), fija la **carpeta de perfiles por defecto** en
   `D:\Users` (`ProfileList\ProfilesDirectory`). **Solo afecta a usuarios NUEVOS**;
   el perfil de `usuario` permanece en `C:\Users`.

> **Seguridad**: solo toca discos **crudos / sin particiones** que **no** sean de
> sistema ni USB. En una VM de un solo disco **no hace nada** (no hay objetivos),
> por lo que es inocuo durante la construcción de la imagen golden.

---

## Construir la ISO

```bash
sudo apt install xorriso wimtools
cd W11/ISO
chmod +x 0-CreaIsoW11.sh

# autounattend.xml y 0b-GitHub.ps1 se toman de esta misma carpeta por defecto
./0-CreaIsoW11.sh -i ~/Descargas/Win11_original.iso \
                  -a autounattend.xml \
                  -o ~/Descargas/Win11_custom.iso
#   -s OTRO.ps1   usa otro script de bootstrap (por defecto ./0b-GitHub.ps1)
#   --split       fuerza trocear install.wim aunque no llegue a 4 GiB
```

Verifica que la ISO lleva arranque BIOS+UEFI, `autounattend.xml` en la raíz y
`0b-GitHub.ps1` en `/sources/$OEM$/$1/Program Files/IAC-IESMHP/W11/ISO/` (el script
lo comprueba al final). **Prueba SIEMPRE en una VM (UEFI + TPM) antes de hardware
real.**

> **IMPORTANTE (igual que `comun.sh` en Ubuntu)**: `comun.ps1` es un fichero del
> repo del que dependen 1/2/3 y (tras clonar) 0b. Hay que hacer **commit + push a
> `main`** de `comun.ps1`, `1/2/3-*.ps1` y `0b-GitHub.ps1` **antes** de arrancar
> una ISO, porque 0b los clona desde GitHub.

---

## Decisiones y convenciones

- **`0b-GitHub.ps1` vive desde el principio en `C:\Program Files\IAC-IESMHP\W11\ISO`**
  (req 1). El build lo coloca ahí vía `$OEM$\$1\Program Files\…` (`$1` = raíz del
  disco de sistema en la jerarquía `$OEM$`). Cuando 0b clona el repo, este se
  materializa **sobre esa misma carpeta**: como `git clone` exige un directorio
  vacío, se clona **in-place** (`git init` + `remote` + `sparse-checkout` +
  `fetch` + `checkout -f`). El propio `0b-GitHub.ps1` se borra justo antes del
  `checkout` (un `.ps1` en ejecución no está bloqueado en Windows) para evitar el
  error "untracked working tree files would be overwritten"; los `.log` y
  `Tiempos.log` no colisionan (el repo no los rastrea) y se conservan.
  Además, como esa carpeta la crea Windows Setup (`$OEM$`) como
  SYSTEM/TrustedInstaller y git ≥2.35.2 rechaza operar en repos de otro
  propietario ("detected dubious ownership"), 0b ejecuta antes
  `git config --global --add safe.directory …` (la ruta y `*`).
- **Gotchas de Windows PowerShell 5.1 (confirmados en VM, no repetir)**:
  - **No redirigir el stderr de ejecutables nativos** (`git`, etc.) con
    `2>$null` / `2>&1` cuando `$ErrorActionPreference='Stop'`: PS 5.1 envuelve
    cada línea de stderr en un `ErrorRecord` y la convierte en error TERMINANTE
    (p. ej. `git remote remove origin` cuando no existe escribía
    "No such remote: 'origin'" y abortaba). 0b corre el bloque git con
    `ErrorActionPreference='Continue'` y comprueba fallos reales con
    `$LASTEXITCODE`.
  - **`Start-Process -ArgumentList` con ARRAY no entrecomilla** los elementos con
    espacios: una ruta como `"C:\Program Files\…\1-Setup.ps1"` se parte y
    `powershell -File` no encuentra el script (salía `-196608` sin ejecutar ni
    crear log). Pásale un **único string** con la ruta entre comillas (así lo
    hacen 0b y la tarea `Register-Resume` de `comun.ps1`).
- **Logs al lado de cada script** (req 0) y **`Tiempos.log`** central (req 1),
  ambos en `…\W11\ISO\`. Ver sección "Logs y tiempos".
- **Ventana visible** (req 2): 0b lanza `1-Setup.ps1` con
  `Start-Process -WindowStyle Normal`; la tarea de reanudación lo relanza también
  en ventana visible. Así se ve el progreso en cada arranque.
- **Windows Update + reinicios**: PSWindowsUpdate + autologon re-armado + tarea
  `IAC-IESMHP-Reanudar` + fase en registro. El compactado va **siempre el último**
  (limpia temporales y hace zero-fill; instalar o particionar después lo
  arruinaría).
- **Pantalla de login al final** (req 2): al terminar se desactiva el autologon
  (`AutoAdminLogon=0`, se borra `DefaultPassword`) → arranque con login normal.
- **Cuenta por defecto `usuario` / `usuario@1`** (password EN CLARO en el XML y,
  temporalmente, en el autologon del registro durante la fase de WU; se borra al
  finalizar). Trátalo como secreto.
- **Escritorio Remoto seguro** = RDP con **NLA**, mismos ajustes que el rol Ansible
  [`escritorioRemoto`](../ansible/roles/escritorioRemoto/CLAUDE.md).
- **Sparse-checkout en modo cono** (`init --cone` + `set W11`): raíz + `W11`,
  excluye `Mint/`, `ThinStation/`, `Ubuntu/`…
- **`xorriso -as mkisofs`, no método nativo**; **`install.wim` > 4 GiB** se trocea
  en `.swm`. Detalle en `tutorial-iso-…md`.

---

## TODO / pendientes

1. **Proxy de aula y Windows Update / winget / choco**: los aulas IABD (`.72`) y
   SMRD (`.32`) tienen proxy (`10.0.72.140:3128` / `10.0.32.119:3128`). La cadena
   asume salida directa (VM con NAT). Si en hardware real hace falta proxy para
   `Install-Module PSWindowsUpdate`, winget o choco, habrá que detectarlo por IP
   (3er octeto) y configurarlo (WinHTTP / `choco config`), como hace el rol
   `chocolatey` en Ansible.
2. **Edición de Windows**: `autounattend.xml` fija `Windows 11 Pro`; ajustar al
   nombre exacto del `install.wim` (`wiminfo sources/install.wim`).
3. **Activación**: clave en blanco ⇒ sin activar (KMS/OEM si aplica).
4. **`Microsoft.Office`** instala Microsoft 365 Apps sin activar licencia (igual
   que el rol `office365`).
5. **Perfiles en `D:\Users`**: usar con cuidado; solo afecta a perfiles nuevos.
   Revisar interacción con roaming/AD si el equipo se une a dominio (`preparaAD`).
