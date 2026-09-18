#!/usr/bin/env bash
#
# preparar_comparte_aula_profesor.sh
# Aulas IF01 / IF02 / IF03 — SOLO para el equipo del profesor de cada aula
# (es el único que tiene físicamente la carpeta comparte-aula, en su
# segundo disco). Los equipos de alumnos NO ejecutan este script: ellos
# solo montan el recurso ya compartido — ver 06_montar_comparte_aula_alumnos.yml
#
# Se ejecuta a mano, una vez por aula, en el propio equipo del profesor:
#   sudo ./preparar_comparte_aula_profesor.sh
#
# QUÉ HACE:
#   1. Formatea /dev/sdb en EXT4 (etiqueta DATOS) y lo monta en /datos.
#      Idempotente: si el disco ya está formateado y etiquetado DATOS de
#      una ejecución anterior, NO lo vuelve a borrar.
#   2. Deja /datos con permisos 0777 (a petición expresa: el profesorado
#      necesita poder escribir directamente en la raíz del disco, no solo
#      dentro de comparte-aula).
#   3. Crea /datos/comparte-aula, con ISO y MV dentro, y aplica permisos
#      con ACL POSIX:
#        - comparte-aula (raíz): profesores Y alumnos, lectura+escritura
#          (para que el alumnado también pueda dejar ahí archivos).
#        - ISO y MV:             profesores lectura+escritura,
#                                 alumnos SOLO lectura.
#   4. Instala y configura Samba, publicando [comparte-aula] en la red
#      del aula en modo INVITADO (guest): cualquier equipo que llegue a
#      la red del aula accede SIN usuario ni contraseña, ni falta hacer
#      que esté unido al dominio — pensado a propósito para que un
#      profesor pueda copiar algo desde su portátil personal en caso de
#      urgencia. Samba mapea toda conexión de invitado a una cuenta
#      LOCAL de este equipo (no del dominio), que solo tiene permisos
#      "de alumno" (escritura en comparte-aula, solo lectura en ISO/MV)
#      — igual que cualquier alumno normal accediendo por red.
#      El profesorado sigue teniendo acceso completo de escritura en
#      ISO/MV, pero solo localmente en este equipo (grupo profesores),
#      no a través de este recurso de red.
#
# Variables configurables — edítalas aquí si no coinciden con vuestro AD:
GRUPO_PROFESORES="profesores"
GRUPO_ALUMNOS="alumnos"
CUENTA_INVITADO="invitado-comparte-aula"   # cuenta LOCAL, no de dominio
SAMBA_WORKGROUP="IESMHP"
SAMBA_REALM="IESMHP.LOCAL"
SHARE_NAME="comparte-aula"
DISCO="/dev/sdb"
PARTICION="/dev/sdb1"
PUNTO_MONTAJE="/datos"

set -euo pipefail

if [[ $EUID -ne 0 ]]; then
    echo "Este script tiene que ejecutarse como root (sudo)." >&2
    exit 1
fi

echo "== 1. Comprobando estado de ${PARTICION} =="
ETIQUETA_ACTUAL="$(blkid -o value -s LABEL "${PARTICION}" 2>/dev/null || true)"

if [[ "${ETIQUETA_ACTUAL}" == "DATOS" ]]; then
    echo "   ${PARTICION} ya está formateado y etiquetado DATOS — no se reformatea."
else
    echo "   ${PARTICION} no está preparado todavía. Formateando ${DISCO} desde cero..."
    umount "${PARTICION}" 2>/dev/null || true
    wipefs -a -f "${DISCO}"
    parted -s "${DISCO}" mklabel gpt
    parted -s "${DISCO}" mkpart primary ext4 0% 100%
    udevadm settle
    mkfs.ext4 -F -L DATOS "${PARTICION}"
fi

echo "== 2. Punto de montaje permanente ${PUNTO_MONTAJE} (con soporte ACL) =="
mkdir -p "${PUNTO_MONTAJE}"
UUID_DATOS="$(blkid -o value -s UUID "${PARTICION}")"
if ! grep -q "${UUID_DATOS}" /etc/fstab; then
    echo "UUID=${UUID_DATOS}  ${PUNTO_MONTAJE}  ext4  defaults,acl  0  2" >> /etc/fstab
fi
mountpoint -q "${PUNTO_MONTAJE}" || mount "${PUNTO_MONTAJE}"

echo "== 3. Permisos de ${PUNTO_MONTAJE}: 0777 (a petición expresa) =="
chown root:root "${PUNTO_MONTAJE}"
chmod 0777 "${PUNTO_MONTAJE}"

echo "== 4. Cuenta local de invitado para Samba (${CUENTA_INVITADO}) =="
# Cuenta técnica LOCAL (no de dominio, no aparece en el AD): solo existe
# para que Samba tenga a qué usuario del sistema mapear las conexiones
# de invitado. Sin shell de login ni contraseña utilizable.
if ! id "${CUENTA_INVITADO}" &>/dev/null; then
    useradd --system --no-create-home --shell /usr/sbin/nologin "${CUENTA_INVITADO}"
fi

echo "== 5. Paquetes necesarios (acl, samba) =="
# update no se fuerza a propósito: evita el fallo conocido "Failed to
# update apt cache: unknown reason" por el repositorio HashiCorp roto
# heredado de la maqueta (ver diagnostico-bootstrap-aulas-IF01-IF04.md,
# sección 6). Si falla la instalación, arregla antes ese repo
# (arreglar_repo_apt_hashicorp.yml) o lanza "apt-get update" a mano.
apt-get install -y acl samba

echo "== 6. Creando estructura de carpetas =="
mkdir -p "${PUNTO_MONTAJE}/${SHARE_NAME}" \
         "${PUNTO_MONTAJE}/${SHARE_NAME}/ISO" \
         "${PUNTO_MONTAJE}/${SHARE_NAME}/MV"

echo "== 7. Permisos ACL =="

# comparte-aula (raíz): profesores Y alumnos con escritura (acceso local,
# a través del grupo de dominio); la cuenta local de invitado (acceso por
# red) recibe el mismo nivel que alumnos, ya que es el uso previsto.
chown root:"${GRUPO_PROFESORES}" "${PUNTO_MONTAJE}/${SHARE_NAME}"
chmod 2770 "${PUNTO_MONTAJE}/${SHARE_NAME}"
setfacl -m g:"${GRUPO_PROFESORES}":rwx "${PUNTO_MONTAJE}/${SHARE_NAME}"
setfacl -m g:"${GRUPO_ALUMNOS}":rwx    "${PUNTO_MONTAJE}/${SHARE_NAME}"
setfacl -m u:"${CUENTA_INVITADO}":rwx  "${PUNTO_MONTAJE}/${SHARE_NAME}"
setfacl -m d:g:"${GRUPO_PROFESORES}":rwx,d:g:"${GRUPO_ALUMNOS}":rwx,d:u:"${CUENTA_INVITADO}":rwx,d:o::--- \
    "${PUNTO_MONTAJE}/${SHARE_NAME}"
setfacl -m o::--- "${PUNTO_MONTAJE}/${SHARE_NAME}"

# ISO y MV: profesores escritura; alumnos e invitado SOLO lectura
for carpeta in ISO MV; do
    destino="${PUNTO_MONTAJE}/${SHARE_NAME}/${carpeta}"
    chown root:"${GRUPO_PROFESORES}" "${destino}"
    chmod 2770 "${destino}"
    setfacl -m g:"${GRUPO_PROFESORES}":rwx "${destino}"
    setfacl -m g:"${GRUPO_ALUMNOS}":rx     "${destino}"
    setfacl -m u:"${CUENTA_INVITADO}":rx   "${destino}"
    setfacl -m d:g:"${GRUPO_PROFESORES}":rwx,d:g:"${GRUPO_ALUMNOS}":rx,d:u:"${CUENTA_INVITADO}":rx,d:o::--- "${destino}"
    setfacl -m o::--- "${destino}"
done

echo "== 8. Configurando Samba =="
SMB_CONF="/etc/samba/smb.conf"
[[ -f "${SMB_CONF}.orig" ]] || cp "${SMB_CONF}" "${SMB_CONF}.orig"

MARCA_INICIO_GLOBAL="# BEGIN comparte-aula - autenticacion de dominio"
MARCA_FIN_GLOBAL="# END comparte-aula - autenticacion de dominio"
if ! grep -q "${MARCA_INICIO_GLOBAL}" "${SMB_CONF}"; then
    # Se inserta al FINAL de la sección [global] (no justo debajo de la
    # cabecera), para que nuestros valores ganen a cualquier "workgroup ="
    # u otro parámetro que ya trajera el smb.conf original de la maqueta:
    # en Samba, si un parámetro se repite dentro de la misma sección,
    # gana la última aparición.
    awk -v inicio="${MARCA_INICIO_GLOBAL}" -v fin="${MARCA_FIN_GLOBAL}" \
        -v wg="${SAMBA_WORKGROUP}" -v realm="${SAMBA_REALM}" '
        BEGIN { en_global = 0; insertado = 0 }
        /^\[global\]/ { en_global = 1; print; next }
        /^\[/ {
            if (en_global == 1 && insertado == 0) {
                print inicio
                print "   workgroup = " wg
                print "   realm = " realm
                print "   security = ads"
                print "   idmap config * : backend = sss"
                print "   idmap config * : range = 10000-999999999"
                print "   map to guest = Bad User"
                print fin
                insertado = 1
            }
            en_global = 0
            print
            next
        }
        { print }
        END {
            if (en_global == 1 && insertado == 0) {
                print inicio
                print "   workgroup = " wg
                print "   realm = " realm
                print "   security = ads"
                print "   idmap config * : backend = sss"
                print "   idmap config * : range = 10000-999999999"
                print "   map to guest = Bad User"
                print fin
            }
        }
    ' "${SMB_CONF}" > "${SMB_CONF}.tmp"
    mv "${SMB_CONF}.tmp" "${SMB_CONF}"
fi

MARCA_INICIO_SHARE="# BEGIN comparte-aula - recurso"
MARCA_FIN_SHARE="# END comparte-aula - recurso"
if ! grep -q "${MARCA_INICIO_SHARE}" "${SMB_CONF}"; then
    {
        echo "${MARCA_INICIO_SHARE}"
        echo "[${SHARE_NAME}]"
        echo "   path = ${PUNTO_MONTAJE}/${SHARE_NAME}"
        echo "   browsable = yes"
        echo "   guest ok = yes"
        echo "   guest only = yes"
        echo "   guest account = ${CUENTA_INVITADO}"
        echo "   read only = no"
        echo "   force user = ${CUENTA_INVITADO}"
        echo "   force group = ${GRUPO_PROFESORES}"
        echo "   create mask = 0664"
        echo "   directory mask = 2775"
        echo "${MARCA_FIN_SHARE}"
    } >> "${SMB_CONF}"
fi

testparm -s "${SMB_CONF}" > /dev/null

echo "== 9. Habilitando y arrancando Samba =="
systemctl enable --now smbd
systemctl restart smbd

echo
echo "Listo. Comprueba desde otro equipo del aula (sin usuario/contraseña, invitado):"
echo "  smbclient -N -L //$(hostname)/"
echo
echo "Recuerda:"
echo "  - Cualquier equipo que llegue a la red de esta aula accede a"
echo "    ${SHARE_NAME} como invitado: escritura en la raíz, solo lectura"
echo "    en ISO y MV. No hace falta usuario de dominio ni contraseña."
echo "  - El profesorado sentado en ESTE equipo sigue teniendo escritura"
echo "    completa en ISO/MV (por el ACL local del grupo ${GRUPO_PROFESORES}),"
echo "    pero eso NO se traslada al acceso por red vía Samba: por red,"
echo "    todo el mundo entra como invitado (nivel alumno)."
