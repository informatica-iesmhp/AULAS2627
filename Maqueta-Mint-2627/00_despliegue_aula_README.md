# Despliegue seguro de un aula tras clonar la maqueta

Guía y playbooks para dejar operativo el PC del profesor y para el primer
arranque de los equipos de un aula recién clonada con DRBL + Clonezilla,
antes de empezar a gestionarla con el resto de Ansible.

> **Actualizada** tras el despliegue real de IF01/IF02 (septiembre 2026):
> incorpora los ajustes y pasos que faltaban, documentados en
> [`diagnostico-bootstrap-aulas-IF01-IF04.md`](diagnostico-bootstrap-aulas-IF01-IF04.md).
> Esa incidencia sigue existiendo como registro histórico; esta guía es
> la versión "ya depurada" para aplicar en cualquier aula nueva.

## Mapa de ficheros de esta carpeta

Antes de nada, para no perderse entre tantos scripts — cada uno se
ejecuta en un sitio y un momento distintos:

| Fichero | Dónde se ejecuta | Cuándo |
|---|---|---|
| `prep_maqueta.sh` | En la plantilla | Una vez, antes de clonarla (herramientas de sistema + chrony) |
| `prepara-cliente-ansible-admin.sh` | En la plantilla | Una vez, antes de clonarla (crea el usuario `ansible-admin`). **Pese al nombre, no se ejecuta en cada cliente ya clonado** — ya viene hecho de fábrica en todos los clones |
| `instalar_ansible_profesor.sh` | PC del profesor | Una vez por PC de profesor, después de clonar (asume que `ansible-admin` ya existe, heredado de la plantilla) |
| `configurar_equipo.sh` | Cada equipo ya clonado y arrancado | Una vez por equipo, justo tras el primer arranque (le pone nombre e IP fija) |
| `ansible-bootstrap/ansible_bootstrap.zip` | PC del profesor | Herramienta de apoyo para lanzar `configurar_equipo.sh` por red en todo el aula a la vez (ver Fase 1) |
| `00_regenerate_identity.yml` → `03_reunir_dominio.yml` | PC del profesor (como `ansible-admin`) | Playbooks de esta guía, en el orden que se explica más abajo |
| `04_habilitar_escritorio_remoto.yml` | PC del profesor (como `ansible-admin`) | Opcional, cuando haga falta — escritorio remoto (xrdp) para los profesores autorizados, ver sección "Extra" |
| `diagnostico-bootstrap-aulas-IF01-IF04.md` | — | Registro histórico de incidencias de IF01/IF02 y cómo se resolvieron. Fuente de esta actualización |
| `tareas-ansible.md` | — | Lista de tareas pendientes del aula (seguimiento, no técnico) |

## Roles y usuarios (léelo antes de nada)

La maqueta trae dos usuarios locales, y cada uno tiene un papel distinto
que conviene no mezclar:

- **`depinfo`** — administración del sistema operativo. Lo gestiona
  únicamente el coordinador TIC del centro. Es quien ejecuta
  `instalar_ansible_profesor.sh` (necesita permisos de root) y quien
  configuraría cualquier cambio a bajo nivel. No se usa para el día a día
  del aula.
- **`ansible-admin`** — identidad de automatización. Ya existe en todos
  los equipos (incluido el del profesor, clonado igual que los demás),
  con sudo **sin contraseña** (`NOPASSWD:ALL`) configurado de fábrica en
  la plantilla. Aquí viven la clave SSH, la carpeta de trabajo
  `~/ansible-aulas/` y desde aquí se ejecutan los playbooks. Nadie inicia
  sesión gráfica con ella directamente.
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

Como `ansible-admin` tiene sudo sin contraseña en todos los equipos,
**ningún comando de esta guía necesita `--ask-become-pass`** — solo
`--ask-pass` en los pasos que todavía usan la contraseña temporal.

## Resumen del proceso

0. El coordinador TIC prepara el PC del profesor como nodo de control de
   Ansible (`instalar_ansible_profesor.sh`, ejecutado como `depinfo`/root):
   instala Ansible y `nmap`, genera la clave de `ansible-admin`, crea la
   carpeta de trabajo y da permiso de sudo a los 2 profesores concretos
   de esa aula.
1. La maqueta (Linux Mint 22.3) ya tiene SSH activo y el usuario
   `ansible-admin` creado, con una contraseña **temporal** (la misma en
   todos los equipos, porque viene de la misma imagen clonada).
2. Con DRBL + Clonezilla se despliega esa maqueta en todos los equipos del
   aula, incluido el del profesor. **Esta maqueta es una instalación
   manual clonada directamente** (no lleva ningún script de "primer
   arranque" tipo `NombreIP.sh`), así que todos los clones nacen con el
   mismo nombre y por DHCP: no tienen todavía identidad de red propia.
3. Por eso, antes de poder usar ningún inventario de Ansible, hay que
   ponerle a cada equipo su nombre y su IP fija con `configurar_equipo.sh`
   (a mano en el PC del profesor, por red en el resto del aula) — ver
   **Fase 1** más abajo.
4. Ya con nombre e IP definitivos, un profesor autorizado (con su cuenta
   de dominio + sudo) ejecuta, **una sola vez por aula**, en este orden,
   tres playbooks:
   - `00_regenerate_identity.yml`
   - `01_bootstrap_keys.yml` (+ una verificación manual)
   - `02_harden_ssh.yml`
5. Si la maqueta se unió al dominio de Windows **antes** de clonarla,
   todos los clones comparten la misma cuenta de equipo en el Active
   Directory y hay que separarlos con `03_reunir_dominio.yml` — ver
   **Fase 3**. Si no es el caso (o ya está resuelto), este paso no hace
   falta.
6. A partir de ahí, toda la gestión diaria del aula se hace con Ansible
   usando la clave SSH, sin contraseña.

## Por qué hace falta esto

Al clonar la misma imagen a todos los equipos, varias cosas se heredan
idénticas en los 100 clones y hay que corregirlas — es como plastificar
un carnet antes de rellenar el nombre y luego repartir 20 fotocopias
plastificadas idénticas a 20 personas distintas: hasta que no se
personaliza cada copia, nadie puede distinguirlas de verdad.

- Los equipos no tienen todavía nombre ni IP propios (Fase 1): sin eso,
  ni siquiera se les puede escribir un inventario de Ansible que apunte a
  cada uno.
- El `machine-id` de systemd y las claves de host de SSH (la identidad
  del propio servidor SSH) son iguales en todos los equipos. Si no se
  regeneran, cualquiera con acceso a un equipo tendría la misma clave de
  host que el resto del aula (riesgo de suplantación) — Paso 0.
- La contraseña temporal de `ansible-admin` también es igual en todos los
  equipos. Hay que sustituirla por autenticación por clave y desactivarla
  cuanto antes, para minimizar el tiempo en que un alumno podría usarla —
  Pasos 1 y 2.
- Si la plantilla se unió al dominio de Windows antes de clonarla, todos
  los clones comparten la misma cuenta de equipo en el Active Directory
  (mismo SID, mismo *keytab* de Kerberos) — Fase 3.

El `deviceid` de GLPI-Agent no aparece en esta lista porque el agente se
instala **después** de clonar (vía Ansible), así que cada equipo genera el
suyo desde cero sin arrastrar nada de la plantilla.

---

## Fase 0 — Preparar el PC del profesor (`instalar_ansible_profesor.sh`)

Se ejecuta **una sola vez por PC de profesor** (no por aula), y lo ejecuta
el coordinador TIC como `depinfo` (o con sudo). Instala Ansible y `nmap`
a nivel de sistema, prepara la identidad `ansible-admin` (clave SSH +
carpeta de trabajo) y da permiso de sudo a los profesores concretos
indicados. El `nmap` es necesario para la Fase 1 (bootstrap por red del
resto del aula).

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
    ├── ansible.cfg          <- ya trae pipelining=True para ir más rápido
    ├── playbooks/          <- copia aquí 00_regenerate_identity.yml,
    │                           01_bootstrap_keys.yml, 02_harden_ssh.yml
    │                           y 03_reunir_dominio.yml
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

Copia los cuatro playbooks dentro de `~/ansible-aulas/playbooks/` (una
vez, no hace falta repetirlo cada vez que un profesor entra).

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

La IP de cada equipo es la que le asigna `configurar_equipo.sh` según
`macs.csv` (ver Fase 1) — **no** un mapeo automático de DRBL, ya que esta
maqueta no usa ese mecanismo. Comprueba antes de escribir el inventario
que la sección de tu aula existe en `macs.csv` (en la raíz del
repositorio) y que tiene todas las MACs que necesitas.

---

## Fase 1 — Poner nombre e IP fija a los equipos recién clonados

Es el problema del huevo y la gallina: para que Ansible pueda hablar con
un equipo necesita su IP, pero el equipo todavía no tiene una IP fija
propia — como repartir cartas certificadas en un edificio nuevo cuyos
pisos todavía no tienen número en la puerta. `configurar_equipo.sh` es
quien pone esos números: busca la MAC de la interfaz de red en
`macs.csv`, y con eso decide el nombre y el último octeto de IP que le
corresponde a ese equipo concreto, manteniendo el resto de su
configuración de red (máscara, gateway, DNS) tal y como llegó por DHCP.

Es idempotente: si un equipo ya tiene el nombre y la IP correctos, no
hace nada.

### 1.1 Comprueba que `macs.csv` tiene tu aula

Antes de nada, abre `macs.csv` (raíz del repositorio) y comprueba que
existe una sección para tu aula, con el mismo formato que las demás
(`AULAN-00` para el equipo del profesor, `AULAN-01`... para los de
alumnos). Si faltan MACs de algún equipo, consíguelas con un barrido de
red desde el PC del profesor (una vez que tenga IP en esa subred):

```bash
sudo nmap -sn 10.0.XX.0/24 -oG - | awk '/Up$/{print $2, $3}'
```

Esto da IP y MAC de cada equipo vivo de un vistazo, sin ir puesto por
puesto. Añade las líneas que falten a `macs.csv` (pide a quien tenga
permiso de escritura en el repositorio que las suba si tú no lo tienes).

### 1.2 El PC del profesor, a mano

No hace falta red ni Ansible para configurar el equipo que tienes
delante:

```bash
sudo ./configurar_equipo.sh
```

Déjalo con su nombre e IP correctos (`AULAN-00`) antes de lanzar nada
contra el resto del aula.

### 1.3 El resto del aula, por red

Para no tener que sentarte delante de cada equipo, `ansible-bootstrap/`
trae una herramienta de apoyo (`ansible_bootstrap.zip`) que hace un
barrido de la subred y ejecuta `configurar_equipo.sh` en todos los
equipos vivos que encuentre. Necesita el propio `configurar_equipo.sh`
como hermano de la carpeta `ansible/` que trae el zip, así que
descomprímelo dentro de un clon completo del repositorio, dentro de
`Maqueta-Mint-2627/` (no dentro de `ansible-bootstrap/`):

```bash
sudo -iu ansible-admin
cd ~/ansible-aulas
git clone https://github.com/informatica-iesmhp/AULAS2627.git repo
cd repo/Maqueta-Mint-2627
unzip ansible-bootstrap/ansible_bootstrap.zip -d .
```

Esto deja `ansible/playbooks/bootstrap_equipos.yml` y
`ansible/playbooks/escanear_aula.sh` junto a `configurar_equipo.sh`, que
es justo la ruta relativa que espera el playbook
(`script_local: "../../configurar_equipo.sh"`). Ya viene configurado
para conectar como `ansible-admin` (`group_vars/all.yml`).

Lánzalo con la subred de tu aula (consulta el mapeo aula → subred en los
comentarios de `macs.csv` o en `AULA_SUBRED` dentro de
`configurar_equipo.sh`):

```bash
cd ~/ansible-aulas/repo/Maqueta-Mint-2627/ansible/playbooks
./escanear_aula.sh 10.0.XX.0/24 --ask-pass
```

No lances `escanear_aula.sh` con `sudo` delante (rompería la
autenticación por clave de `ansible-admin` en pasos futuros): el propio
script pide `sudo` solo para el escaneo `nmap` interno. Como contraseña
SSH usa la temporal de `ansible-admin` de esta maqueta. Cada equipo
cambiará su nombre e IP y cortará la conexión SSH de ese intento — es el
comportamiento esperado.

### 1.4 Verifica antes de seguir

Espera aproximadamente un minuto a que todos hayan terminado de
renombrarse y comprueba unos cuantos al azar:

```bash
ping -c1 10.0.XX.101   # debería responder ya como AULAN-01, por ejemplo
```

Con esto, ya puedes escribir el inventario real (`inventarios/aulaN.ini`)
con las IPs fijas que le tocan a cada equipo según `macs.csv`, y seguir
con la Fase 2.

---

## Fase 2 — Identidad SSH y contraseña

Con el inventario ya apuntando a las IPs fijas reales de la Fase 1, se
ejecutan estos tres playbooks, en orden y una sola vez por aula.

### Paso 0 — Regenerar identidad (`00_regenerate_identity.yml`)

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

### Paso 1 — Copiar la clave pública (`01_bootstrap_keys.yml`)

```bash
ansible-playbook -i inventarios/aula1.ini playbooks/01_bootstrap_keys.yml \
    --ask-pass -u ansible-admin \
    -e pubkey_path=~/.ssh/ansible-admin_ed25519.pub \
    --ssh-common-args='-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null'
```

Copia la clave pública de `ansible-admin` a `~/.ssh/authorized_keys` en
cada equipo. Al final del playbook verás un aviso recordándote el paso
siguiente.

### Verificación (obligatoria antes de continuar)

No sigas al paso 2 sin comprobar antes que la clave funciona en TODOS los
equipos. Esta vez sí queremos que Ansible **guarde de verdad** la clave de
host nueva de cada uno en el `known_hosts` real de `ansible-admin` (para
poder detectar una suplantación de verdad en el futuro, y porque
`02_harden_ssh.yml` va a comparar contra ese mismo fichero):

```bash
ansible all -i inventarios/aula1.ini -m ping -u ansible-admin \
    --ssh-common-args='-o StrictHostKeyChecking=accept-new'
```

> Usa **solo** `StrictHostKeyChecking=accept-new`, sin añadir
> `UserKnownHostsFile=/dev/null`: esa combinación se anula a sí misma
> (acepta la clave nueva pero la escribe al vacío en vez de guardarla de
> verdad) y provoca que el paso 2 se quede colgado pidiendo confirmar la
> clave, o falle con "REMOTE HOST IDENTIFICATION HAS CHANGED". Si ya te ha
> pasado, tienes el arreglo en la sección de notas más abajo.

- Si **todos** responden `"pong"` → continúa con el paso 2.
- Si **alguno falla** → NO continúes. Revisa ese equipo en concreto (red,
  que el paso 0/1 se completara bien, etc.) antes de desactivar la
  contraseña en el resto.

### Paso 2 — Desactivar la contraseña (`02_harden_ssh.yml`)

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

(Este playbook ya fija `StrictHostKeyChecking=accept-new` internamente,
así que aunque la verificación anterior no hubiera guardado nada, no se
queda colgado — pero sigue mereciendo la pena hacer bien la verificación,
porque de ahí en adelante otros comandos manuales sí dependen del
`known_hosts` real.)

---

## Fase 3 — Reunir al dominio con identidad propia (`03_reunir_dominio.yml`)

> **Aún no validado contra un Active Directory real** — se ha revisado su
> sintaxis y su lógica, pero no se ha probado todavía en un equipo de
> producción. Pruébalo primero con `--limit` en un único equipo (ver
> abajo) y comprueba a mano que ha quedado bien antes de lanzarlo contra
> un aula entera.

**Solo hace falta si la plantilla se unió al dominio de Windows *antes*
de clonarla.** Es como plastificar un carnet antes de rellenar el nombre
y sacar 20 fotocopias plastificadas idénticas: todos los clones comparten
la misma cuenta de equipo en el Active Directory (mismo SID, mismo
*keytab* de Kerberos). El login de los profesores con su cuenta de
dominio sigue funcionando con normalidad (pasa por Kerberos con las
credenciales del usuario, no de la máquina), así que esto no se nota en
el día a día — pero sí puede dar problemas más adelante y de forma
intermitente: rotación de contraseña de máquina, auditoría de qué PC
físico hizo qué, o aplicación de políticas de equipo (GPO) ambigua.

Compruébalo en "Usuarios y equipos de Active Directory" (o `dsquery
computer`): si ves una única cuenta de equipo con el nombre original de
la plantilla en vez de una por cada `AULAN-NN`, confirma el diagnóstico.

`03_reunir_dominio.yml`, equipo a equipo: comprueba que el hostname ya es
el definitivo (si no, para en seco, para no crear una cuenta de equipo
basura), saca del dominio actual si lo hay, comprueba que el reloj está
sincronizado por NTP (Kerberos exige menos de 5 minutos de desfase; si
no, aborta ese equipo para no dejar una cuenta huérfana), y vuelve a unir
con identidad propia.

Es idempotente y exige `-e confirmar_reunion=true` a propósito. Pruébalo
primero en un equipo:

```bash
ansible-playbook -i inventarios/aula1.ini playbooks/03_reunir_dominio.yml \
    -u ansible-admin --limit AULAN-01 \
    -e confirmar_reunion=true \
    -e ad_dominio=iesmhp.local \
    -e ad_admin_user=TU_USUARIO_DE_DOMINIO \
    -e ad_admin_password=TU_CONTRASEÑA
```

Mejor pasar la contraseña con `ansible-vault` en vez de en línea de
comandos (queda en el historial de la shell):

```bash
cat > vault/dominio-vault.yml <<'EOF'
ad_admin_user: TU_USUARIO_DE_DOMINIO
ad_admin_password: TU_CONTRASEÑA
EOF
ansible-vault encrypt vault/dominio-vault.yml

ansible-playbook -i inventarios/aula1.ini playbooks/03_reunir_dominio.yml \
    -u ansible-admin --limit AULAN-01 \
    -e confirmar_reunion=true -e ad_dominio=iesmhp.local \
    -e @vault/dominio-vault.yml --ask-vault-pass
```

Cuando compruebes que ha ido bien en ese equipo, quita `--limit` y
lánzalo contra el resto del inventario (mejor por partes que todo de
golpe: el playbook ya limita a 3 equipos simultáneos con `serial: 3` para
no saturar el controlador de dominio).

Verificación:

```bash
ansible all -i inventarios/aula1.ini -u ansible-admin \
    -m command -a "realm list --name-only"
```

Cada equipo debe responder con el nombre del dominio.

> **Para aulas nuevas (aún sin desplegar): no unas la plantilla al
> dominio antes de clonarla.** Únela después, equipo a equipo, ya con su
> hostname definitivo (Fase 1 completada) — con este mismo playbook. Así
> te ahorras tener que hacer esta Fase 3 de "arreglo" en el futuro.

---

---

## Extra (opcional) — Escritorio remoto para los profesores (`04_habilitar_escritorio_remoto.yml`)

> **Pendiente de validar en un equipo real.** Igual que `03_reunir_dominio.yml`,
> se ha revisado su lógica pero no se ha probado todavía contra la
> maqueta. Pruébalo primero con `--limit` en un equipo y entra de verdad
> por escritorio remoto antes de darlo por bueno en toda el aula.

No forma parte del bootstrap obligatorio (Fases 0-3): es una comodidad
para que los profesores autorizados puedan conectarse por escritorio
remoto a **cualquier equipo del aula** (el del profesor o uno de alumno)
desde otro PC **dentro de la red del centro** — para preparar algo con
antelación, o para entrar cuando otro compañero está dando clase en ese
momento en esa aula. No pensado para conectarse desde fuera del centro
(eso necesitaría, como mínimo, una VPN delante — nunca expongas el puerto
RDP a Internet).

Usa `xrdp` con el backend `xorgxrdp`: cada conexión remota abre una
sesión gráfica **nueva e independiente**, no la que ya esté encendida en
la pantalla física — así un profesor puede entrar en remoto con su propia
sesión mientras otro sigue dando clase con la suya, sin pisarse. Cada uno
entra con **su propia cuenta de dominio** (nunca con `ansible-admin`, que
no tiene contraseña utilizable desde el Paso 2).

### Requisitos

- Fases 0-2 ya aplicadas en esa aula (login de dominio y SSH por clave
  funcionando).
- Define, antes de lanzarlo, quién puede conectarse y desde qué red, en
  un fichero de `group_vars` de esa aula (así no hay que teclearlo cada
  vez ni arriesgarse a olvidar a alguien al ampliar la lista):

```bash
mkdir -p ~/ansible-aulas/group_vars
cat > ~/ansible-aulas/group_vars/aula1.yml <<'EOF'
xrdp_allowed_users:
  - profesor.manana
  - profesor.tarde
red_centro_cidr: 10.0.0.0/16   # <-- AJUSTA a la red real del centro
EOF
```

(`aula1` debe coincidir con el nombre del grupo de tu inventario, p.ej.
`[aula1]` en `inventarios/aula1.ini`.)

### Ejecución

Prueba primero en un solo equipo:

```bash
ansible-playbook -i inventarios/aula1.ini playbooks/04_habilitar_escritorio_remoto.yml \
    -u ansible-admin --limit pc01
```

Conéctate con el cliente de Escritorio remoto (RDP) de Windows, o
`xfreerdp`/Remmina desde Linux, a la IP de ese equipo, con la cuenta de
dominio de uno de los profesores de `xrdp_allowed_users`. Si funciona,
lánzalo sin `--limit` contra el resto del aula.

Para **añadir** un profesor más adelante, edita la lista
`xrdp_allowed_users` del `group_vars` (con todos los que deban seguir
teniendo acceso, no solo el nuevo) y vuelve a lanzar el playbook — igual
que con `/etc/sudoers.d/ansible-aula`, la lista se sobreescribe entera en
cada ejecución, no se amplía sola.

### Qué toca (y qué no)

- Instala `xrdp` + `xorgxrdp`, y restringe quién puede autenticarse por
  RDP a la lista `xrdp_allowed_users` (con `pam_listfile` sobre el
  servicio `xrdp-sesman`). Esta restricción **no afecta** al login
  gráfico local (consola), ni a SSH, ni a `sudo` — solo al acceso por
  RDP.
- Si es la primera vez que se activa `ufw` en esa aula (hasta ahora
  `prep_maqueta.sh` lo dejaba parado a propósito), el playbook permite
  primero el propio SSH (perfil `OpenSSH`) antes de activar el
  cortafuegos, para no cortarle a Ansible el acceso a sí mismo. Ten en
  cuenta que, a partir de aquí, esa aula ya tiene cortafuegos: si más
  adelante configuráis Veyon o cualquier otro servicio con puertos
  propios, habrá que añadir su regla de `ufw` — este playbook no lo hace.

## Checklist rápido (para repetir aula por aula)

1. *(Solo la primera vez, por PC de profesor, como `depinfo`)*
   `instalar_ansible_profesor.sh`
2. Clonar el aula con DRBL + Clonezilla.
3. Comprobar que `macs.csv` tiene la sección de esa aula completa
   (Fase 1.1); si faltan MACs, recogerlas con `nmap -sn`.
4. *(En el PC del profesor, a mano)* `sudo ./configurar_equipo.sh`
   (Fase 1.2).
5. *(Resto del aula)* `escanear_aula.sh <subred> --ask-pass` (Fase 1.3) y
   verificar que responden con su IP nueva (Fase 1.4).
6. *(Profesor autorizado)* `sudo -iu ansible-admin` y `cd ~/ansible-aulas`
7. Crear/actualizar `inventarios/aulaN.ini` con las IPs fijas ya
   asignadas en el paso 4-5.
8. `00_regenerate_identity.yml` (con `--ask-pass`)
9. `01_bootstrap_keys.yml` (con `--ask-pass`)
10. `ansible ... -m ping` con `accept-new` (sin `UserKnownHostsFile=/dev/null`)
    → comprobar que responden todos
11. `02_harden_ssh.yml` (ya sin contraseña)
12. *(Solo si la plantilla se unió al dominio antes de clonar)*
    `03_reunir_dominio.yml`, primero con `--limit` en un equipo.
13. A partir de aquí, gestión normal del aula con el resto de playbooks
    (GLPI-Agent, software específico del ciclo, etc.)
14. *(Opcional)* `04_habilitar_escritorio_remoto.yml` si los profesores
    necesitan entrar por escritorio remoto desde dentro del centro —
    primero con `--limit` en un equipo, ver sección "Extra" más arriba.

## Notas / problemas típicos

- **`sudo -iu ansible-admin` dice "not in the sudoers file"**: tu usuario
  de dominio no está en `DOMAIN_ADMIN_USERS` de esa aula, o el nombre no
  coincide exactamente con el que resuelve SSSD en ese equipo (compruébalo
  con `id tu.usuario`). Pide al coordinador TIC que lo revise/añada con
  `sudo visudo -f /etc/sudoers.d/ansible-aula`.
- **Cambia el profesor de mañana o tarde**: no hace falta relanzar todo el
  script. Basta con que el coordinador TIC edite esa misma lista con
  `sudo visudo -f /etc/sudoers.d/ansible-aula` (añadir/quitar un nombre en
  el `User_Alias AULA_ADMINS`). Si en cambio se relanza
  `instalar_ansible_profesor.sh` con `DOMAIN_ADMIN_USERS` actualizado,
  ten en cuenta que **reescribe el fichero entero**: si dejas solo al
  profesor nuevo en la lista, el anterior pierde el acceso sin previo
  aviso. Comprueba después con `sudo cat /etc/sudoers.d/ansible-aula` que
  el `User_Alias AULA_ADMINS` lista a todos los que deberían tener acceso.
  Si el script detecta un error de sintaxis en el sudoers, borra el
  fichero entero por seguridad — en ese caso, hasta volver a ejecutarlo
  bien, **nadie** queda autorizado.
- **`sudo apt install -y nmap` / `ansible-galaxy collection install
  ansible.posix community.general`**: ya los instala
  `instalar_ansible_profesor.sh`; si ves "command not found" para
  `nmap` o el módulo `authorized_key`/`community.general.nmap` no
  existe, es que ese PC de profesor no ha corrido el script (o falló a
  medias) — vuelve a lanzarlo, es repetible.
- **Un equipo no responde al ping tras el paso 1**: no lances el paso 2
  para el resto asumiendo que "ya se arreglará". Repite los pasos 0 y 1
  solo para ese equipo (`ansible-playbook ... --limit pc07`) y vuelve a
  verificar antes de tocar la contraseña.
- **La verificación da "pong" pero `02_harden_ssh.yml` se cuelga o da
  "REMOTE HOST IDENTIFICATION HAS CHANGED"**: revisa que el comando de
  verificación que usaste fue exactamente el de esta guía
  (`StrictHostKeyChecking=accept-new` **sin** `UserKnownHostsFile=/dev/null`).
  Si ya te ha pasado con la combinación antigua, arréglalo así (corta
  primero la ejecución colgada con `Ctrl+C`):
  ```bash
  cd ~/ansible-aulas
  for ip in $(grep -oP 'ansible_host=\K\S+' inventarios/aula1.ini); do
      ssh-keygen -f ~/.ssh/known_hosts -R "$ip"
      ssh-keyscan -t ed25519 "$ip" >> ~/.ssh/known_hosts
  done
  ansible-playbook -i inventarios/aula1.ini playbooks/02_harden_ssh.yml -u ansible-admin
  ```
- **"REMOTE HOST IDENTIFICATION HAS CHANGED"** al conectar a mano con
  `ssh`: es esperado la primera vez tras el paso 0 (la clave de host
  cambió de verdad, a propósito). Bórralo de tu `known_hosts` solo la
  primera vez, o usa directamente el comando de verificación de arriba.
- **`msg: 'authorized_key' is not a valid attribute...`** al lanzar
  `01_bootstrap_keys.yml`: falta la colección `ansible.posix`
  (`ansible-galaxy collection install ansible.posix`, ya la instala el
  script de la Fase 0, como `ansible-admin`).
- **`configurar_equipo.sh` falla con "La MAC ... no aparece en
  macs.csv"**: falta esa MAC en la sección de tu aula (ver Fase 1.1).
  Recógela con `sudo nmap -sn <subred>/24 -oG -` y añádela al CSV.
- **`bootstrap_equipos.yml` no encuentra `configurar_equipo.sh`**: el
  zip de `ansible-bootstrap/` espera quedar descomprimido como hermano de
  `configurar_equipo.sh` (dentro de `Maqueta-Mint-2627/`, no dentro de
  `ansible-bootstrap/`). Repite la Fase 1.3 tal cual.
- **Vas a desplegar una aula nueva y la plantilla ya está en el
  dominio**: no la unas antes de clonar — vale la pena repetirlo, es el
  error que más dolores de cabeza da más adelante y el más difícil de
  diagnosticar. Únela después, equipo a equipo, con `03_reunir_dominio.yml`
  (Fase 3).
- **Escritorio remoto (`04_habilitar_escritorio_remoto.yml`) con pantalla
  en negro o sesión que se corta**: es un problema conocido de Cinnamon
  sobre xrdp; el playbook ya aplica el workaround más habitual
  (`MUFFIN_DISABLE_HW_CURSOR=1`). Si persiste, revisa
  `/var/log/xrdp-sesman.log` y `/var/log/xrdp.log` en ese equipo.
- **Un profesor de `xrdp_allowed_users` no puede conectarse por escritorio
  remoto**: comprueba que su usuario está bien escrito en el
  `group_vars/aulaN.yml` de esa aula tal y como lo resuelve SSSD
  (`id su.usuario`), y que has vuelto a lanzar el playbook después de
  editar la lista (se sobreescribe entera, no se amplía sola — mismo
  comportamiento que `/etc/sudoers.d/ansible-aula`).
