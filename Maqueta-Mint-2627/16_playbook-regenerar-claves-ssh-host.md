# Regenerar las claves de host SSH de los equipos clonados

**Fecha:** 2026-10-09
**Playbook:** `regenerar_claves_ssh_host.yml`

## Problema

Los equipos de las aulas se clonaron de la maqueta sin regenerar las
claves de host SSH (`/etc/ssh/ssh_host_*_key`), así que comparten la
misma identidad SSH. Se detectó en IF03 al lanzar el playbook de
`comparte-aula`: al conectar por primera vez a IF03-20 (10.0.10.120),
SSH avisó de que su clave era la misma que la de IF03-14 (10.0.10.114).

Consecuencias: la comprobación de `known_hosts` deja de distinguir un
equipo de otro (no protege contra suplantaciones) y todos comparten la
misma clave privada de host.

## Qué hace el playbook

1. Lee la huella ed25519 de cada equipo y muestra qué equipos comparten
   clave (siempre, también con `-e solo_comprobar=true`).
2. Si no se ha hecho antes (marca `/etc/ssh/.claves_host_regeneradas`):
   genera claves nuevas ed25519/ecdsa/rsa, las instala, valida con
   `sshd -t` (si falla, restaura las anteriores y para) y reinicia
   `ssh`. Todo en una sola tarea remota.
3. Actualiza el `known_hosts` del usuario que lanza Ansible (por IP y
   por nombre de inventario) con las claves nuevas, leídas por la propia
   conexión ya autenticada. Tarea con `throttle: 1` para no pisar el
   fichero en paralelo.
4. Verifica con `ssh-keyscan` que el equipo ya sirve la clave nueva y
   vuelve a mostrar el resumen de repetidas.

Idempotente por la marca: relanzarlo no cambia las claves de los equipos
ya hechos; los apagados se hacen la siguiente vez. `-e forzar=true`
para repetir en un equipo concreto.

Probado en entorno de pruebas con ansible-core 2.16: regeneración,
actualización de `known_hosts` sin duplicar entradas, idempotencia y
restauración automática si `sshd -t` falla.

## Uso

```
ansible-playbook -i inventarios/IF03.ini playbooks/regenerar_claves_ssh_host.yml -u ansible-admin -e solo_comprobar=true
ansible-playbook -i inventarios/IF03.ini playbooks/regenerar_claves_ssh_host.yml -u ansible-admin --limit IF03-21
ansible-playbook -i inventarios/IF03.ini playbooks/regenerar_claves_ssh_host.yml -u ansible-admin
```

## Después / avisos

- Otros equipos o usuarios que se hubieran conectado antes a estos
  equipos verán `REMOTE HOST IDENTIFICATION HAS CHANGED`: es esperado,
  se arregla con `ssh-keygen -R <IP o nombre>` en ese equipo.
- Recomendado en `ansible.cfg`, para que un equipo nunca visto no deje
  el playbook parado esperando un "yes" (pasó en IF03 con IF03-20):
  ```
  [ssh_connection]
  ssh_args = -C -o ControlMaster=auto -o ControlPersist=60s -o StrictHostKeyChecking=accept-new
  ```
  `accept-new` acepta solo claves de equipos nuevos; una clave cambiada
  en un equipo conocido se sigue rechazando.
- Cada vez que se vuelva a clonar la maqueta, lanzar este playbook sobre
  los equipos recién clonados.

## Estado

| Aula | Estado |
|---|---|
| IF03 | pendiente de lanzar |
| IF01 / IF02 / IF04 | pendiente (comprobar primero con `solo_comprobar`) |
