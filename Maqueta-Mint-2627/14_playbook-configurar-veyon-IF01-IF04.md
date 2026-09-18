# Configurar Veyon (monitorización de aula) en IF01-IF04

**Fecha:** 2026-09-18
**Contexto:** Veyon ya está instalado en todos los equipos de las cuatro
aulas. Falta configurarlo para que el profesor pueda monitorizar todos
los equipos de alumnos desde su propio equipo, y se pide automatizar esa
configuración con Ansible en vez de tocar cada equipo a mano.

## La analogía

Es como el sistema de llaves maestras de un edificio de habitaciones:
cada puerta de alumno lleva un bombín idéntico que solo abre con una
única llave maestra (la clave privada), y esa llave maestra la lleva
encima únicamente el profesor. Los alumnos no tienen copia, así que no
pueden abrirse las puertas entre ellos ni la del profesor. Ansible es el
cerrajero que instala el mismo bombín en las cuarenta puertas del aula
de una sola vez, en vez de ir puerta por puerta con un destornillador.

## Decisión de autenticación: clave (key file), no logon ni dominio

Veyon admite autenticar el Master frente a cada Service de dos formas:

1. **Logon Authentication** — el Master envía usuario/contraseña de
   dominio, el Service los valida. Depende de que la cuenta de dominio
   funcione igual en todos los equipos — descartada por el mismo motivo
   que ya llevó a evitar cuentas de dominio en `comparte-aula`: el
   proyecto ya documentó (`diagnostico-bootstrap-aulas-IF01-IF04.md`)
   problemas de fondo con la unión al dominio de la maqueta (cuenta de
   equipo compartida entre clones), y apoyar la monitorización del aula
   en eso añadiría una dependencia frágil a algo que tiene que funcionar
   todos los días.
2. **Key File Authentication** (la elegida) — un único par de claves
   ("profesor"): la pública se reparte a todos los equipos (alumno y
   profesor), la privada solo se queda en el equipo de profesor de esa
   aula. No depende del dominio en ningún lado de la conexión. Con esto
   solo, sin reglas de control de acceso adicionales, ya se cumple el
   objetivo pedido: solo quien tiene la clave privada (el profesor)
   puede conectarse a los equipos que tienen su clave pública
   registrada.

La clave privada **no viaja por la red**: se genera directamente en el
equipo de profesor con `veyon-cli authkeys create` y se queda ahí. Lo
único que sale de ese equipo hacia el nodo de control (y de ahí a los
alumnos) es la clave pública, que no es secreta. No hace falta
`ansible-vault` para nada de esto.

## Decisión de roles: el profesor no lleva Service

Se valoró que el equipo de profesor también llevara `veyon-service`
arrancado (para que, por ejemplo, otro profesor pudiera monitorizar esa
pantalla algún día — el mismo razonamiento que llevó a aplicar
`09_habilitar_wol.yml` también al profesor). Se descarta por ahora: el
equipo de profesor solo actúa como Master. Si en el futuro interesa lo
contrario, es un cambio de una línea (mover ese host del patrón `*-00`
a la jugada de alumnos, o añadirlo también a esa jugada).

## `10_configurar_veyon.yml` — qué hace

El playbook asume que el equipo de profesor de cada aula termina en
`-00` (`IF01-00`, `IF02-00`...) y el resto son alumnos — el mismo
criterio que ya usa `macs.csv` — y selecciona ambos grupos por patrón de
nombre (`hosts: "*-00"` / `hosts: "all:!*-00"`), sin necesitar tocar los
ficheros de inventario existentes ni depender de que exista un grupo
`profesores`/`alumnos` ya definido.

**Jugada 1 — equipo de profesor (`*-00`):**

1. Comprueba que `veyon-cli` responde (Veyon instalado).
2. Crea el par de claves `profesor` si no existe todavía
   (`authkeys create`, con `creates:` para no regenerarla en cada
   ejecución — mismo patrón que la clave SSH de `01_bootstrap_keys.yml`).
3. Activa `Authentication/Method = 1` (clave) solo si no estaba ya así.
4. Exporta la clave pública y la trae al nodo de control con `fetch`
   (queda en `files/veyon/<AULA>-profesor-public.pem` del repo).
5. Genera, desde el propio inventario de Ansible, el listado de equipos
   del aula (nombre + IP fija, sin depender de `macs.csv` ni de MACs —
   el campo MAC es opcional en Veyon y no hace falta para monitorizar).
6. Vacía y reconstruye el directorio de equipos del Master
   (`networkobjects clear` + `add location` + `import`) para que quede
   siempre igual al inventario actual.

**Jugada 2 — equipos de alumnos (todo menos `*-00`):**

1. Comprueba que `veyon-cli` responde.
2. Copia la clave pública del profesor (la que dejó la jugada 1) y la
   importa con `authkeys import`, con `creates:` para no repetirlo.
3. Activa `Authentication/Method = 1` solo si no estaba ya así.
4. Habilita y arranca `veyon-service` (`systemctl enable --now`).

Un `handler` reinicia `veyon-service` cuando cambia la clave o el método
de autenticación, para que el cambio surta efecto sin esperar a un
reinicio del equipo.

## Firewall

Está desactivado en la maqueta actual, así que el playbook no toca nada
de firewall. Si en algún momento se activa uno a nivel de aula, hay que
abrir el puerto de Veyon (por defecto 11100/TCP — confirmarlo con
`veyon-cli config get Network/VeyonServerPort` en un equipo real, no dar
el número por sentado) para la subred de esa aula concreta, con el mismo
criterio de "riesgo acotado a la subred" que ya se aceptó en
`comparte-aula` para el acceso de invitado.

## Cómo lanzarlo

```bash
ansible-playbook -i inventarios/if01.ini playbooks/10_configurar_veyon.yml -u ansible-admin
```

La primera jugada necesita al profesor, así que la primera vez conviene
lanzar el playbook completo contra un aula piloto (sin `--limit`) antes
de extenderlo al resto. Para relanzarlo después contra un único equipo
de alumno (por ejemplo, tras añadir uno nuevo al aula):

```bash
ansible-playbook -i inventarios/if01.ini playbooks/10_configurar_veyon.yml -u ansible-admin --limit IF01-05
```

(en ese caso hay que dejar también el equipo de profesor en el
`--limit`, porque la jugada 2 necesita leer la clave pública que generó
la jugada 1 en ese mismo playbook run — o usar la clave ya exportada en
`files/veyon/` de una ejecución anterior).

## Cómo comprobar a mano

En el equipo de profesor:

```bash
veyon-cli config get Authentication/Method     # debe dar 1
veyon-cli authkeys list details                # debe listar profesor/private y profesor/public
veyon-cli networkobjects list                  # debe mostrar la ubicación del aula con todos los alumnos
```

En un equipo de alumno:

```bash
veyon-cli config get Authentication/Method     # debe dar 1
veyon-cli authkeys list details                # debe listar profesor/public (sin la privada)
systemctl status veyon-service                 # debe estar active (running)
```

Y, la prueba real: abrir Veyon Master en el equipo de profesor y
comprobar que aparece el aula con sus equipos y que se puede ver la
pantalla de al menos uno.

## Pendiente / a verificar

- **No probado contra una instalación real de Veyon todavía** — la
  sintaxis de `veyon-cli` viene de la documentación oficial
  (`docs.veyon.io`) y del foro de la comunidad, pero conviene confirmar
  en un equipo piloto, sobre todo: la ruta exacta de la clave privada
  para el `creates:` (`/etc/veyon/keys/private/profesor/key`), y si
  `networkobjects import` duplica entradas al repetirse (el playbook usa
  `networkobjects clear` antes de reimportar precisamente para no
  depender de eso, pero el propio `clear` tampoco se ha probado en un
  equipo real).
- **`networkobjects clear` borra todo el directorio del Master en cada
  ejecución.** Si algún profesor llega a añadir equipos a mano desde la
  ventana de Veyon Master, se perderán al volver a lanzar el playbook.
  Aceptable mientras el inventario de Ansible sea la única fuente de
  verdad de qué equipos hay en cada aula (que es el caso hoy).
- **Aviso al alumnado**: al ser una herramienta de monitorización de
  pantallas, conviene dejar constancia en la documentación del centro de
  que el alumnado ha sido informado de que sus equipos pueden ser
  supervisados por el profesorado. No es algo que resuelva Ansible, pero
  merece quedar anotado. Veyon permite además mostrar un aviso en
  pantalla al alumno cuando el profesor toma el control, si interesa
  activarlo más adelante (no configurado en esta primera versión).
- **Firewall**: si se activa en el futuro, falta la tarea de apertura de
  puerto (ver sección "Firewall" arriba) — no incluida en el playbook a
  propósito, porque hoy no hace falta.
- **Probar primero en un equipo/aula piloto**, como el resto de
  playbooks del proyecto, antes de extenderlo a las cuatro aulas.
