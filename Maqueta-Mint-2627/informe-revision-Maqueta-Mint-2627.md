# Informe de revisión — carpeta `Maqueta-Mint-2627`

**Fecha:** 2026-09-12
**Alcance:** todos los ficheros de `Maqueta-Mint-2627/` (guía, playbooks,
scripts, ficheros auxiliares) más `macs.csv` (raíz del repo, del que
dependen varios scripts de esta carpeta).

Este informe acompaña a la actualización de
`00_despliegue_aula_README.md`, que ya incorpora las incidencias
documentadas en `diagnostico-bootstrap-aulas-IF01-IF04.md`. Aquí se
recogen, además, otros hallazgos de coherencia y propuestas de mejora
detectados al revisar el resto de ficheros de la carpeta.

## 1. Cambios ya aplicados en esta revisión

- **`00_despliegue_aula_README.md`**: reescrita. Incorpora la fase de
  bootstrap de nombre/IP (antes no documentada — la guía asumía que DRBL
  ya dejaba IP fija, cosa que esta maqueta no hace), la fase de
  reunificación de dominio (`03_reunir_dominio.yml`, que no estaba
  mencionado en absoluto), el mapa de qué script se ejecuta dónde, y la
  corrección del comando de verificación SSH (ver siguiente punto).
- **`01_bootstrap_keys.yml`**: el mensaje final (`debug`) recomendaba el
  mismo comando de verificación con el bug documentado en el diagnóstico
  (`UserKnownHostsFile=/dev/null` + `StrictHostKeyChecking=accept-new`,
  que se anulan entre sí). Corregido para que coincida con el README.
- **`instalar_ansible_profesor.sh`**: el diagnóstico señala que hace
  falta `nmap` en el PC del profesor para el bootstrap por red (Fase 1),
  pero el script no lo instalaba — añadido a la línea de `apt-get
  install`. También se añade `pipelining = True` en `[ssh_connection]`
  del `ansible.cfg` que genera (mejora de rendimiento recomendada en el
  diagnóstico, antes solo mencionada de palabra en el propio documento).

`02_harden_ssh.yml` **no** se ha tocado: ya trae
`ansible_ssh_common_args: '-o StrictHostKeyChecking=accept-new'` como
variable de play, así que el bug del `known_hosts` no le afecta
directamente a él (afecta a la verificación manual previa, que es lo que
sí estaba mal documentado). `macs.csv` y
`ansible-bootstrap/ansible_bootstrap.zip` tampoco se han tocado: al
revisarlos, el hueco de `IF02` y el usuario `alumno` que señalaba el
diagnóstico **ya están corregidos** en el repositorio actual (la sección
`AULA IF02` existe en `macs.csv`, y `group_vars/all.yml` dentro del zip
ya usa `ansible_user: ansible-admin`). Solo hacía falta que la guía
reflejara ambas cosas, cosa que ya hace.

## 2. Incoherencias y datos a revisar (no modificados — requieren una
decisión o un dato que no tengo)

- **`macs.csv`, fila de `IF03-20`**: el campo MAC está vacío
  (`, IF03-20, 120, equipo alumno`). Ese equipo no podrá autoconfigurarse
  con `configurar_equipo.sh` hasta que se rellene con la MAC real
  (recógela con el mismo truco de `nmap -sn` que ya usa la guía).
- **Huecos en la numeración**: `IF04` no tiene `IF04-07`, `IF02` no tiene
  `IF02-03` ni `IF02-08`. Puede ser intencionado (equipos dados de baja),
  pero merece una comprobación rápida para no dar por hecho que faltan
  por añadir cuando en realidad ya no existen.
- **El mapeo aula → subred está triplicado**: aparece en los comentarios
  de `macs.csv`, en el array `AULA_SUBRED` de `configurar_equipo.sh`, y
  en el comentario de cabecera de
  `ansible-bootstrap/.../inventory/aula_bootstrap.nmap.yml`. Los tres
  coinciden hoy, pero si cambia la subred de un aula habrá que acordarse
  de actualizar los tres sitios a la vez. Merecería la pena tener una
  única fuente (por ejemplo, generar el array de `configurar_equipo.sh` a
  partir de los propios comentarios de `macs.csv`, o al menos dejar un
  comentario en los otros dos ficheros que remita a `macs.csv` como
  fuente de verdad).
- **`ansible_bootstrap.zip` versionado como binario**: al estar
  comprimido, no se puede ver su diff en el historial de git ni revisar
  cambios línea a línea (como se ha podido hacer aquí con el resto de
  ficheros). Sugerencia: subir su contenido descomprimido
  (`ansible/playbooks/...`, `ansible/inventory/...`) directamente al
  repositorio como ficheros de texto normales, y generar el `.zip` solo
  si hace falta distribuirlo suelto. Esto también habría hecho más fácil
  detectar en su día que el `ansible_user` ya estaba corregido, sin tener
  que descomprimirlo a mano para comprobarlo.
- **Duplicidad `tareas-ansible.md` / `tareas-ansible.docx`**: son dos
  listas de tareas distintas y ninguna es un subconjunto de la otra. El
  `.docx` no incluye "instalar y configurar Ansible" ni "reconfigurar
  equipos en dominio" (que sí están en el `.md`, y que son justo las
  tareas de las que trata esta guía); el `.md` no incluye "Instalar
  NetBeans" ni "Configurar Veyon" (que sí están en el `.docx`). Alguien
  que abra solo uno de los dos se queda con una foto incompleta.
  Sugerencia: quedarse con un único fichero de seguimiento (el `.md`, que
  además se puede editar y diferenciar fácilmente en git) y fusionar ahí
  las tareas que falten del `.docx`, o al menos dejar claro en el
  `.docx` que está descontinuado.
- **`usuario-ansible-admin.odt`**: son notas iniciales de cómo dejar un
  cliente listo para Ansible (por el formato del texto, con restos como
  "Usa el código con precaución", da la impresión de ser una copia de una
  respuesta de un asistente de IA pegada tal cual). Su contenido ya está
  totalmente cubierto e implementado por
  `prepara-cliente-ansible-admin.sh` e `instalar_ansible_profesor.sh`, así
  que hoy es redundante y, si alguien lo lee sin saber que está
  superado, puede llevar a confusión sobre cuál es la fuente de verdad.
  Sugerencia: archivarlo (p. ej. en una carpeta `historico/`) o
  eliminarlo, ya que la información vive ahora en los scripts.
- **Nombre de `prepara-cliente-ansible-admin.sh`**: por el nombre parece
  un script para ejecutar "en cada cliente" (cada PC de aula ya clonado),
  pero según el diagnóstico se ejecutó **una única vez**, sobre la
  plantilla, antes de clonarla — de ahí que ya no haga falta volver a
  correrlo tras el clonado. La guía actualizada ya lo aclara en la nueva
  tabla de "Mapa de ficheros", pero podría valer la pena renombrarlo (por
  ejemplo, `preparar-plantilla-ansible-admin.sh`) para que el nombre no
  induzca a error por sí solo.

## 3. Mejoras propuestas (no bloqueantes)

- **Dependencia de Internet de `configurar_equipo.sh`**: en cada
  ejecución, en cada equipo, el script clona el repositorio entero (o
  hace `curl` sobre el raw) solo para obtener `macs.csv`. Esto añade una
  dependencia de GitHub justo en el momento más temprano posible (equipo
  recién arrancado, sin identidad todavía) y, en el flujo de la Fase 1.3
  de la guía (por Ansible/`bootstrap_equipos.yml`), es innecesario: el
  profesor ya tiene una copia local de `macs.csv` en su propio clon del
  repositorio. Propuesta: que `bootstrap_equipos.yml` copie también el
  `macs.csv` local al equipo remoto (junto a `configurar_equipo.sh`) y
  que el script use esa copia si existe, cayendo a la descarga por
  git/curl solo cuando se ejecuta suelto (como en la Fase 1.2, a mano en
  el PC del profesor).
- **Rol Ansible para el `join` de dominio**: el proyecto ya tiene esto
  resuelto para la línea Ubuntu como un rol reutilizable
  (`preparaAD`), documentado con sus propios problemas conocidos
  (reposición de `pam_sss`/`nsswitch`, etc. — problemas que
  `03_reunir_dominio.yml` ya replica correctamente como tareas sueltas).
  Podría valer la pena, más adelante, convertir `03_reunir_dominio.yml`
  en un rol equivalente para Mint, para no mantener la misma lógica
  duplicada en dos sitios del repositorio con formatos distintos (rol vs.
  playbook suelto).
- **Convención de nombres de scripts**: se mezclan guiones
  (`prepara-cliente-ansible-admin.sh`) y guiones bajos
  (`instalar_ansible_profesor.sh`, `configurar_equipo.sh`). No afecta al
  funcionamiento, pero unificar el criterio ayudaría a que la carpeta se
  lea como un conjunto coherente.
- **`03_reunir_dominio.yml` pendiente de validar**: ya señalado en la
  propia guía actualizada (Fase 3), pero se repite aquí porque es
  relevante para la revisión de coherencia: es el único de los cuatro
  playbooks que no se ha probado todavía contra un Active Directory real.
  Antes de darlo por definitivo, conviene ejecutarlo con `--limit` en un
  equipo de pruebas y confirmar en el propio AD que ha quedado con una
  cuenta de equipo propia.

## 4. Lo que se ha comprobado y está bien

- Los tres playbooks originales (`00`/`01`/`02`) son coherentes entre sí
  y con la guía en cuanto a usuario, colecciones necesarias y orden de
  ejecución.
- `configurar_equipo.sh` es idempotente tal y como dice su cabecera, y su
  tabla `AULA_SUBRED` coincide con los comentarios de `macs.csv`.
- El usuario `ansible_user` del `ansible_bootstrap.zip` y la sección
  `IF02` de `macs.csv` — los dos bugs "concretos y fáciles de arreglar"
  que señalaba el diagnóstico — ya están corregidos en el repositorio.
- `02_harden_ssh.yml` ya incorpora `accept-new` como variable de play, lo
  que evita el bloqueo documentado en el diagnóstico incluso si algún día
  alguien se salta la verificación recomendada (aunque seguir la
  verificación tal y como la explica la guía sigue siendo importante para
  dejar poblado el `known_hosts` real de cara a otros usos manuales).
