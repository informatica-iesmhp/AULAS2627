# Propuesta: paso de los discos de aula a ZFS (IF01-IF04)

**Fecha:** 2026-09-14
**Contexto:** las maquetas de IF01, IF02 e IF03 ya están desplegadas en todos
los equipos; la maqueta de IF04 ya está creada y lista para desplegar y **no
se puede rehacer**. Por tanto, todo lo que sigue se aplica *después* del
clonado, por Ansible, sobre equipos ya existentes — no es un cambio en la
imagen/maqueta.

**Motivación:** el espacio en disco se agota a mitad de curso. Cada equipo
lo usan dos alumnos distintos (turno de mañana y turno de tarde), y en
algunos módulos cada alumno necesita varias VMs — con el esquema actual
(cada alumno importa su propio `.ova` completo desde la carpeta compartida
`comparte-aula`), en una sola máquina se duplica varias veces el mismo
sistema base. No hay, además, ninguna forma sencilla de limitar cuánto
disco puede llegar a usar cada alumno.

---

## 1. Esquema final de discos, particiones y puntos de montaje

La arquitectura es idéntica en las cuatro aulas — solo cambia la velocidad
real del hardware por debajo. Esto es intencionado: el mismo playbook vale
para las cuatro sin tener que preguntarle a cada máquina qué disco tiene.

### IF04 (disco A = NVMe, disco B = SATA SSD)

| Disco | Partición | Sistema de ficheros | Punto de montaje | Contenido |
|---|---|---|---|---|
| NVMe (A) | EFI/boot | (sin cambios) | `/boot/efi` | arranque |
| NVMe (A) | 1 — 200GB | ext4 | `/` | sistema operativo — **sin tocar** |
| NVMe (A) | 2 — 800GB | ZFS (`rpool_home`) | `/home` | perfiles de alumnos, compresión lz4, cuota por alumno |
| SATA SSD (B) | disco entero | ZFS (`datos`) | `/datos` | `datos/iso` (ISOs) · `datos/plantillas` (VMs base) |

### IF01 / IF02 / IF03 (disco A = SATA SSD, disco B = HDD magnético)

| Disco | Partición | Sistema de ficheros | Punto de montaje | Contenido |
|---|---|---|---|---|
| SSD (A) | EFI/boot | (sin cambios) | `/boot/efi` | arranque |
| SSD (A) | 1 — 200GB | ext4 | `/` | sistema operativo — **sin tocar** |
| SSD (A) | 2 — 800GB | ZFS (`rpool_home`) | `/home` | perfiles de alumnos, compresión lz4, cuota por alumno |
| HDD (B) | disco entero | ZFS (`datos`) | `/datos` | `datos/iso` (ISOs) · `datos/plantillas` (VMs base) |

`/` se queda en ext4 exactamente como está hoy en las cuatro aulas — no se
toca el arranque en ningún momento.

---

## 2. Cómo encajan los perfiles de dominio (SSSD) y las VMs

El disco ZFS nuevo **no sustituye ni reorganiza** el esquema de perfiles de
alumno — es un almacén compartido que cuelga al lado de `/home`, no dentro
de él. SSSD sigue creando `/home/usuario@dominio/` automáticamente al
primer login, exactamente igual que hoy.

Ejemplo con Ana (turno de mañana) y Pedro (turno de tarde) compartiendo el
mismo equipo:

1. Al aprovisionar/reclonar la máquina, un script (pendiente de escribir,
   fuera del alcance de este documento) copia el `.ova` de la plantilla
   una sola vez a `/datos/plantillas/` y lo descomprime — una única copia
   para toda la vida de esa máquina, no una por alumno ni por turno.
2. Ana inicia sesión por la mañana. SSSD le crea
   `/home/ana.garcia@iesmhp.local/` (ZFS, sin cambios respecto a hoy salvo
   el sistema de ficheros de fondo). Registra la plantilla en su propio
   perfil de VirtualBox/VMware (paso único) y crea un **clon enlazado**:
   su disco diferencial vive en su propio home (disco rápido); solo lee
   de `/datos/plantillas/` los bloques que aún no ha modificado.
3. Por la tarde, Pedro hace lo mismo desde su propio perfil, con su propio
   clon enlazado contra la misma plantilla compartida.
4. Las ISOs de instalación (`/datos/iso/`) se referencian directamente
   desde la configuración de la VM, sin copiarlas a cada perfil.

---

## 3. Ventajas respecto a la situación actual (ext4)

- **Cuotas por alumno** (`zfs set userquota@usuario=20G rpool_home`): ext4
  también tiene cuotas de usuario, pero exigen activar contabilidad de
  cuotas, montar con opciones especiales y mantener `quotacheck` aparte.
  En ZFS es un solo comando, sin herramientas adicionales — y ataca
  directamente el problema real (alumnos que se quedan sin espacio).
- **Snapshots y vuelta atrás instantáneos**: ext4 no tiene nada parecido de
  serie (haría falta LVM por debajo, con sus propias limitaciones de
  espacio y rendimiento). Un `zfs snapshot` de `/home` o `/datos` antes de
  una práctica delicada permite volver atrás en segundos si algo se rompe.
- **Compresión transparente** (lz4): sin coste de CPU apreciable, suele
  rondar 1.5-2x en discos de VM y documentos — estira la capacidad real
  de los discos sin que nadie tenga que hacer nada.
- **Checksums de cada bloque**: ext4 no verifica el contenido de los datos.
  ZFS detecta corrupción silenciosa (relevante sobre todo en el disco
  mecánico de las aulas sin SSD) aunque, con un solo disco por pool, no
  pueda autorepararla.
- **Sin `fsck` tras un apagado brusco**: por su diseño de copia en
  escritura, ZFS nunca deja el sistema de ficheros a medias — arranca
  directo tras un corte de luz o un alumno que apaga sin más.
- **Reparto de espacio flexible en `/datos`**: `iso` y `plantillas`
  comparten el espacio libre del pool sin tener que decidir de antemano
  cuántos GB le tocan a cada una.

**Lo que NO es mérito de ZFS**: los clones enlazados de VM los da el propio
hipervisor (VirtualBox/VMware); funcionarían igual sobre ext4. Lo que ZFS
aporta encima es que esos discos diferenciales, allá donde vivan, salen
comprimidos y con cuota.

---

## 4. Advertencias y contrapartidas

- **RAM del ARC**: ZFS reserva por defecto hasta el 50% de la RAM como
  caché. En equipos que también corren VMs hay que caparlo explícitamente
  (por ejemplo, 2-4GB) en `/etc/modprobe.d/zfs.conf`
  (`options zfs zfs_arc_max=4294967296`) para no quitarle memoria a las
  VMs. **Pendiente de añadir como playbook aparte.**
- **Sin redundancia**: cada pool vive en un único disco. El checksum avisa
  de corrupción, pero no puede repararla — para eso haría falta un mirror,
  y aquí no hay un segundo disco libre para ello.
- **`/home` no está realmente vacío**: aunque no haya alumnos todavía,
  contiene los perfiles de `depinfo` y `ansible-admin` — este último con
  la clave SSH que permite la gestión por Ansible sin contraseña. Los
  playbooks de esta entrega hacen backup y restauran ambos automáticamente,
  pero conviene verificarlo a mano la primera vez en cada aula.
- **`ansible_remote_tmp`**: imprescindible fijarlo fuera de `/home` antes
  de ejecutar `04_migrar_home_zfs.yml` (ver cabecera del propio fichero) —
  si no, Ansible pierde su directorio de trabajo a mitad de la migración.
- **Probar siempre en un equipo piloto** con `--limit` antes de extender
  cualquiera de los tres playbooks a un aula entera.

---

## 5. Playbooks entregados

Continúan la numeración ya existente en el repo
(`00_regenerate_identity.yml`, `01_bootstrap_keys.yml`,
`02_harden_ssh.yml`, `03_reunir_dominio.yml`):

- **`04_migrar_home_zfs.yml`** — migra `/home` de ext4 a ZFS, con backup y
  restauración automática de `depinfo` y `ansible-admin`. Idempotente.
- **`05_migrar_datos_zfs.yml`** — migra el segundo disco a ZFS con
  datasets `iso` y `plantillas`, mismo punto de montaje `/datos`. Identifica
  el disco por descarte (el que no es el del sistema), no por lo que haya
  montado en `/datos` — así funciona igual si ese disco ya tiene `/datos`
  en ext4, si tiene particiones viejas de Windows sin tocar, o si viene
  totalmente sin particionar. Si no encuentra exactamente un segundo disco
  candidato, para sin tocar nada en vez de adivinar. Idempotente.
- **`06_aplicar_cuotas_home.yml`** — aplica `userquota` por alumno
  detectado en `/home`. Pensado para relanzarse periódicamente a medida
  que entran alumnos nuevos; admite cuotas especiales por usuario vía
  `alumnos_cuota`.

Los tres asumen el grupo de inventario `aula` — ajustar el `hosts:` si el
inventario real usa otro nombre de grupo.

**Ninguno de los tres se ha probado todavía contra un equipo real** —
igual que ocurrió en su día con `03_reunir_dominio.yml`, solo se ha
verificado la sintaxis y la lógica.

---

## 6. Tareas adicionales (para añadir al listado de tareas del repo)

- [ ] Añadir `ansible_remote_tmp: /tmp/.ansible-remote` a `group_vars/all.yml`
      antes de ejecutar nada de esta tanda.
- [ ] Verificar en un equipo piloto de IF04 y uno de aula con HDD qué hay
      exactamente en `/home` antes de migrar (debería ser solo `depinfo` y
      `ansible-admin`).
- [ ] Antes de lanzar `05_migrar_datos_zfs.yml` a un aula entera, pasar
      primero una auditoría de solo lectura (`lsblk`, `fdisk -l` o
      `parted --list` por Ansible) sobre todos sus equipos, para saber de
      antemano si hay discos con particiones de Windows sin tocar, discos
      sin particionar, o algo inesperado (más o menos de 2 discos por
      equipo) antes de borrar nada a ciegas.
- [ ] Ejecutar `05_migrar_datos_zfs.yml` primero (menor riesgo), con
      `--limit` en un equipo de prueba por tipo de aula.
- [ ] Verificar `/datos` tras la migración (ISOs accesibles, datasets
      creados).
- [ ] Ejecutar `04_migrar_home_zfs.yml` en el mismo equipo de prueba y
      comprobar que `ansible-admin` sigue conectando por clave SSH sin
      `--ask-pass`.
- [ ] Extender ambos playbooks a un aula completa y, si todo va bien, a
      las cuatro.
- [ ] Escribir el playbook de tuning del ARC de ZFS (`zfs_arc_max`),
      pendiente, mencionado en la sección de advertencias.
- [ ] Escribir el script que copia y descomprime el `.ova` de cada
      plantilla en `/datos/plantillas/` la primera vez que se aprovisiona
      un equipo — no incluido en esta entrega.
- [ ] Ejecutar `06_aplicar_cuotas_home.yml` una vez los alumnos empiecen a
      tener cuenta activa, ajustando `cuota_por_defecto` según el módulo.
- [ ] Actualizar `00_despliegue_aula_README.md` con el nuevo esquema de
      discos de este documento.

---

## 7. Pasos para subirlo al repositorio de GitHub

```bash
cd ~/ansible-aulas/repo          # el clon local de informatica-iesmhp/AULAS2627
git checkout -b feature/discos-zfs

mkdir -p Maqueta-Mint-2627/zfs
# copiar aquí los cuatro ficheros descargados:
#   04_migrar_home_zfs.yml
#   05_migrar_datos_zfs.yml
#   06_aplicar_cuotas_home.yml
#   propuesta-zfs-discos-aula-IF01-IF04.md

git add Maqueta-Mint-2627/zfs/
git commit -m "Añade migración de /home y /datos a ZFS con cuotas por alumno"
git push origin feature/discos-zfs
```

Después, abrir un Pull Request en GitHub contra `main` en vez de subirlo
directamente — según lo ya documentado en el repo, los cambios normalmente
los revisa/aplica quien tiene permisos de escritura (habitualmente Víctor)
antes de fusionarlos.
