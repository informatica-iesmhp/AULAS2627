# Diagnóstico: bootstrap de IF01-IF04 (Linux Mint 22.3 + Ansible)

**Fecha:** 2026-09-10 (actualizado el mismo día con la confirmación de cómo se construyó la maqueta)
**Contexto:** maqueta Mint 22.3 desplegada con Clonezilla en IF01 e IF02 (pendientes IF03/IF04). Objetivo: dejar los equipos gestionables con Ansible (usuario `ansible-admin`) tras el clonado.

**Cómo se construyó la maqueta (confirmado):** instalación limpia normal de Linux Mint 22.3 en un equipo del aula, con el software instalado a mano después. **No se ha usado nada de la carpeta `Mint/` del repositorio** (ni la ISO personalizada, ni `0a-CreaISO.sh`, ni `3-SetupPrimerInicio.sh`, ni `NombreIP.sh`). El usuario `ansible-admin` se creó con un script aparte (`preparaclienteansibleadmin.sh`): `useradd -m`, contraseña temporal `AulaAnsible2026`, grupo `sudo` **y sudo sin contraseña** (`ansible-admin ALL=(ALL) NOPASSWD:ALL` en `/etc/sudoers.d/90-ansible-users`). Esto confirma uno de los supuestos que dejé pendientes de verificar más abajo: `ansible-admin` **no necesita `--ask-become-pass`**, el `become` de Ansible funciona directo.

Esto no cambia el diagnóstico de fondo — al contrario, lo refuerza: al ser una instalación 100% manual, es sistemáticamente imposible que exista ningún mecanismo de "primer arranque" en la maqueta (ni siquiera el limitado `NombreIP.sh`, que tampoco habría servido para IF01-04). La recomendación de meter `configurar_equipo.sh` como servicio de primer arranque para IF03/IF04 (sección 5) sigue siendo, si acaso con más motivo, el camino a seguir.

Repositorio analizado: `informatica-iesmhp/AULAS2627` (ficheros `instalar_ansible_profesor.sh`, `00_despliegue_aula_README.md`, `00_regenerate_identity.yml`, `01_bootstrap_keys.yml`, `02_harden_ssh.yml`, `configurar_equipo.sh`, `macs.csv`, `ansible_bootstrap.zip`, más el resto del repo para contexto — en particular la línea `Ubuntu/` y su rol `preparaAD`, que ya resolvió un problema hermano de este).

---

## Resumen para no perderse

Hay **dos problemas distintos** mezclados, y conviene no confundirlos:

1. **El problema que ya estás viendo**: los equipos recién clonados no tienen IP/nombre propio todavía, así que el inventario de Ansible no puede alcanzarlos. Es un problema de "huevo y gallina" — lo explico abajo.
2. **Un problema que probablemente NO has visto todavía pero que es más grave**: la maqueta se unió al dominio **antes** de clonarla. Si es así, todos los clones de IF01/IF02 están compitiendo por la misma identidad de equipo en el Active Directory, y en algún momento vas a ver fallos de confianza de dominio intermitentes y difíciles de diagnosticar. Esto es prioritario a resolver, aunque todavía no dé síntomas.

Además hay dos bugs concretos y fáciles de arreglar en los ficheros que ya tienes: `IF02` no está registrado en `macs.csv`, y el playbook de `ansible_bootstrap.zip` intenta conectar como un usuario (`alumno`) que no existe en esta maqueta.

---

## 1. El problema del huevo y la gallina (por qué `01_bootstrap_keys.yml` no conecta)

Piénsalo como repartir cartas certificadas a un edificio nuevo de pisos: para entregarlas necesitas saber el número de cada piso, pero los números de piso todavía no están puestos en las puertas. Los tres playbooks "oficiales" (`00_regenerate_identity.yml`, `01_bootstrap_keys.yml`, `02_harden_ssh.yml`) asumen que el inventario (`aula1.ini`) **ya tiene la IP real de cada equipo** — el propio README lo dice: *"La IP de cada equipo debería salir del mapeo MAC→hostname→IP que ya gestiona DRBL"*. Es decir: esos playbooks dan por hecho que, al terminar el clonado, cada equipo **ya se llama como debe y tiene su IP fija**.

Eso es justo lo que en las líneas Ubuntu/Mint "oficiales" (ISO completa) hace el paso de primer arranque: `3-SetupPrimerInicio.sh` (dentro de la ISO) ejecuta un script (`NombreIP.sh` en el caso Mint) **en el propio equipo**, nada más arrancar por primera vez en el aula, que mira su MAC en `macs.csv` y se pone nombre e IP fija él solito, sin que nadie tenga que conectarse por SSH desde fuera.

Tu maqueta 22.3, según la documentación del propio repo (`Mint/CLAUDE.md`: *"ISO 22.3: la carpeta `ISO/22.3/` solo tiene `utiles/`; falta adaptar `0a-CreaISO.sh`"*), **no se generó con esa cadena completa**: es una imagen preparada a mano y clonada directamente con Clonezilla, así que no lleva ese paso de "primer arranque". Resultado: todos los clones nacen con el mismo nombre (o el de la plantilla) y sin IP fija — de ahí que el inventario no pueda apuntar a nada todavía.

**Ya tienes la pieza que falta**, además, mejor hecha que la versión "oficial": `configurar_equipo.sh` (en la raíz del repo) hace exactamente esto — busca la MAC en `macs.csv`, calcula nombre e IP, y es genérico (no tiene el aula hardcodeada, a diferencia de `Mint/utiles/NombreIP.sh`, que solo reconoce IABD y SMRD y se quedaría de brazos cruzados en IF01-04 aunque lo tuvieras instalado). Lo que falta es *dónde y cuándo* se ejecuta.

---

## 2. Por qué probablemente falló también `ansible_bootstrap.zip`

Revisando `ansible_bootstrap.zip` (y `ansible_bootstrap_1.zip`, una versión anterior con los mismos ficheros): `group_vars/all.yml` define:

```yaml
ansible_user: alumno
```

Ese usuario **no existe en tu maqueta** — tú mismo dices que solo hay dos usuarios locales, `depinfo` y `ansible-admin`. Todo el repo, en el resto de aulas (`equiposIABD.ini`, `equiposSMRD.ini`, `equiposIF04.ini` de la línea Ubuntu…), usa `ansible_user=root`. Todo apunta a que ese `ansible_bootstrap.zip` es una plantilla heredada de otro planteamiento (aulas más antiguas con cuenta de alumno) que nadie adaptó a este esquema `depinfo`/`ansible-admin`. Con ese usuario, Ansible no debería ni llegar a autenticar por SSH contra ningún equipo del aula — es, con bastante seguridad, el motivo real por el que ese intento no funcionó, más allá del problema de IP.

Cámbialo a `ansible-admin` (con `--ask-pass`, usando la contraseña temporal `AulaAnsible2026` común a toda la maqueta, tal y como ya hace `00_regenerate_identity.yml`). Como `ansible-admin` tiene sudo **sin contraseña** (`NOPASSWD:ALL`, confirmado en `preparaclienteansibleadmin.sh`), no hace falta `--ask-become-pass`: con `--ask-pass` es suficiente.

---

## 3. `IF02` no está en `macs.csv`

En el `macs.csv` del repo solo hay secciones para `CEIABD`, `DISTANCIA`, `IF04`, `IF03` e `IF01`. **No hay ninguna sección `IF02`.** Aunque arregles todo lo demás, `configurar_equipo.sh` fallará en cualquier equipo de IF02 con *"La MAC ... no aparece en macs.csv"*, porque no hay nada que buscar. Esto es independiente del resto de problemas y bloquea IF02 aunque el mecanismo de bootstrap funcione perfectamente.

Hay que añadir una sección `AULA IF02 (red 10.0.13.x)` con el listado MAC→equipo→IP, con el mismo formato que las demás (`IF02-00` para el profesor, `IF02-01`... para los alumnos).

---

## 4. El problema silencioso: unión al dominio antes de clonar

Este es, para mí, el hallazgo más importante del análisis, aunque no sea el que te está bloqueando *ahora mismo*.

Dices que *"el Linux Mint de la maqueta ya está agregado al dominio del centro"*. Si eso significa que uniste la **imagen origen** (la que luego clonas con Clonezilla) al dominio **antes** de clonarla, tienes un problema análogo al del `machine-id`/claves SSH que `00_regenerate_identity.yml` ya corrige — pero para la identidad de dominio, y sin ningún playbook que lo arregle todavía.

La analogía: es como plastificar el DNI antes de rellenar el nombre, y luego hacer 20 fotocopias plastificadas idénticas y repartirlas a 20 alumnos distintos. Cada equipo clonado comparte la **misma cuenta de equipo** en el Active Directory (mismo SID, mismo *keytab* de Kerberos). El controlador de dominio no sabe distinguir cuál de los 20 clones es "el de verdad"; normalmente el síntoma es intermitente y confuso: unos equipos funcionan bien un rato y luego empiezan a fallar con *"no se puede establecer una relación de confianza entre esta estación de trabajo y el dominio"*, sin patrón claro de cuándo ni en cuál.

Esto **ya lo vivió y documentó el propio proyecto** en la línea Ubuntu (rol `preparaAD`, ver `Ubuntu/ansible/roles/preparaAD/LeemeComoUnirAlDominio.md`). Ahí explican explícitamente por qué la unión al dominio **nunca** debe ir en la imagen/primer arranque:

> *"La unión debe hacerse con el hostname definitivo; si `NombreIP.sh` fallara, se crearía una cuenta de equipo basura en el dominio."* / *"Un join fallido no debe arriesgar el despliegue."*

Además, aunque **renombres** el equipo después (con `configurar_equipo.sh`), el *keytab* de Kerberos y la configuración de SSSD siguen atados al nombre con el que se unió originalmente la plantilla — así que lo más probable es que, tras el cambio de hostname, la autenticación de dominio en esos equipos deje de funcionar del todo, incluso sin contar el problema de la cuenta compartida.

De hecho, en `Mint/ansible/roles.yaml` la propia lista de roles tiene, literalmente, una línea:

```
#      - predominio    #ficheros necesarios para unir el equipo al dominio
```

en la sección `#POR HACER` — es decir: el rol equivalente a `preparaAD` para la línea Mint **todavía no existe**. La unión al dominio de la maqueta se hizo a mano, sin ese mecanismo de seguridad.

**Qué hacer:**
- Comprueba en el Active Directory (Usuarios y equipos de AD, o `dsquery computer`) si hay una única cuenta de equipo peleándose por las ~20-40 máquinas ya clonadas de IF01/IF02, o síntomas de re-registro constante.
- Si es así, lo más limpio es: sacar del dominio cada equipo ya clonado (`realm leave`, o localmente `net ads leave` si se unió con Samba/AD), terminar primero de darle nombre e IP definitivos, y **entonces** volver a unir cada equipo individualmente al dominio (con su hostname ya correcto). El proyecto ya tiene toda esta lógica resuelta y documentada para Ubuntu (`utilesAD/3-UneAlDominio.sh` / `4-SacaDelDominio.sh`, con cuenta delegada `svc-union-linux` y vault cifrado) — merece la pena adaptarla a Mint en vez de reinventarla, aunque sea a mano al principio.
- Para IF03/IF04 (todavía sin desplegar): **no unas la maqueta/plantilla al dominio antes de clonar**. Únela después, equipo a equipo, una vez tenga su nombre definitivo — igual que ya hace (y explica muy bien por qué) el rol `preparaAD` en la línea Ubuntu.

### Playbook creado: `03_reunir_dominio.yml` (11/09)

Con SSH por clave ya funcionando en IF01/IF02, se ha escrito `03_reunir_dominio.yml` (entregado como fichero aparte, no vive todavía en el repo) para resolver esto por Ansible en vez de a mano equipo a equipo. Por cada host: comprueba que el hostname ya es el definitivo, saca del dominio actual si lo hay (`realm leave` + limpieza de caché SSSD), comprueba reloj NTP sincronizado (si no, aborta ese equipo para no dejar una cuenta huérfana), y vuelve a unir (`realm join`) con identidad propia, reponiendo `pam_sss`/`nsswitch` al final (mismo problema que ya documentó el proyecto en `preparaAD` al re-unir equipos).

Es idempotente (si un equipo ya está bien, no lo toca) y exige `-e confirmar_reunion=true` a propósito, para que no se lance por error. Pensado para probarse primero con `--limit UN_EQUIPO` antes de lanzarlo a un aula entera. Necesita credenciales de un usuario de dominio con permisos de crear/borrar cuentas de equipo (pasadas por `-e` o, mejor, por `ansible-vault`) y asume el dominio `iesmhp.local` (variable `ad_dominio`, cambiar si no es ese) y que la unión existente usa `realmd`/`sssd-ad`/`adcli` (si el `login` de dominio ya funciona en los equipos, debería ser el caso).

Pendiente de probar en un equipo real — no se ha podido validar contra un Active Directory de verdad desde aquí, solo la sintaxis YAML.

### Aclaración (10/09, tras probar login de dominio en un equipo desplegado)

Se ha comprobado que el login con un usuario de dominio en un equipo ya desplegado **funciona sin problema**. Eso **no descarta** el problema — es justo el comportamiento esperado incluso en el caso patológico: el login de un usuario normal pasa por Kerberos con las credenciales **del usuario**, no por la cuenta de equipo, así que sigue funcionando aunque 20 clones compartan la misma cuenta de máquina. Kerberos no comprueba "¿esta cuenta de equipo ya se está usando desde otra IP ahora mismo?".

Lo que arriesga la cuenta de equipo compartida no es el login del día a día, sino cosas que solo se notan más adelante y de forma intermitente: rotación automática de la contraseña de máquina (si algún día se activa, cualquier PC "resetea" sin querer el acceso del resto), imposibilidad de distinguir en las auditorías del controlador de dominio qué PC físico hizo qué (todos comparten identidad), y aplicación de políticas de equipo (GPO) ambigua. Además, como se renombraron los equipos después de la unión, en el AD debería verse **una sola cuenta de equipo** con el nombre original de la plantilla (no `IF01-05`, `IF01-06`, etc.) — mira "Usuarios y equipos de Active Directory" cuando tengas 5 minutos; si ves solo un objeto de equipo Linux con un nombre que no coincide con ningún hostname real del aula, confirma el diagnóstico. No es bloqueante hoy y no exige rehacer nada: se puede arreglar más adelante equipo a equipo (`realm leave` + `realm join` con el hostname ya correcto), incluso con otro playbook de Ansible una vez tengas SSH por clave funcionando — no compite con la prioridad de ahora mismo.

---

## 5. Otros detalles menores encontrados

- `configurar_equipo.sh` vuelve a descargar `macs.csv` desde GitHub (clonando el repo entero o con `curl` sobre el raw) **en cada uno de los equipos**, en cada ejecución. Funciona, pero añade una dependencia de Internet en cada PC del aula justo en el momento más temprano posible (recién arrancado, sin identidad todavía). Sería más robusto que el propio playbook de Ansible copie el `macs.csv` que ya tienes en local (junto al script) en vez de depender de que cada cliente llegue a GitHub. Si vas a meter `configurar_equipo.sh` como servicio de primer arranque dentro de la imagen (ver más abajo), esto deja de ser un problema para ese caso, pero seguiría afectando al camino "vía Ansible" que usaste para IF01/IF02.
- `Mint/utiles/NombreIP.sh` apunta a `https://raw.githubusercontent.com/victormuelacarriles/IAC-IESMHP/...` (repositorio personal antiguo, no la organización actual `informatica-iesmhp/AULAS2627`). Es informativo — ese script no se usa para IF01-04 de todas formas — pero si en algún momento lo reactivas, esa URL está desactualizada.

---

## Plan de acción — restricción confirmada: NO se rehace la maqueta (van justos de tiempo)

Todo lo que sigue son cambios sobre los equipos ya clonados (por SSH/Ansible) y sobre ficheros del repo (script/CSV), **no** sobre la maqueta ni sobre el proceso de creación de la imagen. Nada de esto implica reinstalar ni volver a preparar la maqueta.

### Runbook para IF01 e IF02 (equipo del profesor, usuario `ansible-admin`)

**0. Un mínimo, en cada PC de profesor (control node), antes de nada:**
```bash
sudo apt install -y nmap   # instalar_ansible_profesor.sh instala ansible/sshpass/colecciones, pero NO nmap
```

**1. Arreglar `macs.csv` (bloquea IF02 entero):** añadir una sección nueva con el mismo formato que las demás:
```
#,#,#, AULA IF02 (red 10.0.13.x)                          ########################
<MAC>, IF02-00, 100, equipo profesor
<MAC>, IF02-01, 101, equipo alumno
...
```
Las MACs de IF02 no están en ningún fichero que yo haya visto — hay que recogerlas. Truco rápido: un `sudo nmap -sn 10.0.13.0/24` desde el equipo del profesor de esa aula, ejecutado como root, muestra en el mismo escaneo la IP (DHCP) **y** la MAC de cada equipo vivo de la subred (`nmap -sn ... -oG -` lo deja en formato fácil de parsear). Con eso construyes la tabla sin ir puesto por puesto. La numeración PC-NN es cosa tuya (por orden de aula, de MAC, o como prefieras); no tiene que coincidir con nada previo. Esto lo tiene que subir alguien con permisos de escritura en el repo (según el `CLAUDE.md` del proyecto, normalmente Víctor).

**2. Arreglar el usuario en `ansible_bootstrap.zip`:** descomprime el zip conservando la estructura de carpetas (debe quedar `ansible/playbooks/bootstrap_equipos.yml`, `ansible/playbooks/escanear_aula.sh`, `ansible/group_vars/all.yml`, `ansible/inventory/...`) **dentro de un clon completo del repo** (para que `script_local: "../../configurar_equipo.sh"` encuentre el script en la raíz). Por ejemplo, como `ansible-admin`:
```bash
sudo -iu ansible-admin
cd ~/ansible-aulas
git clone https://github.com/informatica-iesmhp/AULAS2627.git repo
cd repo
unzip /ruta/a/ansible_bootstrap.zip -d .
```
Edita `repo/ansible/group_vars/all.yml`: cambia `ansible_user: alumno` por `ansible_user: ansible-admin`.

**3. Configurar primero, a mano, el PC del propio profesor** (ya lo tienes delante, no hace falta red/Ansible para él):
```bash
sudo ./configurar_equipo.sh
```
Así queda con su nombre e IP correctos (`IF01-00` / `IF02-00`) antes de lanzar nada contra el resto del aula; como el script es idempotente, si luego el barrido de red también lo detecta, no le hará nada.

**4. Barrido + bootstrap del resto del aula** (alumnos), desde `repo/ansible/playbooks`:
```bash
cd ~/ansible-aulas/repo/ansible/playbooks
./escanear_aula.sh 10.0.16.0/24 --ask-pass      # IF01
./escanear_aula.sh 10.0.13.0/24 --ask-pass      # IF02
```
(Sin `sudo` delante del script — solo pedirá `sudo` para el propio escaneo `nmap`.) Como contraseña SSH: `AulaAnsible2026`. No hace falta `--ask-become-pass` (sudo sin contraseña ya configurado). Esto copia y lanza `configurar_equipo.sh` en cada equipo vivo detectado; cada uno cambiará su nombre e IP y se caerá la conexión SSH de ese intento — es el comportamiento esperado (ver comentarios del propio playbook).

**5. Verifica** (esperando ~1 minuto a que todos hayan terminado de renombrarse):
```bash
ping -c1 10.0.16.101   # p.ej., debería responder como IF01-01 ahora
```
Comprueba unos cuantos equipos al azar antes de seguir.

**6. A partir de aquí, sigue el flujo ya documentado en `00_despliegue_aula_README.md`** con el inventario real (`inventarios/if01.ini`, `inventarios/if02.ini`, con las IPs fijas que ya les tocan según `macs.csv`):
```bash
ansible-playbook -i inventarios/if01.ini playbooks/00_regenerate_identity.yml \
    --ask-pass -u ansible-admin \
    --ssh-common-args='-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null'

ansible-playbook -i inventarios/if01.ini playbooks/01_bootstrap_keys.yml \
    --ask-pass -u ansible-admin \
    -e pubkey_path=~/.ssh/ansible-admin_ed25519.pub \
    --ssh-common-args='-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null'

ansible all -i inventarios/if01.ini -m ping -u ansible-admin \
    --ssh-common-args='-o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=accept-new'
# si TODOS responden pong:
ansible-playbook -i inventarios/if01.ini playbooks/02_harden_ssh.yml -u ansible-admin
```
(Repite para IF02 con su propio inventario.) Nota: estos tres playbooks (`00`/`01`/`02`) están en la raíz del repo, no dentro del zip — cópialos a `repo/ansible/playbooks/` o ajusta la ruta al lanzarlos.

Con esto ya tienes SSH por clave funcionando y puedes ejecutar cualquier otro playbook de gestión normal contra IF01/IF02. **El tema del dominio (sección 4) no bloquea nada de este runbook** — es un asunto aparte que puedes dejar para cuando tengas un rato, y arreglarlo también por Ansible una vez tengas clave SSH, sin tocar la maqueta.

### Para IF03/IF04 (todavía no desplegadas)

Puedes desplegarlas exactamente igual, repitiendo este mismo runbook — no es obligatorio cambiar nada. Si en algún momento te sobra media hora, lo único que merece la pena antes de clonar es meter `configurar_equipo.sh` como servicio de primer arranque en la imagen (para que cada clon se autoconfigure sin necesitar este rodeo de nmap/Ansible) y completar su sección en `macs.csv` de antemano — pero es una mejora, no un requisito para salir del paso.

---

## Preguntas frecuentes

### ¿Pasa algo por ejecutar `instalar_ansible_profesor.sh` más de una vez? (p. ej. para añadir a otro profesor)

En general no, está pensado para ser repetible: si `ansible-admin` ya existe no lo vuelve a crear; el `apt-get install` y las colecciones de `ansible-galaxy` no rompen nada por reinstalarse; y **la clave SSH no se regenera** si ya existe (`if [[ -f "$KEY" ]]`) — así que no hace falta repetir `01_bootstrap_keys.yml` en los equipos del aula tras relanzarlo.

El único punto que hay que tener en cuenta es `/etc/sudoers.d/ansible-aula`: el script **no añade** el profesor nuevo a la lista, **reescribe el fichero entero** con lo que haya en ese momento en `DOMAIN_ADMIN_USERS` dentro del script. Si antes de la segunda ejecución se edita esa variable para que contenga **a los dos profesores** (el de antes + el nuevo), el resultado es correcto. Pero si se deja solo con el profesor nuevo, el de antes **pierde** el acceso `sudo -iu ansible-admin` sin previo aviso (se sobrescribe, no se conserva). Merece la pena comprobar después con:
```bash
sudo cat /etc/sudoers.d/ansible-aula
```
que el `User_Alias AULA_ADMINS` lista a los profesores que deberían tener acceso — los que falten no podrán usar `sudo -iu ansible-admin` hasta que se les vuelva a añadir (bien relanzando el script con el array completo, bien con `sudo visudo -f /etc/sudoers.d/ansible-aula` a mano, que es lo que recomienda el propio README para altas/bajas sueltas en vez de relanzar el script entero).

Nota aparte: si el script llega a fallar la validación de sintaxis del sudoers (`visudo -cf`), borra el fichero entero por seguridad — en ese caso **nadie** queda autorizado hasta volver a ejecutarlo bien. El script lo avisa por pantalla si pasa.

---

### `02_harden_ssh.yml` falla con "REMOTE HOST IDENTIFICATION HAS CHANGED" o se queda colgado pidiendo confirmar la clave

Visto el 11/09 en IF01, después de completar con éxito los pasos 0 y 1 y la verificación por `ping`. Es un bug del propio comando de verificación que da el README, no de tu ejecución.

El comando de verificación del README combina **dos opciones que se anulan entre sí**:
```bash
--ssh-common-args='-o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=accept-new'
```
`accept-new` acepta la clave nueva de cada host... pero `UserKnownHostsFile=/dev/null` hace que esa aceptación se escriba al vacío (`/dev/null`) en vez de guardarse de verdad. Resultado: el `ping` de verificación da "pong" en todos (porque acepta la clave en ese momento), pero **no queda ninguna clave guardada** en el `known_hosts` real de `ansible-admin`. Al llegar a `02_harden_ssh.yml`, que no lleva ningún `--ssh-common-args` (usa el `host_key_checking = True` de `ansible.cfg` a pelo, contra el `known_hosts` real), Ansible no tiene nada fiable con qué comparar: para los hosts sin ninguna entrada previa se queda **colgado** pidiendo confirmar la clave por teclado (no se puede responder en una ejecución no interactiva → parece que se cuelga); y para algún host que sí tenía una entrada antigua (p. ej. de una prueba manual con `ssh` antes de regenerar identidades en el paso 0), la clave ya no coincide con la nueva → error "REMOTE HOST IDENTIFICATION HAS CHANGED".

**Arreglo** (corta la ejecución colgada con `Ctrl+C` primero):
```bash
cd ~/ansible-aulas

# 1. Quitar cualquier entrada vieja/errónea de esas IPs
for ip in $(grep -oP 'ansible_host=\K\S+' inventarios/IF01.ini); do
    ssh-keygen -f ~/.ssh/known_hosts -R "$ip"
done

# 2. Rellenar known_hosts con las claves REALES actuales (las que puso el paso 0)
for ip in $(grep -oP 'ansible_host=\K\S+' inventarios/IF01.ini); do
    ssh-keyscan -t ed25519 "$ip" >> ~/.ssh/known_hosts
done

# 3. Relanzar el paso 2 tal cual
ansible-playbook -i inventarios/IF01.ini playbooks/02_harden_ssh.yml -u ansible-admin
```
Repetir para cada aula/inventario (`IF02.ini`, etc.) cuando llegue el momento — este bug se repetirá igual con cualquier aula que siga el README tal cual está ahora. Merece la pena avisar a Víctor para que corrija el comando de verificación del README (quitar `UserKnownHostsFile=/dev/null` de esa línea concreta, dejando solo `StrictHostKeyChecking=accept-new` contra el `known_hosts` real).

**Confirmado que se repite (14/09, en IF03):** mismo síntoma exacto (`REMOTE HOST IDENTIFICATION HAS CHANGED`, esta vez con un tipo de clave distinto — ECDSA guardado vs. ED25519 real), esta vez en `IF03-00` al lanzar `02_harden_ssh.yml`. Importante: **cada PC de profesor tiene su propio `~/.ssh/known_hosts`** (es una máquina distinta, clonada aparte) — arreglar esto en el control node de IF01 **no** arregla el de IF02 ni el de IF03; hay que aplicar el mismo arreglo (los dos bucles `ssh-keygen -R` + `ssh-keyscan`) en cada aula, la primera vez que se llega a `02_harden_ssh.yml` allí. Copiar la clave pública a mano por USB (se probó en IF03) no toca este problema — el fallo no es que falte la clave en el cliente (esa parte, pasos 00/01, ya había ido bien), es que el `known_hosts` del *propio* control node tiene una entrada vieja/de otro tipo para esa IP.

---

## Notas / supuestos a verificar

- ~~Sudo de `ansible-admin`~~ — **Confirmado** (`preparaclienteansibleadmin.sh`): `NOPASSWD:ALL`, contraseña SSH temporal `AulaAnsible2026`. No hace falta `--ask-become-pass`.
- No he podido verificar directamente el estado del Active Directory (cuentas de equipo duplicadas) — es una comprobación que solo se puede hacer desde el controlador de dominio o con herramientas de administración de AD. Sigue siendo el punto más importante a comprobar antes de seguir desplegando IF03/IF04 con el mismo patrón (maqueta ya unida al dominio antes de clonar).
