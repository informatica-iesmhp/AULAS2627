# Playbook `08_apagar_equipos_aula.yml` — apagar el aula excepto el equipo del profesor

**Fecha:** 2026-09-18
**Contexto:** se pide un playbook para apagar en remoto los equipos de un
aula (IF01-IF04) sin tocar nunca el del profesor, con dos modos de uso:
apagar todos los equipos de alumnos de golpe, o apagar solo los que en
ese momento no tienen a nadie con sesión iniciada. Entregado como fichero
aparte (`08_apagar_equipos_aula.yml`), siguiendo la numeración de los
playbooks ya existentes del proyecto.

## Qué hace

Un único playbook, dos modos, elegidos con `-e modo_apagado=...`:

1. **`modo_apagado=todos`** — apaga todos los equipos de alumnos del aula,
   tengan o no alguien trabajando en ellos en ese momento. Pensado para
   el final del día, o para cuando el profesorado necesita el aula vacía
   sí o sí.
2. **`modo_apagado=inactivos`** — apaga solo los equipos donde, justo en
   el momento de lanzar el playbook, no hay ninguna sesión de usuario
   iniciada. Los equipos donde alguien sigue conectado (por ejemplo,
   alumnado que se ha quedado rematando algo, o el turno de tarde
   empalmando con el de mañana) se dejan tal cual, sin avisar ni
   interrumpir. Pensado para "limpiar" el aula de equipos abandonados sin
   arriesgarse a cortarle el trabajo a nadie.

El equipo del profesor **nunca** se apaga con este playbook, en ningún
modo — se excluye por `inventory_hostname` con `meta: end_host`, igual
que hacen los demás playbooks del proyecto (`06_montar_comparte_aula_alumnos.yml`)
para no aplicar cambios propios de alumnos al equipo del profesor.

## Cómo decide si un equipo "tiene alguien conectado"

En modo `inactivos`, la comprobación es sencilla a propósito: ejecuta
`who` en el equipo y mira si devuelve alguna línea. `who` solo lista
sesiones de usuario reales (alguien que ha iniciado sesión de verdad, con
su TTY o su sesión gráfica asociada) — no cuenta procesos en segundo
plano ni nada parecido.

**El detalle importante, y la razón de que esto funcione sin confundirse
con la propia conexión de Ansible:** cuando Ansible se conecta por SSH
para lanzar un módulo, no pide una terminal (`pty`) — es como alguien que
entra un momento a dejar un recado por la rendija de la puerta, sin
llegar a sentarse ni abrir la puerta del todo. Esas conexiones "de
recado" no dejan rastro en el registro de quién ha iniciado sesión
(`utmp`), así que `who` no las ve, y la propia ejecución del playbook
nunca cuenta como "alguien conectado". Solo aparecen ahí las sesiones de
verdad: alguien sentado delante del equipo con su usuario de dominio, o
alguien que ha entrado por SSH de forma interactiva.

## Margen antes de apagar (`retraso_segundos`)

El módulo `ansible.builtin.shutdown` manda el aviso estándar de apagado
(el mismo mensaje que ve cualquiera que tenga una sesión abierta cuando
alguien ejecuta `shutdown` a mano) y espera `retraso_segundos` (60 por
defecto) antes de apagar de verdad. Así, en modo `todos`, quien tenga
algo sin guardar ve el aviso y tiene un minuto de margen — no es un corte
en seco. En modo `inactivos` este aviso no lo ve nadie, porque por
definición esos equipos no tienen a nadie delante.

Se puede ajustar con `-e retraso_segundos=180` si se prefiere más margen,
o `-e retraso_segundos=0` para un apagado inmediato.

## Los tres gatillos obligatorios (a propósito, sin valores por defecto)

Igual que `03_reunir_dominio.yml` exige `-e confirmar_reunion=true` para
no dispararse por error, este playbook exige explícitamente:

- `profesor_host` (p. ej. `IF01-00`) — qué equipo excluir.
- `modo_apagado` (`todos` o `inactivos`) — qué comportamiento se quiere.
- `confirmar_apagado=true` — gatillo aparte, para que apagar un aula
  entera nunca sea el efecto colateral de un comando mal copiado.

Si falta cualquiera de los tres, o `modo_apagado` no es uno de los dos
valores válidos, el playbook falla en el primer paso con un mensaje
explicando qué falta, antes de tocar ningún equipo.

## Cómo lanzarlo

```bash
# Apagar TODO el aula IF01 menos el equipo del profesor, ya mismo:
ansible-playbook -i inventarios/IF01.ini playbooks/08_apagar_equipos_aula.yml \
    -u ansible-admin -e profesor_host=IF01-00 -e modo_apagado=todos \
    -e confirmar_apagado=true

# Apagar solo los equipos de IF02 sin sesión iniciada:
ansible-playbook -i inventarios/IF02.ini playbooks/08_apagar_equipos_aula.yml \
    -u ansible-admin -e profesor_host=IF02-00 -e modo_apagado=inactivos \
    -e confirmar_apagado=true
```

**Recomendado antes de lanzarlo al aula entera** — como con el resto de
playbooks del proyecto, probar primero contra un equipo piloto con
`--limit`, comprobando además el caso con sesión iniciada y sin ella:

```bash
ansible-playbook -i inventarios/IF01.ini playbooks/08_apagar_equipos_aula.yml \
    -u ansible-admin -e profesor_host=IF01-00 -e modo_apagado=inactivos \
    -e confirmar_apagado=true --limit IF01-05
```

**Simulacro sin apagar nada de verdad:** añadiendo `--check` al final de
cualquiera de los comandos anteriores, Ansible recorre toda la lógica
(exclusión del profesor, comprobación de sesiones, decisión por equipo)
pero no llega a ejecutar el apagado real — útil para ver, antes de
disparar en serio, qué equipos se apagarían en modo `inactivos` en un
momento dado.

## Pendiente / a verificar

- **Confirmar en un equipo piloto que la conexión de Ansible, en efecto,
  no aparece en `who`** — es el comportamiento estándar de SSH sin `pty`
  y debería cumplirse siempre con la configuración actual del proyecto,
  pero conviene comprobarlo una vez contra un equipo real antes de
  confiar en modo `inactivos` para el aula entera. Si por lo que sea
  apareciera (por ejemplo, si en el futuro se cambia algo de la
  configuración SSH que fuerce asignación de `pty`), la alternativa más
  robusta es comprobar sesiones gráficas por `loginctl` filtrando por
  `Seat=seat0` en vez de por `who` — más preciso pero más largo de
  escribir; se deja como mejora si `who` diera problemas.
- **Módulo `ansible.builtin.shutdown`**: forma parte de `ansible-core`
  desde la versión 2.11 (antes vivía en `community.general`). Si algún
  control node del proyecto tiene una versión de Ansible más antigua que
  esa, el playbook fallaría al no encontrar el módulo — comprobar
  `ansible --version` en el equipo del profesor antes de lanzarlo por
  primera vez.
- **Fuera de alcance de este playbook:** volver a encenderlos — ver
  ahora `09_habilitar_wol.yml` y `encender_aula.sh`, la pieza de
  Wake-on-LAN que resuelve justo esto.
- **Probar primero en el equipo del profesor o en un equipo piloto de
  alumnos**, como con el resto de playbooks del proyecto, antes de
  extenderlo a un aula completa.
