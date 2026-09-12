#!/usr/bin/env bash
#
# instalar_ansible_profesor.sh
# ---------------------------------------------------------------------------
# Deja operativo el PC del profesor como nodo de control de Ansible,
# reutilizando los dos usuarios locales que ya trae la maqueta:
#
#   - depinfo        -> administración del equipo (coordinador TIC). Es quien
#                        ejecuta ESTE script.
#   - ansible-admin  -> identidad de automatización: aquí viven la clave SSH,
#                        la carpeta de trabajo y desde aquí se ejecutan los
#                        playbooks. Nadie inicia sesión gráfica con ella.
#
# Los profesores (cuenta de DOMINIO, en turnos de mañana/tarde) NO tienen
# instalación propia de Ansible: se les da permiso de sudo para "convertirse"
# en ansible-admin cuando necesiten gestionar el aula. Se autoriza SOLO a
# los usuarios de dominio concretos listados en DOMAIN_ADMIN_USERS más
# abajo (no un grupo del AD: aquí se autoriza persona a persona).
#
# Ejecutar con sudo (o como root), como depinfo:
#   sudo ./instalar_ansible_profesor.sh
# ---------------------------------------------------------------------------

set -euo pipefail

# ============================ CONFIGURA AQUÍ ================================

# Usuario local de automatización (ya debe existir, viene de la maqueta)
ANSIBLE_ADMIN_USER="ansible-admin"

# Usuarios de DOMINIO (Windows AD) autorizados a gestionar este aula
# concreta (podrán hacer "sudo -iu ansible-admin"). Normalmente 2: el
# profesor de mañana y el de tarde. Usa el nombre tal y como lo resuelve
# SSSD en este equipo - compruébalo antes con, por ejemplo:
#   id profesor.manana
DOMAIN_ADMIN_USERS=("profesor.manana" "profesor.tarde")   # <-- CAMBIA esto

# ==============================================================================

if [[ $EUID -ne 0 ]]; then
    echo "Este script debe ejecutarse con sudo (o como root), como depinfo." >&2
    echo "Uso: sudo ./instalar_ansible_profesor.sh" >&2
    exit 1
fi

log() { echo -e "\n\033[1;32m==> $*\033[0m"; }

if ! id "$ANSIBLE_ADMIN_USER" &>/dev/null; then
    echo "ERROR: no existe el usuario local '$ANSIBLE_ADMIN_USER' en este equipo." >&2
    echo "Este script asume que ya viene creado desde la maqueta." >&2
    exit 1
fi

ANSIBLE_ADMIN_HOME=$(getent passwd "$ANSIBLE_ADMIN_USER" | cut -d: -f6)

log "Actualizando índices de paquetes..."
apt-get update -y

log "Instalando Ansible, sshpass, nmap y dependencias (a nivel de sistema)..."
# nmap hace falta en este equipo (nodo de control) para el bootstrap por red
# de nombre/IP del resto del aula (ver Fase 1 del README y escanear_aula.sh)
apt-get install -y ansible sshpass nmap python3-pip

log "Instalando colecciones de Ansible (como ${ANSIBLE_ADMIN_USER})..."
# ansible.posix -> módulo "authorized_key" que usa 01_bootstrap_keys.yml
sudo -iu "$ANSIBLE_ADMIN_USER" ansible-galaxy collection install ansible.posix community.general

log "Generando par de claves SSH para ${ANSIBLE_ADMIN_USER} (si no existe ya)..."
sudo -iu "$ANSIBLE_ADMIN_USER" bash -s <<'INNER'
set -e
mkdir -p ~/.ssh
chmod 700 ~/.ssh
KEY="$HOME/.ssh/ansible-admin_ed25519"
if [[ -f "$KEY" ]]; then
    echo "  Ya existe $KEY, no se genera de nuevo."
else
    ssh-keygen -t ed25519 -C "ansible-admin@$(hostname)" -f "$KEY" -N ""
    echo "  Clave generada:"
    echo "    privada -> $KEY"
    echo "    pública -> ${KEY}.pub"
fi
INNER

log "Creando carpeta de trabajo ~/ansible-aulas (como ${ANSIBLE_ADMIN_USER})..."
sudo -iu "$ANSIBLE_ADMIN_USER" bash -s <<'INNER'
set -e
mkdir -p ~/ansible-aulas/playbooks ~/ansible-aulas/inventarios

if [[ ! -f ~/ansible-aulas/ansible.cfg ]]; then
cat > ~/ansible-aulas/ansible.cfg <<EOF
[defaults]
inventory           = inventarios
remote_user         = ansible-admin
private_key_file    = $HOME/.ssh/ansible-admin_ed25519
host_key_checking   = True
retry_files_enabled = False

[privilege_escalation]
become        = True
become_method = sudo

[ssh_connection]
# Reutiliza la misma conexión SSH para varias tareas en vez de abrir una
# nueva cada vez: acelera bastante los playbooks contra 20-30 equipos.
pipelining = True
EOF
fi

if [[ ! -f ~/ansible-aulas/inventarios/aula1.ini ]]; then
cat > ~/ansible-aulas/inventarios/aula1.ini <<'EOF'
[aula1]
pc01 ansible_host=192.168.1.101
pc02 ansible_host=192.168.1.102
# ... añade aquí el resto de equipos del aula (incluido el PC del profesor
#     si también se gestiona por Ansible)
EOF
fi
INNER

log "Configurando permiso de sudo para los profesores autorizados de esta aula..."

if [[ ${#DOMAIN_ADMIN_USERS[@]} -eq 0 ]]; then
    echo "ERROR: DOMAIN_ADMIN_USERS está vacío. Añade al menos un usuario de dominio." >&2
    exit 1
fi

# Lista separada por comas para el User_Alias, ej: profesor.manana, profesor.tarde
JOINED_USERS=$(IFS=,; echo "${DOMAIN_ADMIN_USERS[*]}")
JOINED_USERS="${JOINED_USERS//,/, }"

SUDOERS_FILE="/etc/sudoers.d/ansible-aula"
cat > "$SUDOERS_FILE" <<EOF
# Solo estos usuarios de dominio concretos (no un grupo del AD) pueden
# operar como el usuario de automatización ${ANSIBLE_ADMIN_USER}
# (sudo -iu ${ANSIBLE_ADMIN_USER}), sin conocer su contraseña ni usar esa
# cuenta de forma directa. sudo sigue registrando qué profesor concreto
# invocó cada acción.
User_Alias AULA_ADMINS = ${JOINED_USERS}
AULA_ADMINS ALL=(${ANSIBLE_ADMIN_USER}) ALL
EOF
chmod 440 "$SUDOERS_FILE"

# Validar sintaxis ANTES de fiarnos del fichero: un sudoers.d mal escrito
# puede dejar el sudo de TODO el sistema inutilizable.
if ! visudo -cf "$SUDOERS_FILE"; then
    echo "ERROR: sintaxis inválida en $SUDOERS_FILE. Se elimina por seguridad." >&2
    rm -f "$SUDOERS_FILE"
    exit 1
fi

log "Comprobación final:"
sudo -iu "$ANSIBLE_ADMIN_USER" ansible --version
echo
echo "Colecciones instaladas:"
sudo -iu "$ANSIBLE_ADMIN_USER" ansible-galaxy collection list 2>/dev/null | grep -E "posix|general" || true

echo
echo "Resumen:"
echo "  Identidad de automatización : ${ANSIBLE_ADMIN_USER} (${ANSIBLE_ADMIN_HOME})"
echo "  Profesores autorizados      : ${JOINED_USERS}"
echo "  Carpeta de trabajo          : ${ANSIBLE_ADMIN_HOME}/ansible-aulas/"
echo
echo "IMPORTANTE: verifica que esos nombres de usuario son correctos tal y"
echo "como los resuelve este equipo (por ejemplo: id profesor.manana)."
echo "Si no coinciden, edita /etc/sudoers.d/ansible-aula con visudo:"
echo "  sudo visudo -f /etc/sudoers.d/ansible-aula"
echo "Para añadir o quitar un profesor más adelante, edita ese mismo"
echo "fichero (siempre con visudo, para validar la sintaxis) - no hace"
echo "falta volver a ejecutar este script entero."
echo
echo "Uso diario (un profesor autorizado, con su cuenta de dominio):"
echo "  sudo -iu ${ANSIBLE_ADMIN_USER}"
echo "  cd ~/ansible-aulas"
echo "  ansible-playbook -i inventarios/aula1.ini playbooks/..."
