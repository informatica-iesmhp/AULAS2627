# Despliegue seguro de un aula tras clonar la maqueta

Guía y playbooks para dejar operativo el PC del profesor y para el primer
arranque de los equipos de un aula recién clonada con DRBL + Clonezilla,
antes de empezar a gestionarla con el resto de Ansible.

## Roles y usuarios (léelo antes de nada)

La maqueta trae dos usuarios locales, y cada uno tiene un papel distinto
que conviene no mezclar:

- **`depinfo`** — administración del sistema operativo. Lo gestiona
  únicamente el coordinador TIC del centro. Es quien ejecuta
  `instalar_ansible_profesor.sh` (necesita permisos de root) y quien
  configuraría cualquier cambio a bajo nivel. No se usa para el día a día
  del aula.
- **`ansible-admin`** — identidad de automatización. Ya existe en todos
  los equipos (incluido el del profesor, clonado igual que los demás).
  Aquí viven la clave SSH, la carpeta de trabajo `~/ansible-aulas/` y
  desde aquí se ejecutan los playbooks. Nadie inicia sesión gráfica con
  ella directamente.
- **Cuentas de dominio de los profesores** — el día a día, en turnos de
  mañana/tarde. No tienen instalación propia de Ansible ni clave propia:
  se les da permiso de `sudo` para "convertirse" en `ansible-admin`
  cuando necesiten gestionar el aula (`sudo -iu ansible-admin`). Se
  autoriza a los 2 profesores concretos de esa aula (el de mañana y el de
  tarde) por nombre de usuario, uno a uno - no se usa ningún grupo del AD.
  Así, aunque cambie el profesor de turno, la identidad de automatización
  sigue siendo la misma, y sudo sigue registrando qué profesor concreto
  ejecutó cada acción.

Este reparto evita dos problemas: que la gestión del aula dependa de la
cuenta personal de un profesor concreto (si cambia de centro o se le
bloquea la cuenta, se rompería todo), y que cada profesor tenga su propia
clave SSH suelta por ahí controlando 30 equipos.

## Resumen del proceso

0. El coordinador TIC prepara el PC del profesor como nodo de control de
   Ansible (`instalar_ansible_profesor.sh`, ejecutado como `depinfo`/root):
   instala Ansible, genera la clave de `ansible-admin`, crea la carpeta de
   trabajo y da permiso de sudo a los 2 profesores concretos de esa aula.
1. La maqueta (Linux Mint 22.3) ya tiene SSH activo y el usuario
   `ansible-admin` creado, con una contraseña **temporal** (la misma en
   todos los equipos, porque viene de la misma imagen clonada).
2. Con DRBL + Clonezilla se despliega esa maqueta en todos los equipos del
   aula, incluido el del profesor.
3. En cuanto los equipos arrancan por primera vez, un profesor autorizado
   (con su cuenta de dominio + sudo) ejecuta, **una sola vez por aula**, en
   este orden, tres playbooks:
   - `00_regenerate_identity.yml`
   - `01_bootstrap_keys.yml` (+ una verificación manual)
   - `02_harden_ssh.yml`
4. A partir de ahí, toda la gestión diaria del aula se hace con Ansible
   usando la clave SSH, sin contraseña.

## Por qué hace falta esto

Al clonar la misma imagen a todos los equipos, dos cosas se heredan
idénticas en los 100 clones y hay que corregirlas:

- El `machine-id` de systemd y las claves de host de SSH (la identidad del
  propio servidor SSH) son iguales en todos los equipos. Si no se
  regeneran, cualquiera con acceso a un equipo tendría la misma clave de
  host que el resto del aula (riesgo de suplantación).
- La contraseña temporal de `ansible-admin` también es igual en todos los
  equipos. Hay que sustituirla por autenticación por clave y desactivarla
  cuanto antes, para minimizar el tiempo en que un alumno podría usarla.

El `deviceid` de GLPI-Agent no aparece en esta lista porque el agente se
instala **después** de clonar (vía Ansible), así que cada equipo genera el
suyo desde cero sin arrastrar nada de la plantilla.

---

## Fase 0 — Preparar el PC del profesor (`instalar_ansible_profesor.sh`)

Se ejecuta **una sola vez por PC de profesor** (no por aula), y lo ejecuta
el coordinador TIC como `depinfo` (o con sudo). Instala Ansible a nivel de
sistema, prepara la identidad `ansible-admin` (clave SSH + carpeta de
trabajo) y da permiso de sudo a los profesores concretos indicados.

Antes de lanzarlo, edita dentro del script la variable
`DOMAIN_ADMIN_USERS` con los nombres de usuario de dominio del profesor de
mañana y el de tarde de esa aula (compruébalo con `id nombre.usuario` en
ese equipo, ya que SSSD puede resolverlo con mayúsculas/formato distinto
al que esperas):

```bash
DOMAIN_ADMIN_USERS=("profesor.manana" "profesor.tarde")
```

```bash
sudo chmod +x instalar_ansible_profesor.sh
sudo ./instalar_ansible_profesor.sh
```

Al terminar tendrás, dentro del `$HOME` de `ansible-admin`:

```
~ansible-admin/
├── .ssh/ansible-admin_ed25519(.pub)
└── ansible-aulas/
    ├── ansible.cfg
    ├── playbooks/          <- copia aquí 00_regenerate_identity.yml,
    │                           01_bootstrap_keys.yml, 02_harden_ssh.yml
    └── inventarios/
        └── aula1.ini        <- edítalo con las IPs reales de cada aula
```

Y en `/etc/sudoers.d/ansible-aula`, la regla que permite a esos 2
profesores concretos usar `sudo -iu ansible-admin`.

## Uso diario (los 2 profesores autorizados de esa aula)

El profesor de mañana o el de tarde, con su cuenta de dominio, entra en
la identidad de automatización así:

```bash
sudo -iu ansible-admin
cd ~/ansible-aulas
```

Se le pedirá SU propia contraseña de dominio (no la de `ansible-admin`,
que nadie necesita conocer). A partir de ahí, todos los comandos de esta
guía se ejecutan desde `~/ansible-aulas`.

Copia los tres playbooks dentro de `~/ansible-aulas/playbooks/` (una vez,
no hace falta repetirlo cada vez que un profesor entra).

## Requisitos previos adicionales

Un fichero de inventario con los equipos del aula, por ejemplo
`inventarios/aula1.ini` (el script ya deja uno de plantilla):

```ini
[aula1]
pc01 ansible_host=192.168.1.101
pc02 ansible_host=192.168.1.102
pc03 ansible_host=192.168.1.103
# ...
```

(La IP de cada equipo debería salir del mapeo MAC→hostname→IP que ya
gestiona DRBL, para no mantener dos listas distintas de lo mismo.)

---

## Paso 0 — Regenerar identidad (`00_regenerate_identity.yml`)

Regenera el `machine-id` y las claves de host de SSH de cada equipo.
Todavía se usa la contraseña temporal.

```bash
ansible-playbook -i inventarios/aula1.ini playbooks/00_regenerate_identity.yml \
    --ask-pass -u ansible-admin \
    --ssh-common-args='-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null'
```

Te pedirá la contraseña temporal una vez (se usa para todos los equipos
del inventario). El aviso de `StrictHostKeyChecking=no` es intencionado:
en este primer contacto todos los equipos comparten la misma clave de host
(heredada de la plantilla) y además este mismo playbook se la va a cambiar,
así que no tiene sentido validarla todavía.

## Paso 1 — Copiar la clave pública (`01_bootstrap_keys.yml`)

```bash
ansible-playbook -i inventarios/aula1.ini playbooks/01_bootstrap_keys.yml \
    --ask-pass -u ansible-admin \
    -e pubkey_path=~/.ssh/ansible-admin_ed25519.pub \
    --ssh-common-args='-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null'
```

Copia la clave pública de `ansible-admin` a `~/.ssh/authorized_keys` en
cada equipo. Al final del playbook verás un aviso recordándote el paso
siguiente.

## Verificación (obligatoria antes de continuar)

No sigas al paso 2 sin comprobar antes que la clave funciona en TODOS los
equipos. Esta vez sí queremos que Ansible recuerde la clave de host nueva
de cada uno (para detectar de verdad una suplantación en el futuro), así
que se usa `accept-new` en vez de desactivar la comprobación:

```bash
ansible all -i inventarios/aula1.ini -m ping -u ansible-admin \
    --ssh-common-args='-o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=accept-new'
```

- Si **todos** responden `"pong"` → continúa con el paso 2.
- Si **alguno falla** → NO continúes. Revisa ese equipo en concreto (red,
  que el paso 0/1 se completara bien, etc.) antes de desactivar la
  contraseña en el resto.

## Paso 2 — Desactivar la contraseña (`02_harden_ssh.yml`)

Ya no hace falta `--ask-pass`: se conecta con la clave (el `ansible.cfg`
ya apunta a ella por defecto).

```bash
ansible-playbook -i inventarios/aula1.ini playbooks/02_harden_ssh.yml -u ansible-admin
```

Desactiva `PasswordAuthentication` en `sshd_config` y bloquea además la
contraseña local de `ansible-admin` como segunda capa
(`passwd -l`). A partir de aquí, el acceso a esos equipos es solo por
clave. Como el PC del profesor está en el mismo inventario (se clonó
igual que los demás), también se le aplica este mismo endurecimiento sin
pasos adicionales.

---

## Checklist rápido (para repetir aula por aula)

1. *(Solo la primera vez, por PC de profesor, como `depinfo`)*
   `instalar_ansible_profesor.sh`
2. Clonar el aula con DRBL + Clonezilla.
3. *(Profesor autorizado)* `sudo -iu ansible-admin` y `cd ~/ansible-aulas`
4. Crear/actualizar `inventarios/aulaN.ini` con las IPs de esa aula.
5. `00_regenerate_identity.yml` (con `--ask-pass`)
6. `01_bootstrap_keys.yml` (con `--ask-pass`)
7. `ansible ... -m ping` con la clave → comprobar que responden todos
8. `02_harden_ssh.yml` (ya sin contraseña)
9. A partir de aquí, gestión normal del aula con el resto de playbooks
   (GLPI-Agent, software específico del ciclo, etc.)

## Notas / problemas típicos

- **`sudo -iu ansible-admin` dice "not in the sudoers file"**: tu usuario
  de dominio no está en `DOMAIN_ADMIN_USERS` de esa aula, o el nombre no
  coincide exactamente con el que resuelve SSSD en ese equipo (compruébalo
  con `id tu.usuario`). Pide al coordinador TIC que lo revise/añada con
  `sudo visudo -f /etc/sudoers.d/ansible-aula`.
- **Cambia el profesor de mañana o tarde**: no hace falta relanzar todo el
  script. Basta con que el coordinador TIC edite esa misma lista con
  `sudo visudo -f /etc/sudoers.d/ansible-aula` (añadir/quitar un nombre en
  el `User_Alias AULA_ADMINS`).
- **Un equipo no responde al ping tras el paso 1**: no lances el paso 2
  para el resto asumiendo que "ya se arreglará". Repite los pasos 0 y 1
  solo para ese equipo (`ansible-playbook ... --limit pc07`) y vuelve a
  verificar antes de tocar la contraseña.
- **"REMOTE HOST IDENTIFICATION HAS CHANGED"** al conectar a mano con
  `ssh`: es esperado la primera vez tras el paso 0 (la clave de host
  cambió de verdad, a propósito). Bórralo de tu `known_hosts` solo la
  primera vez, o usa directamente el comando de verificación de arriba.
- **`sshpass: command not found` o `ansible: command not found`**: no se
  ejecutó (o falló) `instalar_ansible_profesor.sh` en ese PC de profesor.
- **`msg: 'authorized_key' is not a valid attribute...` o similar** al
  lanzar `01_bootstrap_keys.yml`: falta la colección `ansible.posix`
  (`ansible-galaxy collection install ansible.posix`, ya la instala el
  script de la Fase 0, como `ansible-admin`).
