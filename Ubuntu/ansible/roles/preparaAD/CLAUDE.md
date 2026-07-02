# Rol `preparaAD`

## Qué hace
Deja el equipo **preconfigurado para unirse a un dominio Active Directory**
(Ubuntu Desktop 26.04) y **comprueba si ya está unido**. Por defecto **NO une
al dominio** (`preparaad_unir: false`): la unión exige credenciales delegadas
y se lanza bajo demanda (ver "Cómo unir el equipo").

Cumple el TODO `predominio` de `roles.yaml`. Sigue la doc oficial de Ubuntu:
<https://ubuntu.com/server/docs/how-to/sssd/with-active-directory/>.

> Guía operativa para humanos (qué hace el rol, cómo comprobar la unión y
> procedimiento recomendado de unión): [`LeemeComoUnirAlDominio.md`](LeemeComoUnirAlDominio.md).

## Prerequisitos que implanta (tasks/main.yml)
1. **Stack de unión** (`preparaad_paquetes`): `realmd` (orquestador
   discover/join), `sssd-ad` + `sssd-tools` + `libnss-sss` + `libpam-sss`
   (identidad/autenticación contra AD), `adcli` (herramienta de unión),
   `krb5-user` (kinit/klist), `packagekit` (lo invoca realmd; preinstalado =
   unión más rápida y sin red a archive), `bind9-dnsutils` (dig/nsupdate).
2. **`pam_mkhomedir`** vía `pam-auth-update --enable mkhomedir`: crea el home
   en el primer login de un usuario del dominio (en Ubuntu no viene activo, a
   diferencia de RHEL). Idempotente: solo corre si `pam_mkhomedir.so` no está
   ya en `/etc/pam.d/common-session`.
2b. **SSH `UsePAM yes`** (drop-in `/etc/ssh/sshd_config.d/60-iac-ad.conf` con
   `UsePAM yes` + `PasswordAuthentication yes` + `KbdInteractiveAuthentication
   yes`, 0644): sin esto **los usuarios del dominio no pueden entrar por SSH**
   aunque GDM/RDP sí funcionen (ver Estado/Notas). Se aplica **siempre** (no solo
   con el equipo unido; `UsePAM yes` es el valor seguro por defecto). El **mismo
   fichero/contenido** lo escribe también `3-SetupPrimerInicio.sh` en el primer
   arranque (mantener en sync entre script y rol). **Además garantiza la
   directiva `Include /etc/ssh/sshd_config.d/*.conf`** en `sshd_config`
   (`lineinfile`, al principio del fichero): sin ella sshd **ignora** el drop-in
   y todo lo anterior es inútil (síntoma 2026-06-17, ver Estado/Notas). Reinicia
   `ssh` solo si el drop-in **o** el Include cambiaron (las conexiones SSH activas
   sobreviven al restart).
3. **Reloj**: Kerberos exige desfase < 5 min con el DC. Si `preparaad_ntp` se
   define (normalmente el propio DC), el rol **detecta el cliente NTP** del
   equipo, lo apunta al DC y **espera a que sincronice ANTES de continuar** (sin
   la espera, la unión posterior pillaba el reloj aún desfasado → *"join a
   medias"*, ver Estado/Notas). Prioridad a chrony:
   - **chrony** (Mint/Debian; no traen timesyncd): añade `server <ntp> iburst
     prefer trust` **+ `maxdistance 16.0`** a `chrony.conf` (bloque marcado,
     idempotente), reinicia el servicio, **arma el salto** (`chronyc makestep
     0.1 3` — step, no slew, en las próximas muestras) y **espera** (`chronyc
     waitsync 30 0.05 0 1`, máx ~30 s). OJO: un `chronyc makestep` lanzado al
     instante tras el restart es un **no-op** (chrony aún no tiene muestras del
     NTP); de ahí el armar+esperar. **El `maxdistance` es imprescindible con DC
     Windows**: w32time anuncia una *distancia de raíz* alta (~10 s) y el
     `maxdistance` por defecto de chrony (3 s) marca la fuente `^?`
     (inutilizable) → chrony **nunca la selecciona** y `makestep`/`waitsync` se
     quedan sin fuente (síntoma: `chronyc sources -v` con `^? <DC> ... 377 ...
     +/- 10s` pese a `Reach 377`). Relajarlo a 16 s acepta el DC; para Kerberos
     basta < 5 min. El arreglo de fondo es sincronizar el w32time del DC con un
     NTP fiable (si el DC va muy desfasado, su reloj CMOS deriva y la dispersión
     crece).
   - **systemd-timesyncd** (Ubuntu Desktop por defecto): escribe
     `/etc/systemd/timesyncd.conf.d/50-iac-ad.conf`, lo reinicia y **sondea**
     `timedatectl … NTPSynchronized` hasta `yes` o ~30 s.
   - Si no hay ninguno de los dos, avisa (`debug`) y no toca el reloj.
   El resumen final muestra SÍ/NO con pista accionable (NTP/conectividad al DC)
   leyendo `timedatectl … NTPSynchronized`.
4. **Hostname**: aviso si supera 15 caracteres (límite NetBIOS de la cuenta
   de equipo en AD). Los `IABD-NN`/`SMRD-NN` van sobrados.
5. **`/etc/krb5.conf`** (solo si se conoce el dominio): realm por defecto en
   mayúsculas, KDC por DNS (SRV), `rdns = false`.
6. **Comprobación de unión y DNS con auto-arreglo**: `realm list --name-only`
   (fuente de verdad de realmd/SSSD) y, si hay dominio, `realm discover`
   comprueba que se resuelve por DNS (**no falla** el play). Si **NO** se
   resuelve y hay `preparaad_dominio_dnss`, fuerza **split-DNS** con un
   drop-in de systemd-resolved (`/etc/systemd/resolved.conf.d/50-iac-ad.conf`:
   `DNS=<DCs>` + `Domains=~iesmhp.local`) — solo las consultas del dominio
   van a los DC, el resto sigue por el DNS del aula; no se toca
   NetworkManager ni el DHCP —, reinicia systemd-resolved y reintenta el
   discover. Además (6b), si el dominio termina en **`.local`** antepone
   `dns` a `mdns4_minimal` en la línea `hosts:` de `/etc/nsswitch.conf`:
   `.local` es el TLD de mDNS y el `[NOTFOUND=return]` de Ubuntu corta la
   resolución de getaddrinfo (ping, **kinit, adcli**) antes de llegar a
   systemd-resolved — `realm discover`/SSSD no lo sufren (resolver propio),
   por lo que sin este ajuste el resumen diría "visible por DNS: SÍ" pero la
   unión podría fallar. Los nombres mDNS legítimos siguen funcionando como
   fallback. Desactivable con `preparaad_arregla_nsswitch: false`.
7. **Unión opcional** (`preparaad_unir=true` + credenciales): `realm join
   --unattended` con la contraseña por stdin (`no_log`), `--computer-ou` si se
   define, y **post-condición ruidosa**: si `realm list` sigue vacío, el play
   falla.
8. **Snippet `/etc/sssd/conf.d/10-iac-ad.conf`** (solo con el equipo **ya
   unido**): `use_fully_qualified_names=False` (login `pepe`, no
   `pepe@dominio`), `fallback_homedir=/home/%u`, `default_shell=/bin/bash`,
   `cache_credentials=True` (login offline) y
   `ad_gpo_access_control=permissive` (el default `enforcing` de SSSD bloquea
   TODOS los logins si las GPO "Allow log on locally" no contemplan Linux).
   Permisos 0600 obligatorios. Reinicia sssd solo si el snippet cambió.
8b. **`pam_sss` / nss `sss` — red de seguridad para RE-UNIONES** (solo con el
   equipo **ya unido**): repone `pam_sss` en `/etc/pam.d/common-*`
   (`pam-auth-update --enable sss`, solo si falta) y `sss` en `passwd`/`group`
   de `/etc/nsswitch.conf` (`lineinfile` con backref idempotente). Es el
   **inverso del paso 6 de `4-SacaDelDominio.sh`**: en una instalación nueva el
   postinst de `libpam-sss` enciende el perfil `sss` al instalar el paquete y
   realmd lo repone al unir, pero al **re-unir** los paquetes ya están
   instalados (postinst no se re-ejecuta) y `realm join` no toca pam-auth-update
   → sin esto el equipo queda **unido pero sin poder hacer login con ningún
   usuario del dominio** (greeter/RDP llegan a la ventana de usuarios; la fase
   auth/account de PAM no consulta a SSSD). En instalación nueva es no-op.
9. **Resumen** (`debug`): unido o no, dominio configurado, dominio visible
   por DNS, reloj sincronizado. Sale en el log de `3-SetupPrimerInicio.sh`.

### ¿Por qué el snippet SOLO tras la unión?
`sssd.service` en Debian/Ubuntu lleva `ConditionPathExists=/etc/sssd/sssd.conf`
y `ConditionDirectoryNotEmpty=/etc/sssd/conf.d/`. Antes de unir no existe
`sssd.conf` (lo escribe realmd al unir) → la unidad se **salta** limpiamente,
sin unidad fallida. Un snippet pre-unión llenaría `conf.d/` → sssd arrancaría
sin dominios → **unidad fallida en cada boot** (saltaría la sección 8 de
`4-Comprobaciones.sh`). Por eso el equipo queda "preparado" con `conf.d/`
vacío y el snippet se aplica en el mismo pase que une (o en re-pases sobre
equipos ya unidos).

## Variables

### `entornoAD.yml` — ÚNICO PUNTO DE CAMBIO del entorno (dominio/DNS/OU)
Fichero en la **raíz del rol** (`roles/preparaAD/entornoAD.yml`). Es la **única
fuente de verdad** del dominio al que se une el equipo, compartida por:
- el **rol** (`tasks/main.yml` lo carga con `include_vars` como tarea 0),
- los **scripts** `utilesAD/2-CreaVault.sh` y `utilesAD/3-UneAlDominio.sh` (lo
  parsean vía `utilesAD/entornoAD.sh`),
- `utilesAD/1-CreaUsuarioUnionAD.ps1` (lee de él la OU y la cuenta; el dominio
  lo autodetecta con `Get-ADDomain`).

Conmutar **producción ⇄ pruebas** = editar SOLO este fichero.

| Variable (en `entornoAD.yml`) | Valor | Para qué |
|----------|-------------|----------|
| `preparaad_dominio` | prod `iesmhp.local` / test `mhpies.local` | Dominio AD (DNS, minúsculas). Vacío = solo prerequisitos genéricos |
| `preparaad_dominio_dnss` | prod `10.0.1.48,10.0.1.54` / test `10.0.72.118` | IPs (separadas por comas) que resuelven el dominio (DNS de los DC). Solo si el DNS del equipo NO resuelve → split-DNS vía systemd-resolved. Vacío = sin auto-arreglo |
| `preparaad_nombre_ou` | `ComputersLinux` | Nombre (hoja) de la OU de las cuentas de equipo. La crea y delega `utilesAD/1-CreaUsuarioUnionAD.ps1` con este nombre |
| `preparaad_ou` | *(derivada)* `OU={{ nombre_ou }},DC=...` | OU completa (DN), **calculada** a partir de `preparaad_dominio` + `preparaad_nombre_ou`. No editar: cambia sola con el dominio |
| `preparaad_usuario_union` | `svc-union-linux` | Cuenta delegada de unión (la crea `utilesAD/1-CreaUsuarioUnionAD.ps1`) |
| `preparaad_ntp` | prod `10.0.1.48` / test `10.0.72.118` | NTP del dominio (normalmente el DC), o varios separados por comas. El rol detecta el cliente NTP (chrony en Mint/Debian, systemd-timesyncd en Ubuntu) y lo apunta aquí + `chronyc makestep`. Vacío = no se toca el reloj |
| `preparaad_membership_software` | prod `""` (adcli) / test `"samba"` | Motor de unión de `realm join`. **Vacío = adcli** (default de realmd, correcto contra Windows AD: fija la contraseña de máquina por kpasswd). **`"samba"`** = realmd delega en `net ads join` (paquete `samba-common-bin`), que fija la contraseña por netlogon en vez de kpasswd; **necesario contra DC Samba**, donde adcli crea la cuenta por LDAP pero el set-password Kerberos falla con `Message stream modified`. Con `samba` se fuerza `--client-software=sssd` (SSSD sigue siendo el cliente de identidad). Ver `Ubuntu/RegistroDeCambios/20260615-Cambios.md` |

Todas se pueden pisar puntualmente con `-e` (extra-vars > include_vars).

### `defaults/main.yml` — comportamiento del rol (no del entorno)
| Variable | Por defecto | Para qué |
|----------|-------------|----------|
| `preparaad_arregla_nsswitch` | `true` | En dominios `.local`: anteponer `dns` a `mdns4_minimal` en `/etc/nsswitch.conf` (sin esto, ping/kinit/adcli no resuelven `*.local` aunque el split-DNS funcione) |
| `preparaad_paquetes` | lista | Stack a instalar |
| `preparaad_unir` | `false` | Intentar la unión en este pase |
| `preparaad_password_union` | `""` | Contraseña de la cuenta de unión — **solo vía vault (`utilesAD/2-CreaVault.sh`) o `-e`** |
| `preparaad_fqn` | `false` | `use_fully_qualified_names` |
| `preparaad_fallback_homedir` | `/home/%u` | Home de usuarios del dominio |
| `preparaad_gpo` | `permissive` | `ad_gpo_access_control` (endurecer a `enforcing` con las GPO revisadas) |

## Scripts de apoyo (`utilesAD/`)
| Script | Dónde se ejecuta | Qué hace |
|--------|------------------|----------|
| `1-CreaUsuarioUnionAD.ps1` | Controlador de dominio (admin del dominio) | OU `ComputersLinux` (si falta) + cuenta `svc-union-linux` (si falta; resetea contraseña si existe) + delegación mínima sobre la OU para **unir Y sacar** equipos (crear equipos, **borrar equipos**, reset password, validated writes dNSHostName/SPN, property set Account Restrictions). El borrado (`DeleteChild` de la clase equipo) queda **acotado a esta OU**. Idempotente: comprueba ACE a ACE. Lee OU/usuario de `entornoAD.yml`; el dominio lo autodetecta con `Get-ADDomain`. Solo pregunta la contraseña. **Sin tildes a propósito** (PS 5.1 lee UTF-8 sin BOM como ANSI) |
| `2-CreaVault.sh` | Equipo del profesor | Crea `Ubuntu/ansible/vault/preparaAD-vault.yml` (AES256, committeable) con las credenciales de unión. Rechaza contraseñas con comilla simple (limitación del rol) |
| `3-UneAlDominio.sh` | El equipo a unir (root) | Rol preparaAD (prerequisitos) → si no unido: `realm discover` + **guarda de reloj** (verifica `NTPSynchronized`; si no, fuerza `chronyc makestep`+`waitsync` / reinicia timesyncd y, si sigue desfasado, **aborta antes de pedir credenciales** para no dejar un objeto de equipo huérfano en AD) + pregunta la contraseña de `svc-union-linux` (**en blanco** = pide OTRO usuario del dominio con permisos de unión y su contraseña) + `realm join` a la OU → verifica → re-pase del rol (despliega el snippet SSSD) |
| `4-SacaDelDominio.sh` | El equipo a sacar (root) | **Inverso de 3**. Comprueba si está unido (si no, termina) → pide confirmación → pregunta la contraseña de `svc-union-linux` (**en blanco** = OTRO usuario con permisos de borrado) + `realm leave -U` (borra la cuenta de equipo en AD y deshace la config local) → verifica → elimina el snippet SSSD huérfano → **(paso 5b) vacía la caché de SSSD** (`/var/lib/sss/{db,mc}`, que `realm leave` no borra) para que una re-unión no arranque con datos del enrolamiento viejo → **(paso 6) revierte `pam_sss` y el módulo `sss` de nsswitch** que realmd metió al unir y NO quita al salir (si no, `pam_sss` apunta a un sssd ya inexistente → rompe el greeter GDM / handover RDP = pantalla en negro; ver Notas). Deja krb5/split-DNS/reorden-mDNS de nsswitch intactos (facilitan reunir). **El rol repone `pam_sss`/`sss` al re-unir (paso 8b)**. **NO borra el rastro de los usuarios del dominio** (homes, subuid, lingering…): eso es `5-LimpiaUsuariosDominio.sh` |
| `5-LimpiaUsuariosDominio.sh` | El equipo ya fuera del dominio (root) | **DESTRUCTIVO**. Borra TODO el rastro local de los usuarios del dominio. Identifica como "de dominio" toda cuenta cuyo NOMBRE ya **no resuelve** en `/etc/passwd` (tras `4-SacaDelDominio.sh`) pero dejó rastro: home en `/home/<n>` (uid≥1000), línea en `/etc/subuid`+`/etc/subgid`, `lingering`, perfil de `AccountsService`. Los usuarios **locales** (en `/etc/passwd`: `usuario`, `adduser`…) se **preservan siempre**. Por cada uno: `loginctl terminate-user` + mata procesos (para el daemon rootless y desmonta overlays) y borra home (`rm -rf --one-file-system`), subuid/subgid, lingering, AccountsService, correo/cron, tickets Kerberos y `/run/user/<uid>`. Pide confirmación (`BORRAR`); `--dry-run` solo lista; `--si` desatendido. Avisa si el equipo sigue unido (entonces no detecta nada). Nota: en CEIABD antiguos con dataset ZFS por usuario, `rm` no destruye el dataset (ver cabecera del script) |

## Cómo unir el equipo (cuando se decida)

### Manual (un equipo, para probar)
```bash
realm discover iesmhp.local                    # ¿se ve el dominio? (DNS)
realm join --user=svc-union-linux \
  --computer-ou='OU=ComputersLinux,DC=iesmhp,DC=local' \
  iesmhp.local                                 # pide la contraseña
realm list                                     # verificación
getent passwd alguien@iesmhp.local && su - alguien   # prueba de login
```
O directamente `sudo utilesAD/3-UneAlDominio.sh`, que hace todo esto y además
relanza el rol al final.

### Automatizado (recomendado): cuenta delegada + ansible-vault + pase de aula

Los tres pasos están **scriptados en [`utilesAD/`](utilesAD/)** (ver tabla más
abajo):

1. **En un controlador de dominio** (administrador del dominio, una vez):
   `utilesAD/1-CreaUsuarioUnionAD.ps1`. Crea (si faltan) la OU
   `ComputersLinux` y la cuenta `svc-union-linux` sin privilegios,
   establece/resetea su contraseña (única pregunta del script) y delega sobre
   la OU los permisos **mínimos** de unión. Si la cuenta se filtrara, el daño
   se limita a dar de alta equipos en esa OU.
2. **En el equipo del profesor**: `utilesAD/2-CreaVault.sh` crea
   `Ubuntu/ansible/vault/preparaAD-vault.yml` cifrado (AES256, committeable)
   con `preparaad_usuario_union`/`preparaad_password_union`. Va en `vault/`,
   **NO en `group_vars/`**: ahí Ansible lo auto-cargaría y TODOS los pases
   (incluido el primer arranque desatendido) exigirían `--ask-vault-pass`.
3. **Pase de aula** (desde el equipo del profesor, NO en el primer arranque):
   ```bash
   ansible-playbook -i equiposIABD.ini roles.yaml --tags preparaad \
     -e preparaad_unir=true -e @vault/preparaAD-vault.yml --ask-vault-pass
   ```

Para un **equipo suelto** sin vault: `sudo utilesAD/3-UneAlDominio.sh` —
lanza el rol (prerequisitos), comprueba si ya está unido, pregunta la
contraseña de `svc-union-linux`, une con `realm join` a la OU delegada y
relanza el rol para desplegar el snippet SSSD.

### ¿Por qué NO unir en el primer arranque (`3-SetupPrimerInicio`)?
- La contraseña del vault no está disponible en un equipo recién instalado
  (habría que embeberla en la ISO/repo = en claro).
- La unión debe hacerse con el **hostname definitivo**; aunque `NombreIP.sh`
  corre antes que Ansible, si fallara la resolución MAC→nombre se crearía una
  cuenta de equipo basura (`ubuntu`) en el dominio.
- Un join fallido (DNS de aula, DC caído) no debe arriesgar el primer
  arranque. El rol en el primer arranque solo instala prerequisitos (rápido,
  sin credenciales, sin red al DC).

### Alternativa más segura (si no se quiere ninguna credencial en juego)
Pre-crear las cuentas de equipo con contraseña de un solo uso desde un equipo
de confianza: `adcli preset-computer --domain DOMINIO --one-time-password XXX
IABD-01 IABD-02 …` y unir cada equipo con
`realm join --one-time-password=XXX DOMINIO` (la OTP solo vale para ese alta;
ninguna cuenta de usuario viaja a los clientes). Más segura pero más
laboriosa: hay que generar/distribuir una OTP por hostname. Plan B si la
cuenta delegada no convence.

## Requisito externo: DNS (con auto-arreglo)
La unión y el discover exigen que el equipo **resuelva el dominio** (registros
SRV `_ldap._tcp.dc._msdcs.iesmhp.local`). Si el DNS que reparte el DHCP del
aula no lo resuelve, el rol lo arregla solo: split-DNS hacia los DC de
`preparaad_dominio_dnss` (drop-in `/etc/systemd/resolved.conf.d/50-iac-ad.conf`,
solo afecta a las consultas del dominio). Si el resumen sigue diciendo
"NO — ni con split-DNS", el problema es de **conectividad** con esas IPs
(routing/firewall del aula hacia `10.0.1.48`/`10.0.1.54`), no de DNS.
Diagnóstico: `resolvectl status`, `dig -t SRV _ldap._tcp.iesmhp.local @10.0.1.48`.

El rol arregla **las dos rutas de resolución** del equipo: la de
systemd-resolved (split-DNS — la que usan `realm`/SSSD) y la de
nsswitch/getaddrinfo (reorden del mDNS — la que usan `ping`/`kinit`/`adcli`).
Verificar cada una por separado: `resolvectl query iesmhp.local` (resolved) y
`getent hosts iesmhp.local` (nsswitch).

## Estado / Notas
- **Activo** en `roles.yaml` (modo "solo prerequisitos": sin `preparaad_dominio`
  ni `preparaad_unir`, instala el stack y comprueba; no toca nada del dominio).
- **Idempotente**: paquetes `state: present`; mkhomedir solo si falta; krb5.conf
  y snippet por plantilla (mismo contenido = sin cambios); el join solo corre si
  `realm list` está vacío; sssd solo se reinicia si el snippet cambió.
- **Primer arranque**: solo usa `systemd` con `state: restarted` (los cuelgues
  documentados 2026-05-17 son de `enabled:`/`daemon_reload:` — no se usan).
- **Limitación**: `preparaad_password_union` no debe contener comillas simples
  (se interpola en una orden shell; la tarea va con `no_log`).
- **Reloj = requisito DURO, no opcional**: si `preparaad_ntp` está vacío o el
  reloj no sincroniza, `realm join` hace un **"join a medias"**: crea la cuenta
  de equipo por LDAP pero falla la finalización Kerberos (keytab/auth de
  máquina) → el equipo **aparece unido** pero la **autenticación falla** y queda
  un objeto huérfano en la OU. Síntoma del mensaje "posible fallo de
  sincronización de reloj". Por eso el rol ahora **espera** a la sincronización
  (chrony `waitsync` / sondeo de timesyncd) y `3-UneAlDominio.sh` aborta si el
  reloj no está OK. Limpiar un objeto huérfano: `adcli delete-computer
  --domain=DOMINIO --login-user=svc-union-linux HOSTNAME`.
- **VMware — sincronizar la hora con el host (recomendado)**: en una máquina
  virtual VMware, activar **Settings → Options → VMware Tools → "Synchronize
  guest time with host"**. En las aulas el **UDP 123 (NTP)** suele estar filtrado
  y en VMware con host Windows el RTC se reinterpreta en cada arranque, así que el
  reloj del guest deriva entre reinicios y Kerberos puede fallar por desfase >5
  min con el DC. Con esta opción el host mantiene la hora del guest correcta sin
  depender del NTP del aula (complementa al rol `horaHTTP` y al NTP del dominio,
  no los sustituye). Requiere `open-vm-tools` instalado (lo pone el rol `vmware`
  / `3-SetupPrimerInicio.sh` en VMware).
- **DC Samba — `Message stream modified` al fijar la contraseña de máquina**
  (visto 2026-06-15 en pruebas `mhpies.local` / `dcfake`): con el motor por
  defecto (adcli), `realm join`/`adcli join` autentica OK, crea la cuenta de
  equipo por LDAP en la OU (¡por eso **aparece en AD aunque el join "falle"**!),
  pero el `set computer password` por Kerberos (kpasswd) falla con
  `Couldn't set password for computer account: HOST$: Message stream modified`.
  Descartado: red/puerto 464, reloj, OU/delegación, host del kpasswd (mismo DC) y
  enctype (RC4/AES-SHA1/SHA2). Es un quirk del kpasswd de Samba. **Solución**:
  `preparaad_membership_software: "samba"` en `entornoAD.yml` → realmd une por
  `net ads join` (no usa kpasswd) manteniendo SSSD. Limpiar el objeto huérfano
  antes de reintentar: `adcli delete-computer --domain=DOMINIO
  --login-user=svc-union-linux HOSTNAME`. Producción Windows AD no lo sufre
  (adcli funciona) → ahí se deja `""`.
- **Tras salir del dominio — pantalla en negro por RDP (pam_sss huérfano)**
  (visto 2026-06-15 en `IABD-14`, PC físico): `realm leave` deshace `sssd.conf`
  pero **NO retira `pam_sss` de `/etc/pam.d/common-*` ni el módulo `sss` de
  `/etc/nsswitch.conf`** (los puso realmd al unir). Al reiniciar, sssd no
  arranca (sin config) y `pam_sss` queda apuntando a un socket muerto →
  `pam_sss(...:account): Request to sssd failed. Connection refused` en **cada**
  arranque de sesión gráfica → el greeter de GDM y el *handover* de
  `gnome-remote-desktop` abortan la sesión → **RDP en negro** (`Aborting
  handover`). No es render/Wayland (`systemd-detect-virt`=none, sin 3D de por
  medio). **Solución**: `pam-auth-update --disable sss` + quitar `sss` de las
  bases passwd/group de nsswitch + reiniciar `gnome-remote-desktop`. Desde
  2026-06-15 lo hace **`4-SacaDelDominio.sh` (paso 6)** automáticamente.
- **Re-unión: equipo UNIDO pero sin poder hacer login con ningún usuario del
  dominio** (visto 2026-06-15, secuela del fix anterior): tras sacar el equipo
  con `4-SacaDelDominio.sh` (que **a propósito** quita `pam_sss`/nss `sss`) y
  **volver a unirlo** con `3-UneAlDominio.sh`, el join cuaja (`realm list` no
  vacío) pero **ningún usuario del dominio puede entrar**: el greeter/RDP llegan
  a la ventana de usuarios y ahí se quedan. **Causa raíz**: en la unión nueva
  esos `pam_sss`/`sss` los pone el **postinst de `libpam-sss`** (al instalar el
  paquete) y realmd; al re-unir, los paquetes **ya están instalados** (postinst
  no se re-ejecuta) y `realm join` **no toca pam-auth-update** → `pam_sss` se
  queda fuera del stack → la fase auth/account de PAM no consulta a SSSD. **No
  es** reloj, DNS ni la caché. **Solución**: el rol los **repone al re-unir**
  (paso 8b: `pam-auth-update --enable sss` + `sss` en nsswitch, solo si faltan;
  no-op en instalación nueva). `3-UneAlDominio.sh` lo aplica en su re-pase final
  del rol. Arreglo manual en un equipo ya roto (atajo: `3-UneAlDominio.sh`
  termina pronto si ya está unido, así que lanzar el rol directo):
  `sudo ansible-playbook -i localhost, --connection=local roles.yaml --tags
  preparaad` (o a mano `sudo pam-auth-update --enable sss` + reponer `sss` en
  `passwd`/`group` de `/etc/nsswitch.conf` + `sudo systemctl restart sssd
  gnome-remote-desktop`).
- **Usuario del dominio entra por GDM/RDP pero NO por SSH** (visto 2026-06-16 en
  `IABD-08`): `ssh victor@<ip>` rechaza la contraseña correcta. En el log de
  sshd: `error: Could not get shadow information for victor` + `Failed password`.
  `getent passwd victor` SÍ resuelve. **Causa raíz**: `sshd -T` muestra
  **`usepam no`**. El `/etc/ssh/sshd_config` de Ubuntu 26.04 viene sin línea
  `UsePAM`, así que cae al **default COMPILADO de OpenSSH, que es `no`** (Ubuntu
  lo solía fijar a `yes` en su sshd_config, pero el de 26.04 quedó reducido a
  `Include` + `#PasswordAuthentication`). Con `UsePAM no`, sshd valida la
  contraseña contra el `/etc/shadow` local; el usuario de dominio no tiene
  entrada en shadow (su contraseña está en AD, se comprueba vía PAM→`pam_sss`)
  → falla siempre. GDM/RDP funcionan porque **sí** pasan por PAM. **No es** el
  formato del usuario: con `use_fully_qualified_names=False` se entra como
  `victor` a secas (no `MHPIES\victor` ni `victor@dominio`). **Solución**: drop-in
  `/etc/ssh/sshd_config.d/60-iac-ad.conf` con `UsePAM yes` + `PasswordAuthentication
  yes` + `KbdInteractiveAuthentication yes` y `systemctl restart ssh`. Lo
  despliega el **rol (paso 2b)** y `3-SetupPrimerInicio.sh` en el primer arranque.
  Diagnóstico: `sshd -T | grep -i usepam` (debe ser `yes`); ojo: si falta la
  línea `Include /etc/ssh/sshd_config.d/*.conf` en `sshd_config`, el drop-in se
  ignora.
- **El drop-in NO bastaba en instalación desde squashfs — faltaba el `Include`**
  (visto 2026-06-17 en VM recién instalada y unida al dominio): pese a que el rol
  y `3-SetupPrimerInicio.sh` SÍ escribían `60-iac-ad.conf` con `UsePAM yes`,
  `ssh victor@<ip>` seguía rechazando la contraseña mientras `su victor` (PAM)
  funcionaba — prueba de que **sshd no usaba PAM** (`UsePAM no` efectivo). Causa:
  el `/etc/ssh/sshd_config` conservado de la instalación squashfs (`apt-get
  install ssh` con `--force-confold`) **no tenía** `Include
  /etc/ssh/sshd_config.d/*.conf`, así que sshd ignoraba el drop-in. **Fix
  2026-06-17**: el rol (paso 2b, `lineinfile`) y `3-SetupPrimerInicio.sh` (`sed
  1i`) **garantizan ahora el Include** al principio de `sshd_config`. El script
  además registra en el log `sshd -T | grep usepam` para verlo. En equipos ya
  rotos: añadir esa línea a mano (arriba del fichero) + `systemctl restart ssh`,
  o reaplicar el rol (`--tags preparaad`).
- **`sftp`/`scp`/`sftp://` fallan: falta el subsistema SFTP** (visto 2026-06-19;
  mismo patrón que el bug `UsePAM`/`Include`): el `sshd_config` reducido de Ubuntu
  26.04 (instalación squashfs + `--force-confold`) puede quedarse **sin la línea
  `Subsystem sftp`**, y el binario `/usr/lib/openssh/sftp-server` vive en el
  paquete **aparte** `openssh-sftp-server` (solo *Recommends* de `openssh-server`,
  puede faltar en una instalación mínima). Sin ambos, `sftp://` en GNOME Files
  (sesión Wayland), `sftp` y `scp` (OpenSSH ≥ 9 transfiere por SFTP) fallan con
  *"subsystem request failed on channel 0"*. **Solución** (paso **2c** del rol y
  `3-SetupPrimerInicio.sh`, mantener en sync): instalar `openssh-sftp-server` y
  añadir `Subsystem sftp /usr/lib/openssh/sftp-server` a `sshd_config` **solo si
  no hay ya uno activo** (OpenSSH **aborta** si `Subsystem sftp` se define dos
  veces). Diagnóstico: `sshd -T | grep -i subsystem` (debe dar
  `subsystem-sftp /usr/lib/openssh/sftp-server`) + `dpkg -l openssh-sftp-server`.
  En equipos ya rotos: reaplicar el rol con `--tags sftp`.
- **Salir del dominio**: `utilesAD/4-SacaDelDominio.sh` (borra la cuenta de
  equipo de la OU con `realm leave -U`, deshace la config local y elimina el
  snippet `conf.d/10-iac-ad.conf` huérfano). A mano: `realm leave` deshace solo
  la config local (deja la cuenta en AD); en ese caso borrar el snippet a mano
  (si no, sssd intentaría arrancar con un dominio sin sección `[sssd]`).
- **Borrar el rastro de los usuarios del dominio** (homes, subuid/subgid,
  lingering, daemon rootless, AccountsService, correo/cron, tickets Kerberos):
  `utilesAD/5-LimpiaUsuariosDominio.sh`, **después** de `4-SacaDelDominio.sh`
  (necesita que los usuarios ya NO resuelvan en `getent`). Es **destructivo**:
  pide confirmación `BORRAR`; usar antes `--dry-run` para ver la lista; `--si`
  para un pase de aula desatendido. Preserva siempre los usuarios locales
  (`/etc/passwd`). Razón de ser separado de `4-`: salir del dominio es
  reversible (re-unir), pero borrar las carpetas personales no.
