#!/usr/bin/env bash
#
# 0-ConfiguracionInicial.sh
# -------------------------------------------------------------------
# Configuración inicial de CADA usuario (se ejecuta COMO el usuario,
# NO como root). Forma parte de la carpeta `rolesUsuario`.
#
# Qué hace:
#   PARTE 1 — SSH "auto" (login a sí mismo):
#     1. Asegura que el usuario tiene un par de claves SSH ed25519
#        (~/.ssh/id_ed25519). Si no existe, lo crea sin passphrase.
#     2. Asegura que el usuario puede conectarse a SÍ MISMO con esa
#        clave: añade su clave pública a ~/.ssh/authorized_keys y
#        registra el host en ~/.ssh/known_hosts.
#     3. Verifica la conexión (ssh localhost "exit 0").
#   PARTE 2 — Docker rootless para ESTE usuario:
#     4. Da por hecha la parte de sistema (rol roles/Docker como root:
#        paquetes, repo, daemon de sistema desactivado). Completa lo que
#        cabe en permisos del usuario (equivale al rol DockerRootless):
#        subuid/subgid (escritos A FICHERO, válido también para usuarios del
#        DOMINIO; delega en el helper del rol Docker si está) + lingering,
#        instala el daemon rootless del usuario (dockerd-rootless-setuptool.sh install),
#        exporta DOCKER_HOST en ~/.bashrc y arranca docker.service --user.
#        Corrige el síntoma típico de un usuario NUEVO:
#          "failed to connect to the docker API at unix:///var/run/docker.sock"
#        (el cliente apunta al daemon de SISTEMA, desactivado, en vez de al
#        socket rootless /run/user/<uid>/docker.sock).
#
# Idempotente: relanzarlo no rompe nada ni duplica entradas.
#
# Uso:
#   bash 0-ConfiguracionInicial.sh          # como el usuario actual
# -------------------------------------------------------------------
set -u

# ---- No ejecutar como root -----------------------------------------
if [ "$(id -u)" -eq 0 ]; then
    echo "[ERR] Este script debe ejecutarse como el USUARIO, no como root." >&2
    echo "      (configura el ~/.ssh del usuario que lo lanza)." >&2
    exit 1
fi

USUARIO="$(id -un)"
HOME_DIR="${HOME:-/home/$USUARIO}"
SSH_DIR="$HOME_DIR/.ssh"
CLAVE_PRIV="$SSH_DIR/id_ed25519"
CLAVE_PUB="$CLAVE_PRIV.pub"
AUTH_KEYS="$SSH_DIR/authorized_keys"
KNOWN="$SSH_DIR/known_hosts"

log()  { echo "[INFO] $*"; }
ok()   { echo "[OK]   $*"; }
warn() { echo "[WARN] $*" >&2; }
err()  { echo "[ERR]  $*" >&2; }

log "Configuración inicial para el usuario '$USUARIO' (home: $HOME_DIR)"

# ---- 1. Directorio ~/.ssh ------------------------------------------
GRUPO="$(id -gn)"

if [ ! -d "$SSH_DIR" ]; then
    if ! mkdir -p "$SSH_DIR" 2>/dev/null; then
        # El home puede pertenecer a root; intentamos crearlo con sudo.
        warn "No se pudo crear $SSH_DIR como usuario; reintentando con sudo…"
        sudo mkdir -p "$SSH_DIR" && sudo chown "$USUARIO:$GRUPO" "$SSH_DIR" \
            || { err "No se pudo crear $SSH_DIR."; exit 1; }
    fi
    log "Creado $SSH_DIR"
fi

# Asegurar que el USUARIO es propietario de ~/.ssh y de su contenido.
# En equipos ya provisionados, authorized_keys/.ssh pueden haber quedado
# como root:root (el instalador escribió las claves como root sin chown),
# y entonces el usuario no puede ni hacer chmod ni escribir su clave.
NEEDFIX=0
[ -e "$SSH_DIR" ]   && [ ! -O "$SSH_DIR" ]   && NEEDFIX=1
[ -e "$AUTH_KEYS" ] && [ ! -O "$AUTH_KEYS" ] && NEEDFIX=1
if [ "$NEEDFIX" -eq 1 ]; then
    warn "$SSH_DIR no pertenece a '$USUARIO' (seguramente root). Corrigiendo propiedad…"
    if command -v sudo >/dev/null 2>&1; then
        if sudo chown -R "$USUARIO:$GRUPO" "$SSH_DIR"; then
            ok "Propiedad de $SSH_DIR reasignada a $USUARIO:$GRUPO (contenido intacto)."
        else
            err "No se pudo cambiar la propiedad de $SSH_DIR."
            err "Hazlo manualmente:  sudo chown -R $USUARIO:$GRUPO $SSH_DIR"
            exit 1
        fi
    else
        err "Falta 'sudo' y $SSH_DIR no es tuyo. Pide a un administrador:"
        err "  chown -R $USUARIO:$GRUPO $SSH_DIR"
        exit 1
    fi
fi

chmod 700 "$SSH_DIR"

# ---- 2. Par de claves ed25519 --------------------------------------
if [ -f "$CLAVE_PRIV" ]; then
    ok "Ya existe la clave privada ($CLAVE_PRIV); no se regenera."
else
    log "No existe clave; generando par ed25519 sin passphrase…"
    if ssh-keygen -t ed25519 -C "$USUARIO@$(hostname)" -f "$CLAVE_PRIV" -N "" >/dev/null; then
        ok "Clave generada: $CLAVE_PRIV"
    else
        err "Fallo al generar la clave SSH."
        exit 1
    fi
fi
chmod 600 "$CLAVE_PRIV" 2>/dev/null || true
chmod 644 "$CLAVE_PUB"  2>/dev/null || true

# ---- 3. authorized_keys (login a sí mismo) -------------------------
PUB_CONTENT="$(cat "$CLAVE_PUB")"
touch "$AUTH_KEYS"
chmod 600 "$AUTH_KEYS"
if grep -qF "$PUB_CONTENT" "$AUTH_KEYS" 2>/dev/null; then
    ok "La clave pública ya está en authorized_keys."
else
    printf '%s\n' "$PUB_CONTENT" >> "$AUTH_KEYS"
    ok "Clave pública añadida a authorized_keys."
fi

# ---- 4. known_hosts: registrar localhost ---------------------------
touch "$KNOWN"
chmod 644 "$KNOWN"
for destino in localhost 127.0.0.1 "$(hostname)"; do
    [ -z "$destino" ] && continue
    if ssh-keygen -F "$destino" >/dev/null 2>&1; then
        continue   # ya está en known_hosts
    fi
    if ssh-keyscan -t ed25519,rsa "$destino" 2>/dev/null >> "$KNOWN"; then
        log "Host '$destino' añadido a known_hosts."
    else
        warn "No se pudo escanear '$destino' (¿servicio ssh no arrancado?)."
    fi
done

# ---- 5. Verificar conexión a sí mismo ------------------------------
log "Verificando conexión SSH a localhost…"
SSH_OK=0
if ssh -o BatchMode=yes \
       -o StrictHostKeyChecking=accept-new \
       -o ConnectTimeout=5 \
       -i "$CLAVE_PRIV" \
       localhost "exit 0" 2>/dev/null; then
    ok "Conexión a sí mismo correcta (ssh localhost)."
    SSH_OK=1
else
    warn "No se pudo conectar por SSH a localhost con la clave."
    warn "Causas habituales: el servicio 'ssh' (sshd) no está instalado o"
    warn "no está arrancado en este equipo. La clave y authorized_keys SÍ"
    warn "quedaron configurados; la conexión funcionará cuando sshd esté activo."
fi

# ====================================================================
# PARTE 2 — Docker rootless para ESTE usuario
# --------------------------------------------------------------------
# Equivale al rol `rolesUsuario/roles/DockerRootless`, pero en bash y
# autosuficiente: si faltan subuid/subgid o el lingering (cosas que
# normalmente deja `roles/Docker` como root) los completa con sudo.
#
# Por qué un usuario NUEVO falla con
#   "failed to connect to the docker API at unix:///var/run/docker.sock":
# el daemon de SISTEMA está desactivado a propósito (modo rootless), así
# que el cliente debe apuntar a /run/user/<uid>/docker.sock vía
# DOCKER_HOST. Si el usuario nunca completó esta parte, no tiene daemon
# de usuario ni DOCKER_HOST y el cliente cae al socket de sistema
# inexistente. Esta sección lo corrige.
# ====================================================================
log "PARTE 2: configurando Docker rootless para '$USUARIO'…"

UID_ACT="$(id -u)"
DOCKER_SOCK="/run/user/$UID_ACT/docker.sock"
XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$UID_ACT}"
export XDG_RUNTIME_DIR
export DBUS_SESSION_BUS_ADDRESS="unix:path=$XDG_RUNTIME_DIR/bus"
export PATH="/usr/bin:/sbin:/usr/sbin:$PATH"
DOCKER_OK=0

# ---- 2.1 Prerrequisito de sistema (lo deja el rol roles/Docker) ----
if ! command -v dockerd-rootless-setuptool.sh >/dev/null 2>&1; then
    err "Falta la instalación de SISTEMA de Docker (no existe"
    err "'dockerd-rootless-setuptool.sh'). Aplícala primero como root:"
    err "  cd /opt/IAC-IESMHP/Ubuntu/ansible && \\"
    err "  sudo ansible-playbook -i localhost, --connection=local roles.yaml --tags docker"
    err "y vuelve a lanzar este script."
    # La PARTE 1 (SSH) sí quedó hecha; salimos con aviso (2), no error duro.
    exit 2
fi

# ---- 2.2 subuid/subgid del usuario ---------------------------------
# Se asignan escribiéndolos A FICHERO (/etc/subuid|subgid), NO con
# `usermod --add-subuids`: usermod solo conoce /etc/passwd y FALLA con
# usuarios del DOMINIO (viven en SSSD). Si el rol roles/Docker dejó su helper
# (/usr/local/sbin/iac-docker-rootless-prep.sh — idempotente, hace subuid A
# FICHERO + lingering), se delega en él; si no, se hace inline aquí (subuid;
# el lingering lo cubre el paso 2.3).
PREP_HELPER=/usr/local/sbin/iac-docker-rootless-prep.sh

# Fallback inline: calcula el siguiente rango libre (sin solapar) y lo añade a
# ambos ficheros vía sudo. Mismo algoritmo que el helper del rol.
asignar_subid_fichero() {
    local maxend=100000 f s c end linea
    for f in /etc/subuid /etc/subgid; do
        [ -f "$f" ] || continue
        while IFS=: read -r _ s c; do
            [ -n "$s" ] && [ -n "$c" ] || continue
            case "$s" in *[!0-9]*) continue ;; esac
            case "$c" in *[!0-9]*) continue ;; esac
            end=$(( s + c ))
            [ "$end" -gt "$maxend" ] && maxend="$end"
        done < "$f"
    done
    linea="$USUARIO:$maxend:65536"
    for f in /etc/subuid /etc/subgid; do
        grep -q "^$USUARIO:" "$f" 2>/dev/null && continue
        printf '%s\n' "$linea" | sudo tee -a "$f" >/dev/null || return 1
    done
    return 0
}

NEED_SUBID=0
grep -q "^$USUARIO:" /etc/subuid 2>/dev/null || NEED_SUBID=1
grep -q "^$USUARIO:" /etc/subgid 2>/dev/null || NEED_SUBID=1
if [ "$NEED_SUBID" -eq 1 ]; then
    warn "El usuario '$USUARIO' no tiene rango subuid/subgid (el daemon"
    warn "rootless no arranca sin ellos). Asignándolo (a fichero, vía sudo)…"
    if ! command -v sudo >/dev/null 2>&1; then
        err "Falta 'sudo' para asignar subuid/subgid. Hazlo como admin:"
        err "  echo '$USUARIO:100000:65536' | sudo tee -a /etc/subuid /etc/subgid"
        exit 3
    fi
    if [ -x "$PREP_HELPER" ]; then
        # Helper del rol Docker: subuid A FICHERO + lingering (cubre 2.3).
        if sudo "$PREP_HELPER" "$USUARIO"; then
            ok "subuid/subgid (+ lingering) asignados vía helper del rol Docker."
        else
            err "El helper $PREP_HELPER falló. Revisa /etc/subuid y /etc/subgid."
            exit 3
        fi
    elif asignar_subid_fichero; then
        ok "subuid/subgid asignados a $USUARIO (a fichero)."
    else
        err "No se pudieron asignar subuid/subgid. Hazlo como admin:"
        err "  echo '$USUARIO:100000:65536' | sudo tee -a /etc/subuid /etc/subgid"
        exit 3
    fi
else
    ok "El usuario ya tiene rango subuid/subgid."
fi

# ---- 2.3 Lingering (daemon de usuario arranca en boot, crea /run/user)
if [ ! -e "/var/lib/systemd/linger/$USUARIO" ]; then
    log "Habilitando lingering del usuario (sudo loginctl enable-linger)…"
    if command -v sudo >/dev/null 2>&1 && sudo loginctl enable-linger "$USUARIO"; then
        ok "Lingering habilitado para $USUARIO."
    else
        warn "No se pudo habilitar lingering. El daemon rootless solo"
        warn "estará activo mientras el usuario tenga sesión abierta."
    fi
else
    ok "Lingering ya habilitado para $USUARIO."
fi

# Esperar a que el gestor systemd de usuario monte $XDG_RUNTIME_DIR.
if [ ! -d "$XDG_RUNTIME_DIR" ]; then
    log "Esperando a que arranque el gestor systemd de usuario ($XDG_RUNTIME_DIR)…"
    for _ in $(seq 1 10); do
        [ -d "$XDG_RUNTIME_DIR" ] && break
        sleep 1
    done
fi
if [ ! -d "$XDG_RUNTIME_DIR" ]; then
    warn "No existe $XDG_RUNTIME_DIR; 'systemctl --user' puede fallar en"
    warn "esta ejecución. Suele resolverse al abrir una sesión nueva."
fi

# ---- 2.3b Módulo nf_tables (prerequisito de dockerd-rootless-setuptool.sh) --
# Sin nf_tables cargado, el setuptool de abajo ABORTA con "Missing system
# requirements ... modprobe nf_tables" (iptables-nft lo necesita). Lo deja
# cargado el rol Docker (modules-load.d) en el primer arranque, pero al lanzar
# este script a mano en un equipo recién instalado puede no estarlo todavía.
# Lo cargamos vía sudo (idempotente; modprobe no falla si ya está cargado).
if ! lsmod 2>/dev/null | grep -qw nf_tables; then
    log "Cargando el módulo nf_tables (prerequisito de Docker rootless)…"
    if command -v sudo >/dev/null 2>&1 && sudo modprobe nf_tables 2>/dev/null; then
        ok "Módulo nf_tables cargado."
    else
        warn "No se pudo cargar nf_tables; 'dockerd-rootless-setuptool.sh"
        warn "install' puede fallar con 'Missing system requirements'."
    fi
else
    ok "El módulo nf_tables ya está cargado."
fi

# ---- 2.4 Instalar el daemon rootless del usuario (idempotente) -----
USER_UNIT="$HOME_DIR/.config/systemd/user/docker.service"
if [ -f "$USER_UNIT" ]; then
    ok "Ya existe la unit de usuario docker.service; no se reinstala."
else
    log "Instalando Docker rootless (dockerd-rootless-setuptool.sh install)…"
    if dockerd-rootless-setuptool.sh install; then
        ok "Docker rootless instalado para $USUARIO."
    else
        err "Falló 'dockerd-rootless-setuptool.sh install'. Revisa que el"
        err "gestor systemd de usuario esté activo (sesión/lingering)."
        exit 3
    fi
fi

# ---- 2.5 DOCKER_HOST + PATH en ~/.bashrc (bloque idempotente) ------
BASHRC="$HOME_DIR/.bashrc"
MARK_INI="# >>> IAC-IESMHP DockerRootless >>>"
MARK_FIN="# <<< IAC-IESMHP DockerRootless <<<"
touch "$BASHRC"
if grep -qF "$MARK_INI" "$BASHRC" 2>/dev/null; then
    ok "El bloque DOCKER_HOST ya está en ~/.bashrc."
else
    {
        printf '%s\n' "$MARK_INI"
        printf '%s\n' "# Cliente docker apunta al daemon rootless del usuario"
        printf '%s\n' 'export PATH=/usr/bin:$PATH'
        printf '%s\n' "export DOCKER_HOST=unix://$DOCKER_SOCK"
        printf '%s\n' "$MARK_FIN"
    } >> "$BASHRC"
    ok "Añadido DOCKER_HOST=$DOCKER_SOCK a ~/.bashrc."
fi
# Exportarlo también en ESTA ejecución para la verificación de abajo.
export DOCKER_HOST="unix://$DOCKER_SOCK"

# ---- 2.6 Habilitar y arrancar docker.service del usuario -----------
log "Habilitando y arrancando docker.service (--user)…"
systemctl --user enable docker.service >/dev/null 2>&1 \
    || warn "No se pudo hacer 'enable' de docker.service (usuario)."
if systemctl --user start docker.service 2>/dev/null; then
    ok "docker.service (usuario) arrancado."
else
    warn "No se pudo arrancar docker.service del usuario en esta sesión."
fi

# ---- 2.7 Verificación final ----------------------------------------
log "Verificando el daemon rootless (docker info)…"
if docker info >/dev/null 2>&1; then
    ok "Docker rootless OK (daemon respondiendo en $DOCKER_SOCK)."
    DOCKER_OK=1
else
    warn "docker info aún falla. La instalación quedó hecha; abre un"
    warn "terminal NUEVO (para que ~/.bashrc exporte DOCKER_HOST) o"
    warn "reinicia la sesión y prueba:  docker run --rm hello-world"
fi

# ====================================================================
# Resumen y código de salida
# ====================================================================
if [ "$SSH_OK" -eq 1 ] && [ "$DOCKER_OK" -eq 1 ]; then
    echo "Correcto"
    exit 0
fi
[ "$SSH_OK" -ne 1 ]    && warn "PARTE 1 (SSH): pendiente (sshd no disponible)."
[ "$DOCKER_OK" -ne 1 ] && warn "PARTE 2 (Docker): instalado pero sin verificar; reabre sesión."
exit 2
