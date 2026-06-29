# Rol `nvidia`

## Contexto
Pensado para **Ubuntu Desktop 26.04**, que trae **soporte nativo de drivers
NVIDIA**: el metapaquete `ubuntu-drivers-common` selecciona e instala el driver
**recomendado** por Ubuntu para la GPU detectada (ya no hay que fijar a fuego
una serie antigua como `nvidia-driver-535`).

## Qué hace
Instala el driver propietario de NVIDIA **solo si se detecta una GPU NVIDIA** en el equipo:

1. `lspci` → detecta si hay cadena `NVIDIA` (`has_nvidia`).
2. Si **no** hay GPU NVIDIA: muestra mensaje y salta todo el bloque (el playbook continúa, *no* aborta).
3. Si **hay** GPU NVIDIA:
   - Instala `ubuntu-drivers-common` (gestor nativo de drivers de Ubuntu).
   - Comprueba si el driver ya está operativo (`nvidia-smi`). Si lo está, **no
     reinstala** (idempotente).
   - Si no lo está, instala el driver:
     - `required_nvidia_driver == ""` → `ubuntu-drivers install` (driver
       **recomendado** por Ubuntu 26.04, comportamiento por defecto).
     - `required_nvidia_driver == "NNN"` → fuerza `nvidia-driver-NNN` (pin
       manual a una serie concreta).
   - **Reinicia** el equipo solo si se acaba de instalar el driver.
   - Comprueba la versión instalada con `nvidia-smi`.
   - Informa del driver **recomendado** por `ubuntu-drivers devices` y lo
     compara con el instalado (solo informa, no actualiza).
   - **Instala el NVIDIA Container Toolkit** (al final del bloque, solo si
     hay GPU): si `nvidia-container-toolkit` no está ya instalado, añade el
     repo APT oficial (clave GPG en `/usr/share/keyrings/`), lo instala y
     genera la especificación CDI en `/etc/cdi/nvidia.yaml`
     (`nvidia-ctk cdi generate`). Permite que Docker/Podman accedan a la
     GPU. Idempotente: si el toolkit ya está, no reinstala.

## Estructura
- `tasks/main.yml`
- `defaults/main.yml`:
  - `required_nvidia_driver: ""` — vacío = driver recomendado por Ubuntu
    (nativo 26.04). Asignar una serie (`"570"`, `"575"`, …) solo si hay que
    pinear manualmente.

> La variable `required_kernel` se eliminó: la comprobación de kernel estaba
> comentada y Ubuntu 26.04 gestiona la compatibilidad kernel/driver de forma
> nativa vía DKMS.

## Notas
- El reinicio (`reboot`) se dispara dentro del playbook **solo** cuando el
  driver no estaba operativo y se acaba de instalar:
  `connect_timeout=5`, `reboot_timeout=600`, `post_reboot_delay=30`.
- Si el driver ya está cargado, el rol es idempotente (no instala, no reinicia).
- Solo **avisa** si el driver recomendado difiere del instalado; no actualiza
  automáticamente.
- En equipos sin NVIDIA (la mayoría de las VMs de prueba) el rol es prácticamente un no-op.
- **Bloque envuelto en `environment:` no interactivo** (`DEBIAN_FRONTEND=noninteractive`,
  `NEEDRESTART_MODE=a`). Imprescindible: `command: ubuntu-drivers install` es un
  comando crudo (no el módulo `apt`, que ya forzaría noninteractive) y Ansible
  corre sin TTY → sin esto, el `postinst` del driver en **hardware físico** abre
  un debconf interactivo que cuelga el primer arranque y deja dpkg a medio
  configurar. Primera tarea del bloque: `dpkg --configure --pending` defensivo.

## Issues conocidos
- **Secure Boot**: con `DEBIAN_FRONTEND=noninteractive`, `shim-signed` **no**
  enrola la clave MOK (omite el prompt). Si la máquina física tiene **Secure
  Boot activo**, el módulo NVIDIA quedará instalado pero **sin firmar → no
  carga** (`nvidia-smi` falla, GNOME cae a `nouveau`/llvmpipe). Para estos
  equipos: **deshabilitar Secure Boot en el firmware** (práctica habitual con
  el driver propietario) o implementar enrolado MOK automático (fuera del
  alcance del fix mínimo).
- **Cuelgue en máquina FÍSICA pese a `noninteractive` (2026-05-18, 2ª iter.)**:
  el frontend no interactivo **no** evita dos causas reales de cuelgue en el
  primer arranque, ya mitigadas en el rol:
  1. **Lock de dpkg/apt**: tras el `apt-get full-upgrade` de
     `3-SetupPrimerInicio.sh`, los timers `apt-daily`/`apt-daily-upgrade`,
     `unattended-upgrades` y `packagekit` agarran `lock-frontend`.
     `ubuntu-drivers install` (apt por debajo) colisiona → dpkg a medio
     configurar. **Mitigación**: 1ª tarea del bloque para esos
     timers/servicios (`systemd state=stopped`, best-effort) + tarea
     `flock -w 600 /var/lib/dpkg/lock-frontend` antes de instalar.
  2. **Sin timeout duro**: `command:` crudo esperaría para siempre.
     **Mitigación**: el install pasa a `shell: timeout -k 60 1800
     ubuntu-drivers install </dev/null` con environment no interactivo
     reforzado (`DEBIAN_FRONTEND`, `DEBCONF_NONINTERACTIVE_SEEN`,
     `NEEDRESTART_MODE=a`, `APT_LISTCHANGES_FRONTEND=none`),
     `changed_when: rc==0`, `failed_when:false` (rol best-effort; rc=124 =
     timeout, se avisa por `debug`). Tras instalar, `dpkg --configure -a`
     defensivo → ya no hace falta el `sudo dpkg --configure -a` manual.
  - **Caveat Secure Boot inalterado**: si la máquina física tiene Secure Boot
    **activo**, con `noninteractive` el módulo queda **sin firmar → no carga**
    (`nvidia-smi` falla; no es un cuelgue). Solución: deshabilitar Secure Boot
    en el firmware o enrolado MOK automático (fuera de alcance).
