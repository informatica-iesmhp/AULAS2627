# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this directory.

## Propósito del proyecto

Automatización del despliegue de Linux Mint Cinnamon (22.1 y 22.3) en equipos del IES Miguel Herrero (Torrelavega). Incluye tres partes bien diferenciadas:

1. **Generación de ISO personalizada** (`ISO/`): scripts que crean una ISO bootable que instala y configura el sistema sin intervención manual.
2. **Control de aulas** (`ControlIABD/`, `ControlSMRD/`): scripts para encender/apagar equipos vía Wake-on-LAN.
3. **Orquestación Ansible** (`ansible/`): playbooks y roles para configurar el software de los equipos ya instalados.

---

## Cadena de ejecución de la ISO

```
0a-CreaISO.sh          ← En el equipo de desarrollo (Linux), genera la ISO
  └── [ISO bootea]
       └── setup.desktop (autostart Cinnamon del usuario "mint")
            └── 0b-Github.sh   ← embebido en la raíz del squashfs
                 └── 1-SetupLiveCD.sh        ← clona repo, particiona discos, copia squashfs, prepara chroot
                      └── 2-SetupSOdesdeLiveCD.sh  ← corre DENTRO del chroot, configura el SO instalado
                           └── [reboot → primer arranque]
                                └── 3-SetupPrimerInicio.service  ← systemd oneshot, instala Ansible y hace full-upgrade
```

---

## Versiones de Mint

| Versión | Carpeta         | Estado              |
|---------|-----------------|---------------------|
| 22.1    | `ISO/22.1/`     | Completa y funcional |
| 22.3    | `ISO/22.3/`     | Solo `utiles/` por ahora; `0a-CreaISO.sh` pendiente |

Los scripts en `utiles/` (raíz de `Mint/`) son la versión más actualizada de `Auto-Ansible.sh` y `NombreIP.sh`, que las versiones dentro de `ISO/*/utiles/` pueden no tener.

---

## Comandos clave

### Generar la ISO (en equipo Linux con Mint/Ubuntu)
```bash
sudo apt install xorriso isolinux syslinux-utils mtools squashfs-tools -y

cd ~/xIAC-IESMHP/Mint/ISO/22.1
sudo ./0a-creandoISO.sh ~/Descargas/linuxmint-22.1-cinnamon-64bit.iso
# La ISO de salida se llama: Mint-CEIABD-SMRV-v22.1.iso
```

### Ver logs en el equipo instalado
```bash
ls /var/log/IAC-IESMHP/Mint/
# 1-SetupLiveCD.sh.log        ← particionado y copia del FS
# 2-SetupSOdesdeLiveCD.sh.log ← configuración en chroot
# 3-SetupPrimerInicio.sh.log  ← primer arranque y Ansible
```

### Ejecutar Ansible manualmente
```bash
cd /opt/IAC-IESMHP/Mint/ansible/
ansible-playbook -i ./equiposIABD.ini roles.yaml --ssh-extra-args="-o StrictHostKeyChecking=no"
# Para un equipo concreto:
ansible-playbook -i ./equiposIABD.ini roles.yaml -l IABD-17
# En local:
ansible-playbook -i localhost, --connection=local roles.yaml
```

### Encender/apagar aulas
```bash
# Desde el equipo del profesor (requiere wakeonlan instalado):
bash ControlIABD/EnciendeAula.sh    # Wake-on-LAN a todos los IABD
bash ControlIABD/ApagaAula.sh
bash ControlSMRD/EnciendeSMRD.sh
bash ControlSMRD/ApagaAulaSMRD.sh
```

---

## Arquitectura y decisiones clave

### 0a-CreaISO.sh (v22.1) — Generación de la ISO
- **squashfs único**: Mint 22.x usa `filesystem.squashfs` (a diferencia de Ubuntu 26.04 que usa multicapa).
- **Autostart Cinnamon**: se escribe `setup.desktop` en `/home/mint/.config/autostart/`. El `.desktop` ejecuta `sudo /bin/bash /0b-Github.sh` en un terminal (`x-terminal-emulator -e`).
- **BIOS + UEFI**: usa `isolinux` para BIOS y `boot/grub/efi.img` para UEFI (a diferencia de Ubuntu 26.04 que solo soporta UEFI).
- **GRUB personalizado**: timeout 5 s, entrada única "Instalación ON FIRE!" con `nomodeset` quitado (lo tiene comentado como histórico; se puede reactivar si hay problemas gráficos).

### 0b-Github.sh — Bootstrap en el Live CD
- Se embebe en la raíz del squashfs como `/0b-Github.sh`.
- Clona el repo en `/LiveCDiesmhp` y luego llama a `1-SetupLiveCD.sh`.
- Los scripts del repo quedan en `/opt/IAC-IESMHP/` en el sistema instalado.

### 1-SetupLiveCD.sh — Particionado e instalación
- **Detección de discos**: ignora USB y loop; separa NVMe de SD.
  - 2×NVMe → pequeño=`/`, grande=`/home`
  - NVMe+SD → NVMe=`/`, SD=`/home` (sufijo de partición: `p1` para NVMe, `1` para SD)
- **Esquema GPT**: EFI 512 MiB | swap 8 GiB | root resto. Disco grande: /home entero.
- **squashfs único**: busca con `find /cdrom -name "filesystem.squashfs"` (no multicapa).
- Copia con `rsync` excluyendo `/etc/fstab` y `/etc/machine-id`.
- Si `2-SetupSOdesdeLiveCD.sh` termina con `Correcto` (última línea del log), reinicia; si no, espera 100000 s.

### 2-SetupSOdesdeLiveCD.sh — Configuración en chroot
- Configura locale y teclado en español (dconf + `/etc/default/locale` + `/etc/default/keyboard`).
- Genera `/etc/fstab` con UUIDs reales (`blkid`); detecta particiones por mountpoint (`lsblk -rno NAME,MOUNTPOINT`).
- Elimina paquetes live: `casper`, `ubiquity`, `live-boot`, `live-boot-initramfs-tools`.
- Lee `macs.csv` para asignar hostname; si la MAC no está registrada, el equipo se queda como `mint`.
- Crea usuarios: `root:root` y `usuario:usuario` (ambos con sudo).
- Instala GRUB UEFI: `grub-install --target=x86_64-efi --bootloader-id=MINT`.
- `nomodeset` está comentado (fue necesario en 22.1 hasta hacer `full-upgrade`); si vuelven los problemas gráficos, descomentar la línea `sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT.*/`.
- Crea el servicio `3-SetupPrimerInicio.service` con `WantedBy=multi-user.target`.
- Termina con `echo "Correcto"`.

### 3-SetupPrimerInicio.sh — Primer arranque
- Hace `apt-get full-upgrade` e instala `ssh` y `ansible`.
- Ejecuta `Auto-Ansible.sh` (configura claves SSH para Ansible) y luego `ansible-playbook roles.yaml`.
- Se autodeshabilita al terminar.

### Auto-Ansible.sh — Preparación SSH para Ansible
- Genera clave `ed25519` en `/root/.ssh/id_ed25519` si no existe.
- Añade la clave pública a `authorized_keys`.
- **Issue conocido** (línea 38): `ssh-keygen -F $HOSTNAME` falla si el hostname no está en `known_hosts`. Como workaround usa `ssh-keyscan -H localhost`.

---

## Roles Ansible (`ansible/roles/`)

| Rol              | Función                                                         |
|------------------|-----------------------------------------------------------------|
| `basicos`        | Python, pip, pipx, ansible                                      |
| `comparteaula`   | NFS servidor/cliente según IP del aula (72→IABD, 32→SMRD)      |
| `nvidia`         | Drivers NVIDIA                                                  |
| `certificados`   | Certificados del centro                                         |
| `obs`            | OBS Studio                                                      |
| `xrdp`           | Escritorio remoto (XRDP)                                        |
| `vscode`         | Visual Studio Code                                              |
| `virtualbox`     | VirtualBox (pendiente: no instala la versión exacta especificada) |
| `vmware`         | VMware (pendiente: pide compilar como sudo en el primer arranque) |
| `contenedores`   | Docker + Podman (pendiente, comentado en roles.yaml)            |

El rol `comparteaula` unifica `comparteaula32` y `comparteaula72`; detecta el aula por el tercer octeto de la IP.

---

## Inventarios Ansible

| Fichero                          | Aula / uso                          |
|----------------------------------|-------------------------------------|
| `equiposIABD.ini`                | IABD (IABD-00 a IABD-20)            |
| `equiposSMRD.ini`                | SMRD (SMRD-00 a SMRD-18)            |
| `EquiposSMRD-alumnos2526.ini`    | Alias de alumnos SMRD curso 25/26   |

---

## Configuraciones de hardware soportadas

| Aula      | Disco pequeño (/)       | Disco grande (/home)    |
|-----------|-------------------------|-------------------------|
| Distancia | NVMe 0.5 TB (EFI+swap+/) | NVMe 2.0 TB            |
| CEIABD    | NVMe 0.5 TB (EFI+swap+/) | SDA 1.0 TB             |

---

## Issues conocidos y pendientes

- **`Auto-Ansible.sh` línea 38**: `ssh-keygen -F $HOSTNAME` puede fallar. Pendiente corrección.
- **`virtualbox`**: no instala exactamente la versión especificada (instala la última disponible).
- **`vmware`**: pide compilar módulos como sudo en el primer arranque. Pendiente automatización.
- **ISO 22.3**: la carpeta `ISO/22.3/` solo tiene `utiles/`; falta adaptar `0a-CreaISO.sh` a esa versión.
- **`nomodeset`**: fue necesario en 22.1 tras actualizaciones del kernel. Resuelto con `full-upgrade`; la línea queda comentada en `2-SetupSOdesdeLiveCD.sh` por si vuelve a hacer falta.
