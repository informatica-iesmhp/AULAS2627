# Playbook `10_apagado_automatico_nocturno.yml` — apagado automático del aula a las 21:00

**Fecha:** 2026-09-22
**Contexto:** algunos equipos del aula se quedan encendidos por la noche
(nadie los apaga al salir). Se pide un mecanismo que los apague solo,
automáticamente, todas las noches a las 21:00, desplegado por Ansible a
todos los equipos del aula de una vez para no tener que ir uno por uno.
Entregado como fichero aparte (`10_apagado_automatico_nocturno.yml`),
siguiendo la numeración de los playbooks ya existentes del proyecto.

## La idea clave: no es un playbook que "se queda corriendo"

Esto es fácil de confundir con `08_apagar_equipos_aula.yml`, pero son dos
cosas muy distintas:

- **`08_apagar_equipos_aula.yml`** apaga el aula **en el momento** en que
  se lanza el comando — hace falta ejecutarlo a mano (o desde un cron en
  el equipo del profesor) cada vez que se quiere apagar.
- **`10_apagado_automatico_nocturno.yml`** se lanza **una sola vez** (o
  cada vez que se quiera cambiar la hora o el margen) y lo que hace es
  **dejar montado un despertador dentro de cada equipo** — un
  temporizador de `systemd`, el mismo mecanismo del sistema operativo que
  ya se usó en `09_habilitar_wol.yml` para que Wake-on-LAN sobreviva a
  los reinicios. A partir de ahí, cada equipo se apaga solo todas las
  noches a las 21:00, **sin que Ansible tenga que estar corriendo ni
  conectado en ese momento** — es el propio equipo el que lleva la cuenta
  de la hora, como una alarma de móvil: la programas una vez y suena todas
  las noches aunque el teléfono lleve horas sin conexión a internet.

Si un equipo está apagado a las 21:00 (por ejemplo, porque ya lo apagó
alguien, o porque nunca llegó a encenderse ese día), el temporizador
simplemente no tiene nada que hacer ese día — no se "acumula" ningún
apagado pendiente para el día siguiente (`Persistent=false`, a propósito:
lo contrario haría que el equipo se apagara solo nada más arrancar por la
mañana, que es justo lo que no interesa).

## Qué hace, por equipo

1. A las 21:00 (hora configurable), un temporizador de systemd
   (`apagado-nocturno.timer`) dispara un servicio
   (`apagado-nocturno.service`) que ejecuta un script
   (`/usr/local/sbin/apagado-nocturno.sh`).
2. El script avisa por pantalla a quien tenga sesión iniciada — el mismo
   tipo de aviso estándar que ve cualquiera cuando alguien ejecuta
   `shutdown` a mano — y dice cuántos minutos quedan.
3. Pasado ese margen de cortesía (5 minutos por defecto), el equipo se
   apaga. **Se apaga siempre, haya o no alguien con sesión iniciada** —
   se ha implementado así a propósito, para garantizar que ningún equipo
   se quede encendido toda la noche, ni siquiera si alguien se ha dejado
   una sesión abierta sin estar realmente trabajando.

## El equipo del profesor, excluido siempre

Igual que `08_apagar_equipos_aula.yml`, el equipo del profesor
(`profesor_host`, p. ej. `IF01-00`) se excluye por `inventory_hostname`
con `meta: end_host` antes de tocar nada — nunca se le instala este
apagado automático.

## Los dos gatillos obligatorios (a propósito, sin valores por defecto)

- `profesor_host` — qué equipo excluir.
- `confirmar_apagado_automatico=true` — para que dejar montado un
  apagado automático en toda un aula nunca sea el efecto colateral de un
  comando mal copiado. El playbook comprueba estas variables (y que
  `hora_apagado`, si se pasa, tenga formato `HH:MM`) en el primer paso,
  antes de tocar ningún equipo — igual que hacen `03_reunir_dominio.yml`
  y `08_apagar_equipos_aula.yml`.

## Variables opcionales

- `hora_apagado` (por defecto `21:00`) — hora a la que se dispara el
  aviso, en formato `HH:MM`.
- `apagado_margen_minutos` (por defecto `5`) — minutos de margen entre el
  aviso y el apagado real.
- `apagado_automatico_activo` (por defecto `true`) — con `false`, el
  playbook deja instalados el script y las unidades de systemd pero
  **desactiva y para el temporizador**, sin desinstalar nada. Pensado
  para desactivar el apagado automático temporalmente (una semana de
  exámenes con turno de tarde, una jornada de puertas abiertas...) y
  reactivarlo después simplemente volviendo a lanzar el playbook con
  `apagado_automatico_activo=true` (o sin la variable, que es el valor
  por defecto).

## Cómo lanzarlo

```bash
# Instalar y activar en toda el aula IF01, a las 21:00 por defecto:
ansible-playbook -i inventarios/IF01.ini playbooks/10_apagado_automatico_nocturno.yml \
    -u ansible-admin -e profesor_host=IF01-00 -e confirmar_apagado_automatico=true

# Cambiar la hora y el margen de aviso:
ansible-playbook -i inventarios/IF01.ini playbooks/10_apagado_automatico_nocturno.yml \
    -u ansible-admin -e profesor_host=IF01-00 -e confirmar_apagado_automatico=true \
    -e hora_apagado=22:30 -e apagado_margen_minutos=10

# Desactivar temporalmente en toda el aula (sin desinstalar):
ansible-playbook -i inventarios/IF01.ini playbooks/10_apagado_automatico_nocturno.yml \
    -u ansible-admin -e profesor_host=IF01-00 -e confirmar_apagado_automatico=true \
    -e apagado_automatico_activo=false
```

**Recomendado antes de lanzarlo al aula entera** — como con el resto de
playbooks del proyecto, probar primero contra un equipo piloto:

```bash
ansible-playbook -i inventarios/IF01.ini playbooks/10_apagado_automatico_nocturno.yml \
    -u ansible-admin -e profesor_host=IF01-00 -e confirmar_apagado_automatico=true \
    --limit IF01-05
```

No hace falta esperar hasta las 21:00 para comprobar que ha quedado bien
instalado — el playbook ya muestra al final la próxima ejecución
programada (`systemctl list-timers apagado-nocturno.timer`). Para forzar
una prueba real de apagado sin esperar a la hora, en el equipo piloto:

```bash
sudo systemctl start apagado-nocturno.service   # dispara el aviso + apagado ya mismo
```

## Cómo comprobar a mano en un equipo

```bash
systemctl status apagado-nocturno.timer     # activo y programado
systemctl list-timers apagado-nocturno.timer --no-pager   # próxima vez que saltará
journalctl -t apagado-nocturno              # historial de disparos (via logger)
```

## Relación con Wake-on-LAN (`09_habilitar_wol.yml`)

Estas dos piezas encajan de forma natural: con `10_...` el aula se apaga
sola cada noche, y con `09_habilitar_wol.yml` + `encender_aula.sh` se
puede volver a encender en remoto por la mañana antes de la primera
clase, sin que nadie tenga que ir físicamente a pulsar el botón de cada
equipo. Ojo con el mismo matiz que ya se documentó en `09_...`: si la
regleta/corriente del aula se corta por la noche, Wake-on-LAN no podrá
despertar equipos que se hayan apagado por completo sin alimentación de
espera — pero eso ya estaba fuera del alcance de ambos playbooks, no es
algo nuevo que introduzca este.

## Pendiente / a verificar

- **Confirmar con el centro si 21:00 es la hora correcta para las cuatro
  aulas** — si alguna tiene clases de tarde/noche que se alargan más
  allá de esa hora, ese aula necesitará un `hora_apagado` distinto (o
  quedar excluida de este playbook por ahora).
- **Decidir si el comportamiento incondicional (apagar aunque haya sesión
  activa) es el que se quiere mantener a largo plazo.** Se ha
  implementado así a propósito según lo pedido, pero si en el futuro se
  prefiere "avisar pero no apagar si hay alguien trabajando" (como el
  modo `inactivos` de `08_apagar_equipos_aula.yml`), el propio fichero
  del playbook deja anotada la variante del script que haría falta
  (comprobación con `who`, igual que en `08_...`).
- **Probar primero en un equipo piloto de cada aula**, como con el resto
  de playbooks del proyecto, y forzar una prueba real con
  `systemctl start apagado-nocturno.service` en vez de esperar a las
  21:00 la primera vez.
- **Servicio Veyon** (`playbook-configurar-veyon-IF01-IF04.md`): si el
  profesorado usa Veyon para controlar el aula, un apagado automático a
  las 21:00 es transparente para Veyon (Veyon simplemente deja de ver el
  equipo, como si se hubiera apagado a mano) — no debería requerir ningún
  ajuste adicional, pero conviene confirmarlo la primera vez que coincida
  con una sesión de Veyon abierta pasadas las 21:00.
