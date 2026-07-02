# Léeme — Cómo unir los equipos al dominio Active Directory (rol `preparaAD`)

Este documento explica **qué deja preparado el rol `preparaAD`**, cómo
comprobar si un equipo está unido al dominio y **cuál es el procedimiento
recomendado para automatizar la unión** cuando se decida dar el paso.

> Documentación técnica del rol (tareas, variables, issues): [`CLAUDE.md`](CLAUDE.md).
> Scripts de apoyo (cuenta delegada en el DC, vault, unión de un equipo): [`utilesAD/`](utilesAD/).
> Referencia oficial: [Ubuntu Server docs — SSSD with Active Directory](https://ubuntu.com/server/docs/how-to/sssd/with-active-directory/).

---

## 1. Qué hace el rol (y qué NO hace)

El rol deja el equipo **preconfigurado** para unirse a un dominio AD.
**Por defecto NO une al dominio** (`preparaad_unir: false`): la unión exige
credenciales y se lanza bajo demanda (sección 4).

### Prerequisitos que implanta en cada equipo

1. **Paquetes del stack de unión**: `realmd` (orquestador `realm
   discover/join/leave`), `sssd-ad` + `sssd-tools` + `libnss-sss` +
   `libpam-sss` (identidad y autenticación contra AD), `adcli` (herramienta
   de unión), `krb5-user` (`kinit`/`klist` para diagnóstico), `packagekit` y
   `bind9-dnsutils` (`dig`/`nsupdate`).
2. **`pam_mkhomedir`** (`pam-auth-update --enable mkhomedir`): en Ubuntu no
   viene activo y, sin él, los usuarios del dominio entrarían **sin carpeta
   personal**. Con esto el home se crea solo en el primer login.
3. **Reloj** (requisito **duro**, no opcional): Kerberos exige menos de
   **5 minutos** de desfase con el controlador de dominio. `preparaad_ntp`
   ([`entornoAD.yml`](entornoAD.yml)) apunta el cliente NTP del equipo al DC —
   el rol **detecta cuál hay** (chrony en Mint/Debian, `systemd-timesyncd` en
   Ubuntu), lo configura y **espera a que sincronice** antes de seguir
   (`chronyc waitsync` / sondeo de `timedatectl`). Si `preparaad_ntp` queda
   vacío o el reloj no sincroniza, la unión hace un *"join a medias"* (crea la
   cuenta de equipo pero la autenticación falla — ver sección 7). El resumen del
   rol informa siempre de si hay sincronización NTP.
4. **Hostname**: aviso si supera **15 caracteres** (límite NetBIOS de la
   cuenta de equipo en AD). Los `IABD-NN`/`SMRD-NN` van sobrados.
5. **`/etc/krb5.conf`** con el realm por defecto (`IESMHP.LOCAL`) y
   localización de los KDC por DNS (`preparaad_dominio: iesmhp.local` en
   [`entornoAD.yml`](entornoAD.yml) — **único punto de cambio** del dominio).

### Detalles de diseño importantes

- El snippet de configuración SSSD (`/etc/sssd/conf.d/10-iac-ad.conf`) solo
  se despliega **después** de la unión. Antes dejaría `sssd.service` como
  unidad fallida en cada arranque (y saltaría la sección 8 de
  `4-Comprobaciones.sh`).
- El módulo `systemd` de Ansible solo se usa con `state: restarted` — nunca
  `enabled:`/`daemon_reload:`, que cuelgan el primer arranque (bugs
  2026-05-17 del rol `rdp`).

---

## 2. Cómo saber si un equipo está unido

El rol lo comprueba en cada pase y lo imprime en su **resumen final** (sale
en el log del play y en `3-SetupPrimerInicio.sh.log`). A mano:

```bash
realm list --name-only     # vacío = NO unido; nombre del dominio = unido
realm list                 # detalle completo (proveedor sssd, políticas…)

# Con el equipo unido, pruebas de fuego:
getent passwd alguien@iesmhp.local   # ¿se resuelve un usuario del dominio?
kinit alguien@IESMHP.LOCAL           # ¿Kerberos da ticket? (realm en MAYÚSCULAS)
su - alguien                         # ¿login real? (crea el home vía mkhomedir)
```

Si el equipo **no** está unido y hay dominio definido, el rol ejecuta además
`realm discover` (informativo, no falla el play): detecta el problema más
habitual, que el **DNS del aula no resuelva el dominio** (ver sección 5).

---

## 3. Unión de UN equipo: `utilesAD/3-UneAlDominio.sh`

En el equipo a unir (como root, asume que la cuenta `svc-union-linux` ya
existe — sección 4, paso 1):

```bash
sudo /opt/IAC-IESMHP/Ubuntu/ansible/roles/preparaAD/utilesAD/3-UneAlDominio.sh
```

El script: (1) lanza el rol preparaAD (prerequisitos); (2) si ya está unido,
termina sin tocar nada; (3) si no, comprueba el DNS (`realm discover`),
**pregunta la contraseña de `svc-union-linux`** y une con `realm join` a la
OU delegada; (4) verifica y relanza el rol para desplegar el snippet SSSD.

Si dejas la contraseña **en blanco** (p. ej. la cuenta delegada aún no
existe), el script pregunta **otro usuario del dominio** con permisos de
unión (un administrador, por ejemplo) y su contraseña, e intenta la unión
con él. La cuenta de equipo se crea igualmente en la OU `ComputersLinux`,
que debe existir.

<details><summary>Equivalente a mano (para entender qué hace)</summary>

```bash
realm discover iesmhp.local                    # ¿se ve el dominio por DNS?
sudo realm join --user=svc-union-linux \
  --computer-ou='OU=ComputersLinux,DC=iesmhp,DC=local' \
  iesmhp.local                                 # pide la contraseña
realm list                                     # verificación
# y reaplicar el rol para el snippet SSSD del IES:
cd /opt/IAC-IESMHP/Ubuntu/ansible
ansible-playbook -i localhost, --connection=local roles.yaml --tags preparaad
```
</details>

### Sacar UN equipo del dominio: `utilesAD/4-SacaDelDominio.sh`

El inverso de la unión. En el equipo a sacar (como root):

```bash
sudo /opt/IAC-IESMHP/Ubuntu/ansible/roles/preparaAD/utilesAD/4-SacaDelDominio.sh
```

El script: (1) comprueba si está unido (si no, termina sin tocar nada); (2)
pide **confirmación**; (3) pregunta la contraseña de `svc-union-linux` (en
blanco = otro usuario del dominio con permisos de borrado) y ejecuta
`realm leave -U`, que **borra la cuenta de equipo de la OU en AD** y deshace la
configuración local (sssd.conf, keytab); (4) verifica y elimina el snippet SSSD
huérfano. Los prerequisitos (krb5.conf, split-DNS, nsswitch) se dejan intactos
para facilitar una reunión posterior.

> El borrado de la cuenta en AD lo permite la delegación `DeleteChild` que
> `1-CreaUsuarioUnionAD.ps1` concede a `svc-union-linux` **solo en la OU
> `ComputersLinux`**. A mano, `realm leave` (sin `-U`) deshace solo la config
> local y deja la cuenta en el dominio.

---

## 4. Unión automatizada (recomendada): cuenta delegada + vault + pase de aula

La cuestión clave es **cómo manejar el usuario del dominio con permisos de
unión** sin que su contraseña acabe en claro en el repo o en la ISO.

Los pasos 1 y 2 están **scriptados en [`utilesAD/`](utilesAD/)**.

### Paso 1 — En un controlador de dominio: `1-CreaUsuarioUnionAD.ps1`

```powershell
.\1-CreaUsuarioUnionAD.ps1     # solo pregunta la contraseña a establecer
```

Idempotente; con permisos de administrador del dominio: crea (si faltan) la
OU `ComputersLinux` y la cuenta `svc-union-linux` **sin privilegios
de administrador**, establece/resetea su contraseña y le delega sobre esa OU
los permisos **mínimos** para **unir y sacar** equipos (crear y **borrar**
objetos equipo + reset password/escrituras validadas sobre los equipos de la
OU). Tanto el alta como la baja quedan **acotadas a esa OU**: si la contraseña
se filtrara, el daño se limita a dar de alta/baja equipos en `ComputersLinux`.
Auditoría: `dsacls "OU=ComputersLinux,DC=iesmhp,DC=local"`.

### Paso 2 — En el equipo del profesor: `2-CreaVault.sh`

```bash
/opt/IAC-IESMHP/Ubuntu/ansible/roles/preparaAD/utilesAD/2-CreaVault.sh
```

Pide la contraseña de `svc-union-linux` (la del paso 1) y luego la contraseña
**del vault** (la pide `ansible-vault`; es la que protege el fichero y la que
se teclea en cada pase con `--ask-vault-pass` — no confundir ambas). Genera
`Ubuntu/ansible/vault/preparaAD-vault.yml`, cifrado AES256 y **committeable**.

> ⚠️ El vault va en `vault/`, **NO en `group_vars/`**: ahí Ansible lo
> auto-cargaría en TODOS los pases y cualquier ejecución sin
> `--ask-vault-pass` (incluido el primer arranque desatendido) fallaría.

### Paso 3 — Pase de aula (desde el equipo del profesor)

```bash
cd /opt/IAC-IESMHP/Ubuntu/ansible
ansible-playbook -i equiposIABD.ini roles.yaml --tags preparaad \
  -e preparaad_unir=true -e @vault/preparaAD-vault.yml --ask-vault-pass
```

El rol une solo los equipos que no lo estén (idempotente) a la OU delegada,
despliega el snippet SSSD y falla ruidosamente si alguno no queda unido.

El rol une solo los equipos que no lo estén ya (idempotente), despliega el
snippet SSSD y **falla ruidosamente** si algún equipo no queda unido.

### ¿Por qué NO unir en el primer arranque (`3-SetupPrimerInicio`)?

- La contraseña del vault no está disponible en un equipo recién instalado
  (habría que embeberla en claro en la ISO o el repo).
- La unión debe hacerse con el **hostname definitivo**; si `NombreIP.sh`
  fallara, se crearía una cuenta de equipo basura en el dominio.
- Un join fallido (DNS del aula, DC caído) **no debe arriesgar el
  despliegue**. El primer arranque deja solo los prerequisitos: rápido, sin
  credenciales y sin necesitar ver al DC.

### Alternativa más segura (plan B): one-time passwords

Si no se quiere ninguna credencial circulando: pre-crear las cuentas de
equipo desde un equipo de confianza con
`adcli preset-computer --domain DOMINIO --one-time-password XXX IABD-01 …`
y unir cada equipo con `realm join --one-time-password=XXX DOMINIO`. La OTP
solo vale para ese alta y ninguna cuenta de usuario viaja a los clientes.
Más segura pero más laboriosa (una OTP por hostname).

---

## 5. Requisito externo: DNS (el rol lo auto-arregla)

La unión y el `realm discover` exigen que el equipo **resuelva el dominio**
(registros SRV `_ldap._tcp.dc._msdcs.iesmhp.local`). Como el DNS que reparte
el DHCP del aula normalmente NO es el del dominio, el rol lo detecta y lo
arregla solo: despliega un **split-DNS** con systemd-resolved
(`/etc/systemd/resolved.conf.d/50-iac-ad.conf`) que enruta **solo** las
consultas de `iesmhp.local` a los DNS del dominio
(`preparaad_dominio_dnss: 10.0.1.48,10.0.1.54` en
[`entornoAD.yml`](entornoAD.yml)); el resto del tráfico DNS sigue saliendo por
el DNS del aula. No toca NetworkManager ni el DHCP.

Además, como el dominio termina en **`.local`** (el TLD reservado para
mDNS/Avahi), el rol ajusta también la línea `hosts:` de
**`/etc/nsswitch.conf`**: en Ubuntu lleva `mdns4_minimal [NOTFOUND=return]`
**antes** de `dns`, lo que hace que `ping`, `kinit` o `adcli` corten en el
mDNS y nunca lleguen a preguntar a systemd-resolved (síntoma típico: el
resumen del rol dice "visible por DNS: SÍ" pero `ping iesmhp.local` no
resuelve). El rol antepone `dns` al mDNS
(`hosts: files dns mdns4_minimal [NOTFOUND=return]`); los nombres mDNS
reales (impresoras…) siguen funcionando como fallback. Desactivable con
`preparaad_arregla_nsswitch: false`. Comprobar cada ruta por separado:

```bash
resolvectl query iesmhp.local   # ruta systemd-resolved (la de realm/SSSD)
getent hosts iesmhp.local       # ruta nsswitch (la de ping/kinit/adcli)
```

Si aun así el resumen del rol dice *"NO — ni con split-DNS"*, el problema ya
no es de DNS sino de **conectividad** hacia esas IPs (routing/firewall del
aula). Diagnóstico:

```bash
resolvectl status                                 # ¿qué DNS usa el equipo? ¿hay ruta ~iesmhp.local?
dig -t SRV _ldap._tcp.iesmhp.local                # ¿resuelven los SRV del dominio?
dig -t SRV _ldap._tcp.iesmhp.local @10.0.1.48     # ¿se llega al DC directamente?
```

---

## 6. Qué falta para activarlo de verdad

El dominio (`iesmhp.local`) y la OU (`ComputersLinux`) ya están
fijados en [`entornoAD.yml`](entornoAD.yml) (**único punto de cambio**: lo leen
el rol y todos los scripts de `utilesAD/`). Queda:

1. **Crear la cuenta delegada**: ejecutar
   [`utilesAD/1-CreaUsuarioUnionAD.ps1`](utilesAD/1-CreaUsuarioUnionAD.ps1)
   en un controlador de dominio (sección 4, paso 1).
2. **Crear el vault**: [`utilesAD/2-CreaVault.sh`](utilesAD/2-CreaVault.sh)
   en el equipo del profesor (sección 4, paso 2) — solo para pases de aula;
   para un equipo suelto basta `3-UneAlDominio.sh`, que pregunta la
   contraseña.
3. **Verificar la conectividad de las aulas con los DC** (`10.0.1.48` /
   `10.0.1.54`): la resolución DNS la auto-arregla el rol (sección 5), pero
   tiene que haber ruta hasta esas IPs.
4. **`preparaad_ntp` apuntando al DC** (NO opcional): sin NTP alcanzable el
   reloj no sincroniza y la unión hace un *"join a medias"* (sección 7). En
   producción ha de apuntar a un DC que reparta NTP y sea **alcanzable desde el
   aula** (el pool de internet de chrony NO llega desde la red del centro).

Tras la primera unión real, revisar `ad_gpo_access_control` (el rol lo deja
en `permissive` para evitar el bloqueo típico de logins cuando las GPO no
contemplan Linux; endurecer a `enforcing` cuando estén revisadas).

---

## 7. Problema típico: reloj desfasado → *"join a medias"*

**Síntoma**: `realm join` (o `3-UneAlDominio.sh`) **falla** con un mensaje sobre
*sincronización de reloj* / *clock skew*, pero al mirar `realm list` el equipo
**aparece unido**… y, sin embargo, **no se puede autenticar** ningún usuario del
dominio.

**Causa**: Kerberos exige < 5 min de desfase con el DC. `realm join` se hace en
dos fases: (1) por LDAP crea la cuenta de equipo en la OU — esto va **aunque el
reloj esté mal**; (2) se autentica como esa cuenta de máquina (Kerberos) para
generar el keytab — esto **falla por el desfase**. Resultado: cuenta de equipo
creada (parece unido) pero unión inservible, y un **objeto huérfano** en la OU.

**Por qué pasaba**: en aulas sin salida a internet el pool NTP por defecto
(chrony) **no se alcanza**, así que el reloj nunca sincronizaba. Había que
apuntar el NTP al **DC** (que sí reparte hora y es alcanzable). El rol ya lo
hace y **espera** a la sincronización, pero conviene saber diagnosticarlo.

**Comprobar el reloj**:

```bash
timedatectl status            # "System clock synchronized: yes" ← lo que hace falta
chronyc tracking              # (Mint/Debian) offset actual respecto al NTP
chronyc sources -v            # ¿se alcanza el NTP del dominio? (línea con '*')
systemctl status systemd-timesyncd   # (Ubuntu) alternativa a chrony
```

**Forzar la sincronización a mano** (si hiciera falta):

```bash
# chrony (Mint/Debian):
sudo chronyc makestep 0.1 3 && sudo chronyc waitsync 30 0.05 0 1
# systemd-timesyncd (Ubuntu):
sudo systemctl restart systemd-timesyncd && sleep 5 && timedatectl show -p NTPSynchronized --value
```

**Limpiar el objeto huérfano** en AD antes de reintentar (si la unión quedó a
medias):

```bash
sudo adcli delete-computer --domain=iesmhp.local --login-user=svc-union-linux NOMBREEQUIPO
# y reintentar:
sudo /opt/IAC-IESMHP/Ubuntu/ansible/roles/preparaAD/utilesAD/3-UneAlDominio.sh
```

`3-UneAlDominio.sh` incorpora una **guarda de reloj**: si tras forzar el ajuste
sigue sin sincronizar, **aborta antes de pedir la contraseña** (no crea el
objeto huérfano) e indica qué revisar (NTP/conectividad al DC).
