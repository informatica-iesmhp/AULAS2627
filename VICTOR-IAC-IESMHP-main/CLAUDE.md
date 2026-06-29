# CLAUDE.md

Guía general para Claude Code (claude.ai/code) sobre **todo** el repositorio
`IAC-IESMHP`. Este fichero describe el **espíritu común** a las cuatro líneas de
despliegue del proyecto y sirve de **índice**; el detalle de cada una vive en su
propio `CLAUDE.md` (mapa al final).

## ⛔ Gestión de git — NO la hagas tú (regla del propietario)

**NUNCA** ejecutes operaciones de git que modifiquen el repositorio o el remoto:
nada de `git add`, `git commit`, `git push`, `git reset`, `git checkout` para
cambiar de rama, crear ramas, etc. **El propietario (Víctor) sube SIEMPRE él mismo
los cambios de código a GitHub.**

- Limita tu trabajo a **crear/editar ficheros** en el árbol de trabajo. Deja los
  cambios **sin commitear**; ya los revisará y subirá él.
- Puedes usar git en **solo lectura** si lo necesitas para diagnosticar
  (`git status`, `git log`, `git diff`), pero **sin** modificar nada.
- Si crees que hace falta un commit/push, **dilo y para**; no lo hagas.

> Nota histórica: en una sesión previa (24/06/2026) sí se hicieron commits/push
> de los arreglos de `W11/ISO/0b-GitHub.ps1`. A partir de ahí el propietario pidió
> expresamente que **no** se gestione git. Respétalo.

---

## Propósito del proyecto

**Infraestructura como código (IAC) para el IES Miguel Herrero (Torrelavega)**:
automatizar el despliegue y la configuración de los equipos de las aulas **sin
intervención manual**. Para cada sistema operativo se genera una **imagen de
instalación personalizada** que, al arrancar, deja la máquina lista de principio a
fin: particiona, instala el SO, le pone nombre e IP, instala el software del aula y
aplica la configuración.

El repositorio **ya no es solo Ubuntu**: aloja **cuatro líneas de despliegue** que
comparten la misma filosofía y estructura, cada una con su propio `CLAUDE.md`:

| Línea | Carpeta | Sistema | Rol en el proyecto |
|-------|---------|---------|--------------------|
| **Mint** | [`Mint/`](Mint/CLAUDE.md) | Linux Mint Cinnamon 22.x | **Primera generación** (versión previa). De aquí evolucionó el resto; sigue como referencia/legacy. |
| **Ubuntu** | [`Ubuntu/`](Ubuntu/CLAUDE.md) | Ubuntu 26.04 Desktop | **Línea Linux actual**, la más desarrollada (ZFS, GDM 26.04, RegistroDeCambios vivo). |
| **ThinStation** | [`ThinStation/`](ThinStation/CLAUDE.md) | ThinStation-NG 7.2 | **Cliente ligero** RDP en modo kiosco. No instala SO: arranca de ISO/USB/PXE en RAM. En uso real en aulas ESO/Bachillerato. |
| **W11** | [`W11/ISO/`](W11/ISO/CLAUDE.md) | Windows 11 | **ISO desatendida** de Windows: instala + software en local (winget/choco) + Ansible como mantenimiento. |

**Metodología de trabajo** (común a todas): el usuario **arranca la imagen en una
máquina virtual (VMware)**, recoge los logs y los pega aquí para diagnosticar fallos
y optimizar el proceso. Solo cuando funciona en VM se prueba en hardware real.

---

## El patrón común (espíritu del proyecto)

Aunque cada SO tiene sus particularidades, **todas las líneas comparten el mismo
esqueleto**. Entenderlo es la clave para moverse por cualquiera de ellas:

### 1. Imagen autodesplegable construida en Linux
Un script **`0…CreaISO`** corre en un equipo de desarrollo Linux y produce la imagen
personalizada (ISO con `xorriso`). En Linux/W11 inserta un **answer file** y/o
**autostart** para que la imagen arranque y se configure sola; ThinStation, al ser
cliente ligero, **compila** la imagen entera (Fedora + `./build`) y no instala nada
en disco.

### 2. Bootstrap desde GitHub + cadena de scripts numerados
La imagen arranca y, en el primer arranque/sesión, un script **`0b-GitHub`** clona
el repo desde GitHub y lanza una **cadena de scripts numerada** que va de menor a
mayor: *crear → clonar → particionar/instalar → configurar el SO → primer arranque
→ comprobaciones*. Los números son consistentes entre Mint, Ubuntu y W11 (varía el
lenguaje: Bash en Linux, PowerShell en Windows). El repo se clona en
`/opt/IAC-IESMHP` (Linux) o `C:\Program Files\IAC-IESMHP` (Windows).

### 3. Única fuente de verdad para las variables
Cada línea centraliza sus rutas y constantes "mágicas" en **un solo fichero** que
los demás scripts cargan (`source` / `dot-source`): **`comun.sh`** (Linux) /
**`comun.ps1`** (Windows). Define `GITHUB_USER`/`REPO`, rutas del proyecto, ficheros
de datos y redes/proxy de aula. **Para cambiar una ruta, se edita solo ese fichero**
(excepción inevitable: `0b-GitHub`, que corre antes de clonar y duplica
`GITHUB_USER`+`REPO`).
> Como `comun.*` y los scripts se clonan desde GitHub, hay que **commit+push a
> `main` ANTES de generar/arrancar una imagen** o el equipo clonará una versión vieja.

### 4. Identidad del equipo: `macs.csv` + IP estática
Un único **`macs.csv`** en la raíz del repo mapea cada equipo. Formato:
`MAC, Equipo, IPf, Comentario` (líneas que empiezan por `#` son comentarios). Por la
**MAC** se asigna el **nombre** (`prefijo-NN`, reservando `-00` para el equipo de
profesor) y, si la interfaz está en DHCP, se convierte a **IP estática** conservando
máscara/gateway/DNS y cambiando solo el último octeto por `IPf`. Lo aplica el paso
de "primer arranque" (`NombreIP.sh` en Linux, bloque equivalente en `1-Setup.ps1`).

### 5. Detección de aula por IP (3er octeto)
La red del centro codifica el aula en el **tercer octeto**: `10.0.72.x` → **IABD**,
`10.0.32.x` → **SMRD/SMRV**. Se usa para fijar el **proxy de aula**
(IABD `10.0.72.140:3128`, SMRD `10.0.32.119:3128`) en apt/winget/choco y para
decidir servidor vs. cliente NFS. El equipo `-00` suele ser el servidor del aula.

### 6. Configuración post-instalación con Ansible
Tras instalar el SO, la cadena lanza **Ansible** (`roles.yaml`) para instalar el
software y configurar el equipo. Convenciones compartidas por Ubuntu y W11:
- **Un rol por programa**, con su versión del aula en `defaults/` y **su propio
  `CLAUDE.md`** por rol.
- **`roles.yaml` maestro** con detección de aula en `pre_tasks` y **tolerancia a
  fallos**: si un rol falla, se anota y se sigue con el resto (no aborta).
- Cada rol lleva **su nombre como tag** para instalar un solo programa
  (`--tags chrome`).
- En Linux Ansible corre **en local** en el primer arranque; en W11 el mismo
  software se instala **en local sin Ansible** (winget+choco desde la ISO) y Ansible
  por SSH queda como vía de mantenimiento.

### 7. Robustez, logs y registro de cambios
- **Supervivencia a reinicios**: la fase larga (Windows Update, upgrades) usa una
  **máquina de estados** que sobrevive a los reinicios (W11: autologon + tarea de
  reanudación + fase en registro; Linux: servicio systemd oneshot que se
  autodeshabilita y centinela `Correcto` que decide si reiniciar o esperar).
- **Logs**: cada script deja su `.log` (al lado del script en W11, en
  `/var/log/IAC-IESMHP/<Distro>/` en Linux). Útiles como primer análisis al pegar.
- **RegistroDeCambios**: los cambios de cada sesión se documentan en
  `<Distro>/RegistroDeCambios/YYYYMMDD-Cambios.md` (con hora). **Consúltalo antes de
  tocar un script** para no repetir correcciones que ya se probaron.

---

## Protocolo de diagnóstico (al pegar un log)

1. Identifica la **línea** (Mint/Ubuntu/ThinStation/W11) y lee su `CLAUDE.md`.
2. Lee el **RegistroDeCambios** más reciente de esa línea (qué se tocó por última vez).
3. Lee el log o el script de comprobaciones (`4-Comprobaciones.sh` en Linux).
4. **Cruza cada error con los falsos positivos conocidos** documentados en el
   `CLAUDE.md` de la línea — muchos `[ERR]` son del propio script de diagnóstico.
5. Si el error es real, localiza la **línea exacta** del script que lo genera y
   propón el **cambio mínimo**.
6. Documenta el fix en `<Distro>/RegistroDeCambios/YYYYMMDD-Cambios.md` (con la hora).

---

## Aulas y hardware

| Aula | Red (3er octeto) | Notas |
|------|------------------|-------|
| **IABD** | `10.0.72.x` | Aula CEIABD. Proxy `10.0.72.140:3128`. |
| **SMRD / SMRV** | `10.0.32.x` | Proxy `10.0.32.119:3128`. |
| **Distancia** | — | Perfil de disco sin ZFS (ext4 íntegro). |

Particionado por perfil (línea Ubuntu; detalle en [`Ubuntu/CLAUDE.md`](Ubuntu/CLAUDE.md)):

| Perfil | Disco pequeño | Disco grande |
|--------|---------------|--------------|
| Distancia | NVMe 0.5 TB (EFI+swap+`/` ext4) | NVMe 2.0 TB (`/home` ext4) |
| CEIABD | NVMe 0.5 TB (EFI+swap+`/` ext4 + `rpool` ZFS) | SDA 1.0 TB (ZFS `tank` → `/datos`) |

---

## Ficheros de datos compartidos (raíz del repo)

- **`macs.csv`** — mapeo `MAC, Equipo, IPf, Comentario` de **todos** los equipos.
  Lo consumen las cuatro líneas para nombre + IP estática.
- **`Autorizados.txt`** — claves SSH públicas autorizadas (root/usuario/Administrador).
- **`README.md`** — instrucciones mínimas de clonado.

> Los fondos de escritorio, logos Plymouth e imágenes del IES viven dentro de cada
> línea (p. ej. `Ubuntu/ISO/26.04/imagenesIES/`, `ThinStation/imagenes/`), **no** en
> la raíz.

---

## Mapa de los `CLAUDE.md` del repositorio

Cuando trabajes en una parte concreta, **lee primero su `CLAUDE.md`** (es la fuente
de verdad; este fichero raíz solo da el contexto general):

- **Por línea de despliegue**
  - [`Mint/CLAUDE.md`](Mint/CLAUDE.md) — ISO Mint 22.x, control de aulas (Wake-on-LAN), Ansible Mint.
  - [`Ubuntu/CLAUDE.md`](Ubuntu/CLAUDE.md) — ISO Ubuntu 26.04, particionado/ZFS, GDM, falsos positivos, ZFS-operación.
  - [`ThinStation/CLAUDE.md`](ThinStation/CLAUDE.md) — compilación en Fedora, imagen universal BIOS+UEFI, RDP kiosco.
  - [`W11/ISO/CLAUDE.md`](W11/ISO/CLAUDE.md) — ISO desatendida de Windows 11, `autounattend.xml`, máquina de estados, `comun.ps1`.
- **Ansible (post-instalación)**
  - [`Ubuntu/ansible/CLAUDE.md`](Ubuntu/ansible/CLAUDE.md) y un `CLAUDE.md` por rol en `Ubuntu/ansible/roles/<rol>/`.
  - [`W11/ansible/CLAUDE.md`](W11/ansible/CLAUDE.md) (Ansible por SSH→PowerShell) y un `CLAUDE.md` por rol en `W11/ansible/roles/<rol>/`.
  - `Ubuntu/ansible/rolesUsuario/CLAUDE.md` — configuración por usuario (no root), en construcción.
- **Utilidades**
  - [`W11/Utiles/Compacta/CLAUDE.md`](W11/Utiles/Compacta/CLAUDE.md) — limpieza dentro de la VM (`LimpiaW11.ps1`) + compactado del VMDK en el host (`CompactaW11.sh`).

> **Estado vigente de cada rol Ansible** (activo / comentado / legacy): la tabla del
> `CLAUDE.md` de cada `ansible/`; la fuente de verdad última es su `roles.yaml`.
