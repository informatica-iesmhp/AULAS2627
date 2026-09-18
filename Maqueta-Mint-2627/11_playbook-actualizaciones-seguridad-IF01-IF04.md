# Playbook `07_actualizaciones_seguridad.yml` — solo actualizaciones de seguridad, en automático

**Fecha:** 2026-09-18
**Contexto:** se pide un playbook para las cuatro aulas (IF01-IF04) que
configure las actualizaciones del sistema para que se instalen en
automático **solo** las de seguridad, dejando fuera actualizaciones
normales, de Mint y backports. Entregado como fichero aparte
(`07_actualizaciones_seguridad.yml`, pendiente de subir al repo con ese
número o el que le corresponda según lo que ya esté mergeado).

## Qué hace

Instala y configura `unattended-upgrades` (la herramienta estándar de
Debian/Ubuntu para esto) en cada equipo del aula — profesor y alumnos por
igual — para que cada día, solo, sin que nadie tenga que entrar:

1. Compruebe si hay actualizaciones de **seguridad** pendientes.
2. Las descargue e instale.
3. Si alguna necesita reiniciar (típicamente el kernel), reinicie el
   equipo solo, pero **solo si no hay nadie con sesión iniciada** en ese
   momento — y a una hora fija fuera de horario lectivo
   (`05:30` por defecto, ajustable).

Todo lo demás (actualizaciones normales, actualizaciones de Mint,
backports) se deja **fuera** a propósito — eso lo sigue gestionando el
profesorado a mano, cuando quiera, con el gestor de actualizaciones
gráfico de Mint de toda la vida (ver más abajo, "Qué pasa con el
Gestor de actualizaciones de Mint").

## La trampa de Mint (por qué no basta con instalar el paquete y ya)

`unattended-upgrades` decide qué actualizar mirando el "sello de fábrica"
(el origen) de cada paquete disponible, no su nombre. Por defecto, su
fichero de configuración usa dos variables, `${distro_id}` y
`${distro_codename}`, para rellenar ese filtro automáticamente según el
sistema en el que se instale.

El problema: en Linux Mint, esas dos variables no valen "Ubuntu" y
"noble" (el codename de Ubuntu del que cuelga Mint 22.x) — valen
"Linuxmint" y el codename **de Mint** (p. ej. "zena" para 22.3). Es como
si un guardia de seguridad en la puerta de un almacén tuviera la
consigna de "deja pasar solo lo que lleve el sello de la fábrica
Linuxmint" — pero casi todo lo que de verdad importa para la seguridad
del sistema (el kernel, `openssl`, `glibc`, y en general la base entera)
llega con el sello "Ubuntu", porque es Ubuntu quien lo fabrica y Mint
simplemente lo redistribuye tal cual. El guardia, siguiendo la consigna
de fábrica al pie de la letra, rechaza silenciosamente todo lo que
importa — y no avisa a nadie de que lo está haciendo. El equipo *parece*
tener actualizaciones automáticas configuradas y funcionando, pero en la
práctica no actualiza nada relevante. Es un problema conocido del propio
proyecto Mint, documentado y sin resolver desde 2020
([linuxmint/linuxmint#282](https://github.com/linuxmint/linuxmint/issues/282)).

**La solución que aplica el playbook:** en vez de dejar que esas dos
variables se calculen solas (mal, en Mint), el fichero
`/etc/apt/apt.conf.d/50unattended-upgrades` que despliega el playbook
escribe el origen real a pelo:

```
Unattended-Upgrade::Allowed-Origins {
    "Ubuntu:noble-security";
};
```

Esto es exactamente lo que hay que perseguir con "solo seguridad": el
repositorio `noble-security` de Ubuntu es donde llegan los parches de
seguridad reales, y es lo único que se toca. Deliberadamente **no** se
incluye `"Ubuntu:noble"` a secas (eso traería también actualizaciones
normales, no solo de seguridad) ni ningún origen `"Linuxmint:..."` (Mint
no publica un repositorio de seguridad separado para sus propios
paquetes — los pocos parches de seguridad que le tocan a componentes
específicos de Mint llegan mezclados con sus actualizaciones normales, no
por esta vía).

Si el día de mañana se despliega una versión distinta de Mint (basada en
otro Ubuntu), hay que cambiar la variable `ubuntu_codename` del playbook
— no basta con que Ansible detecte el sistema solo, por el mismo motivo.

## Requisito previo: el repositorio de HashiCorp roto

Ya documentado en `diagnostico-bootstrap-aulas-IF01-IF04.md` (sección 6):
la maqueta trae un repositorio de HashiCorp con la clave GPG caducada, y
un solo repositorio con la clave inválida hace que `apt update` falle
**entero** (no solo ese repositorio) cuando lo ejecuta el módulo `apt` de
Ansible (o cualquier herramienta que use `python-apt` por debajo, como
`unattended-upgrades`). Si un aula todavía no ha pasado por
`arreglar_repo_apt_hashicorp.yml`, este playbook se para en seco en la
primera tarea (comprobación de `apt update`) con un mensaje claro, en vez
de dejar una configuración a medias que parezca correcta pero no
funcione — el mismo tipo de fallo silencioso que la trampa de Mint de
arriba, así que se ha preferido que falle alto y claro en vez de
esconderlo.

## Reinicio automático: por qué sí, y la red de seguridad

Muchos parches de seguridad (kernel, `glibc`...) no surten efecto de
verdad hasta que se reinicia. Dejarlos "instalados pero pendientes de
aplicar" indefinidamente es, en la práctica, casi como no instalarlos.
Por eso el playbook activa el reinicio automático — pero con dos
salvaguardas:

- **Solo si no hay nadie con sesión iniciada** en el equipo en ese
  momento (`Automatic-Reboot-WithUsers "false"`). Si a las 05:30 alguien
  sigue conectado, ese día no se reinicia — lo volverá a intentar en la
  siguiente comprobación.
- **Hora fija fuera de horario lectivo** (`05:30` por defecto).

**Pendiente de confirmar con el centro:** si los equipos del aula se
**apagan cada noche** (por los propios alumnos, por limpieza, o por
política del centro), a las 05:30 estarán apagados y el reinicio
programado simplemente no se disparará ese día — los timers de systemd
(`apt-daily.timer` / `apt-daily-upgrade.timer`) sí se ponen al día solos
en cuanto el equipo arranca de nuevo (llevan `Persistent=true`), así que
la instalación de parches no se pierde, pero el reinicio para aplicarlos
puede quedar pospuesto varios días si nunca coincide con un momento
"equipo encendido + sin nadie conectado". Si resulta que los equipos se
apagan cada noche, puede compensar más cambiar
`hora_reinicio_actualizaciones` a una franja en la que sí suelan estar
encendidos y libres (p. ej., a primera hora de la mañana antes de la
primera clase, o al mediodía en el hueco del recreo), en vez de
dejarlo a las 05:30.

## Qué pasa con el Gestor de actualizaciones de Mint

Este playbook no toca `mintupdate` (el gestor gráfico de actualizaciones
de Mint) ni lo desactiva. Sigue ahí, y el profesorado lo puede seguir
usando igual que hasta ahora para actualizaciones normales o mayores,
cuando le convenga. El único efecto visible es que, tras cada pasada
nocturna de `unattended-upgrades`, `mintupdate` mostrará menos paquetes
pendientes (los de seguridad ya se habrán instalado solos) — no hay
conflicto entre los dos, trabajan sobre el mismo `apt` por debajo.

## Cómo lanzarlo

Igual que el resto de playbooks numerados, un aula cada vez:

```bash
ansible-playbook -i inventarios/IF01.ini playbooks/07_actualizaciones_seguridad.yml -u ansible-admin
```

**Recomendado antes de lanzarlo al aula entera:** probarlo primero contra
un solo equipo (el del profesor es el más cómodo, ya lo tienes delante):

```bash
ansible-playbook -i inventarios/IF01.ini playbooks/07_actualizaciones_seguridad.yml \
    -u ansible-admin --limit IF01-00
```

## Cómo verificar que de verdad está funcionando (no solo que "no ha dado error")

Esto es lo importante, precisamente por la trampa de Mint explicada
arriba: que el playbook termine en verde no demuestra por sí solo que el
filtro de orígenes esté bien — para eso hace falta mirar la salida real.
La última tarea del playbook ya hace esto automáticamente (task "Mostrar
los orígenes permitidos..."), pero conviene revisarla a ojo en el equipo
piloto, y si hace falta repetirlo a mano:

```bash
sudo unattended-upgrade --dry-run --debug 2>&1 | grep -i origin
```

Busca una línea con `o=Ubuntu,a=noble-security` (o similar) en la lista
de orígenes permitidos. Si en vez de eso solo aparece algo con
`Linuxmint`, la configuración desplegada no es la de este playbook (o no
se ha aplicado bien) — hay que revisar
`/etc/apt/apt.conf.d/50unattended-upgrades` a mano en ese equipo.

Otras comprobaciones útiles:

```bash
# Que los timers están activos
systemctl is-enabled apt-daily.timer apt-daily-upgrade.timer
systemctl status apt-daily-upgrade.timer

# Historial real de lo que se ha instalado por esta vía
cat /var/log/unattended-upgrades/unattended-upgrades.log
```

## Pendiente / a verificar

- **Confirmar con el centro si los equipos se apagan cada noche** — ver
  el apartado de reinicio automático arriba; si es así, revisar
  `hora_reinicio_actualizaciones`.
- **Probar primero en el equipo del profesor de una sola aula** antes de
  extenderlo al resto, como con el resto de playbooks del proyecto.
- **Confirmar que ninguna aula tiene ya pendiente el arreglo del
  repositorio de HashiCorp** antes de lanzar esto sin más (o lanzar antes
  `arreglar_repo_apt_hashicorp.yml` por si acaso, ya que es idempotente y
  no hace nada si el repo ya está limpio).
- Este playbook asume que las cuatro aulas siguen en Mint 22.x / Ubuntu
  `noble`. Si en algún momento conviven aulas con versiones distintas de
  Mint, `ubuntu_codename` tendría que pasar a ser una variable por
  inventario/aula en vez de un valor fijo en el playbook.
