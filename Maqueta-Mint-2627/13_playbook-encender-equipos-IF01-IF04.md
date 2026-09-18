# Encender el aula en remoto: Wake-on-LAN (WoL)

**Fecha:** 2026-09-18
**Contexto:** siguiente pieza de `08_apagar_equipos_aula.yml` — ahora que
se puede apagar el aula en remoto, se pide poder encenderla también.
Wake-on-LAN funciona muy distinto a un playbook normal: los equipos que
hay que encender están, por definición, apagados — así que no hay nada
a lo que Ansible pueda conectarse por SSH todavía. Por eso la solución
son **dos piezas separadas**, no una sola:

1. **`09_habilitar_wol.yml`** — playbook de Ansible normal, se lanza
   contra el aula **mientras los equipos están encendidos**, una vez
   (deja el soporte de WoL preparado para siempre, es idempotente).
2. **`encender_aula.sh`** — script que se ejecuta a mano en el equipo
   del profesor cuando se quiere encender el resto del aula. No es
   Ansible: manda "paquetes mágicos" por la red local a las MACs de los
   equipos apagados.

## La analogía: un timbre que hay que dejar "armado" de antemano

Wake-on-LAN es como un portero automático que solo abre la puerta si el
timbre está armado desde dentro. No basta con pulsar el botón de fuera
(mandar el paquete mágico) si nadie dejó el mecanismo activado antes de
irse. Aquí hay **tres cerrojos** que tienen que estar abiertos a la vez,
y si falta uno, el timbre no suena aunque los otros dos estén bien:

1. **La BIOS/UEFI** de cada equipo, diciendo "aunque esté apagado, deja
   la tarjeta de red con corriente de espera y escuchando" (la opción se
   suele llamar "Wake on LAN", "Power On by PCI-E" o "Resume by PCIe
   Device" según el fabricante de la placa).
2. **El sistema operativo**, diciendo lo mismo a nivel de controlador de
   red (`ethtool ... wol g`) — la mayoría de tarjetas "olvidan" este
   ajuste en cada arranque aunque la BIOS esté bien, así que hay que
   reaplicarlo cada vez que el equipo arranca.
3. **La corriente eléctrica de verdad**, sin cortar — la tarjeta de red
   solo puede "escuchar" apagada si sigue teniendo alimentación de
   espera. Si el aula se queda sin corriente por la noche (regleta
   apagada, breaker cortado), da igual lo bien configurados que estén
   los otros dos cerrojos: no hay nada escuchando.

`09_habilitar_wol.yml` resuelve el cerrojo 2 (y dentro de sus manos,
solo ese). Los cerrojos 1 y 3 son responsabilidad humana/física, fuera
del alcance de cualquier playbook.

## `09_habilitar_wol.yml` — qué hace

Se aplica a **todos** los equipos del inventario, profesor incluido (como
`07_actualizaciones_seguridad.yml`) — no hace daño tenerlo también en el
equipo del profesor, y así queda la puerta abierta por si algún día
interesa poder encenderlo en remoto igual que a los de alumnos.

Por cada equipo:

1. Detecta la interfaz de red cableada por defecto (`ansible_default_ipv4.interface`).
   Si el equipo no tiene ninguna (por ejemplo, si algún día se conecta
   solo por WiFi), se salta ese equipo con un aviso — WoL normalmente
   solo aplica a Ethernet.
2. Instala `ethtool` si falta.
3. Activa `wol g` (magic packet) ya mismo, en caliente — para que la
   comprobación funcione sin esperar a un reinicio.
4. Deja un script (`/usr/local/sbin/habilitar-wol.sh`) y un servicio de
   systemd (`wol-enable.service`, `WantedBy=multi-user.target`) que
   repiten ese mismo `ethtool ... wol g` en cada arranque — es la parte
   que hace falta para que WoL siga funcionando después del primer
   apagado, no solo la primera vez.
5. Muestra al final la línea `Wake-on:` real de `ethtool`, para poder
   comprobar a ojo (sin fiarse solo de que el playbook termine en verde)
   que ha quedado en `g` y no en `d` (desactivado).

### Cómo lanzarlo

```bash
ansible-playbook -i inventarios/IF01.ini playbooks/09_habilitar_wol.yml -u ansible-admin
```

Probar primero en un equipo, como con el resto de playbooks del proyecto:

```bash
ansible-playbook -i inventarios/IF01.ini playbooks/09_habilitar_wol.yml \
    -u ansible-admin --limit IF01-05
```

### Cómo comprobar a mano en un equipo

```bash
ethtool <interfaz>   # p.ej. eth0 / enp2s0 — buscar la línea "Wake-on:"
```

Debe decir `Wake-on: g`. Si dice `Wake-on: d`, algo no ha cuajado (revisar
que el servicio `wol-enable.service` esté activo: `systemctl status
wol-enable.service`).

## `encender_aula.sh` — qué hace

Vive fuera de Ansible a propósito, junto al resto de scripts del
proyecto que se ejecutan directamente en el equipo del profesor
(`configurar_equipo.sh`, `escanear_aula.sh`). Lee `macs.csv`, localiza
la sección del aula pedida, y manda un paquete mágico (`wakeonlan`) a
cada MAC de esa aula **excepto** `IF0X-00` (el profesor, que ya está
encendido: es quien ejecuta el script).

```bash
./encender_aula.sh IF01                  # despierta todo el aula IF01
./encender_aula.sh IF01 --verificar      # + hace ping a cada uno después
./encender_aula.sh IF01 --solo=IF01-05   # despierta solo ese equipo
```

Requiere el paquete `wakeonlan` (`sudo apt install wakeonlan`) en el
equipo del profesor. El envío usa la dirección de difusión (broadcast)
de la propia red local, así que solo despierta equipos en el mismo
segmento de red que el equipo del profesor — que es justo el caso de
cada aula, cada una en su propia subred.

La opción `--verificar` hace ping por nombre de equipo tras 30 segundos
de espera (el arranque tarda) — depende de que el DNS del dominio
resuelva esos nombres cortos (`IF01-05`, etc.); si no responde, no
significa necesariamente que WoL haya fallado, puede ser solo que el DNS
no resuelva ese nombre — en ese caso comprobar con la IP fija del
equipo (la misma que usa el inventario de Ansible para esa aula).

## Pendiente / a verificar

- **Confirmar en un equipo piloto que la BIOS realmente tiene "Wake on
  LAN" activado** — es el paso manual que ningún playbook puede hacer,
  y sin él nada de lo demás sirve de nada. Conviene comprobarlo en un
  equipo de cada modelo/aula antes de dar por bueno el resto.
- **Confirmar con el centro si las regletas/enchufes del aula se cortan
  por la noche.** Si es así, WoL simplemente no puede funcionar fuera
  de las horas en que el aula tiene corriente, por bien configurado que
  esté todo lo demás — igual que el reinicio automático de
  `07_actualizaciones_seguridad.yml` dependía de que los equipos
  siguieran encendidos a las 05:30.
- **Probar `--verificar` en la práctica** para confirmar si el DNS del
  dominio resuelve de verdad los nombres cortos de los equipos
  (`IF01-05`) desde el equipo del profesor — si no, cambiar esa parte
  del script para pings por IP usando el inventario, en vez de por
  nombre.
- **Ruta de `macs.csv` en `encender_aula.sh`**: el script asume que vive
  en una carpeta junto al repo (`../macs.csv` relativo a donde está el
  script) — ajustar la variable `MACS_CSV` al principio del script si la
  estructura real de carpetas en el equipo del profesor es distinta.
- **No cubre routers/switches gestionados con IGMP snooping agresivo o
  filtrado de broadcast** — si en algún momento se cambia el
  switch/router del aula por uno que bloquee tráfico de difusión entre
  puertos, `wakeonlan` dejaría de llegar aunque los tres cerrojos de
  arriba estén bien; no hay indicios de que sea el caso hoy, se deja
  anotado por si algún día WoL deja de funcionar sin motivo aparente.
