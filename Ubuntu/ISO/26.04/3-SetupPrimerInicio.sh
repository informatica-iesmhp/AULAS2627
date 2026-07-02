#!/bin/bash

#"set -e" significa que el script se detendrá si ocurre un error
set -e # lo desactivamos para que no se pare en errores de 

VERSIONSCRIPT="22.24-20260520"       #Versión del script
SCRIPT3=$(basename "$0")
echo "$SCRIPT3 (vs$VERSIONSCRIPT)"
#Nos quedamos solo con el nombre del script sin ruta

# Variables comunes del proyecto (REPO, DISTRO, RAIZSCRIPTS, RAIZLOG,
# RAIZDISTRO, RAIZANSIBLE, versionDISTRO, rutas de sub-scripts...). Único
# punto de definición: comun.sh (mismo directorio que este script).
_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$_DIR/comun.sh"

SCRIPT4nombreip="$SCRIPT_NOMBREIP"
SCRIPT5ansible="$SCRIPT_AUTOANSIBLE"

VERLOGSCRIPT="/home/usuario/verLog.sh"

#Fichero de log del servicio de primer arranque
# Un UNICO log: 3-SetupPrimerInicio.sh.log. Recoge TODO lo que lanza el
# servicio (este script + NombreIP.sh + Auto-Ansible.sh + ansible-playbook +
# 4-Comprobaciones.sh). Cada linea se antepone con la hora y se graba al
# instante (consumidor por linea, sin buffer de tee que se pierda) y un
# 'sync' periodico vacia el page cache cada 3 s. Objetivo: si una maquina
# FISICA con GPU NVIDIA se congela compilando/insertando el modulo del driver
# (cuelgue duro del kernel), el log queda en disco hasta la ultima linea
# escrita -> esa linea identifica el paso que provoco el cuelgue.
# (2026-05-18: se elimina 5-PrimerArranque.log; era una copia identica de
#  este fichero — el mismo 'tee' escribia ambos — y solo anadia ruido.)
FLOG="$RAIZLOG/$SCRIPT3.log"
mkdir -p "$RAIZLOG"

# Guardamos stdout/stderr originales: los captura el journal de systemd
# (StandardOutput=journal). Seguimos enviando copia al journal sin volver a
# anexar al fichero (ver bug 2026-05-15 "log duplicado").
exec 3>&1 4>&2

# Consumidor de log: antepone hora a cada linea, la graba en los DOS ficheros
# reabriendolos por linea (flush inmediato a kernel) y la reenvia al journal.
exec > >(
    while IFS= read -r _linea; do
        printf '%(%H:%M:%S)T %s\n' -1 "$_linea" | tee -a "$FLOG" >&3
    done
) 2>&1

# Flush periodico del page cache: un cuelgue duro del kernel (tipico al
# insertar el modulo NVIDIA en hardware real) pierde como mucho los ~3 s
# ultimos de log en vez de todo lo no escrito a disco.
( while :; do sync; sleep 3; done ) &
_SYNC_PID=$!

# Al terminar (fin normal, reboot del rol nvidia, parada del servicio, senal):
# dejar marca en el log, parar el sync periodico y forzar un sync final.
_cerrar_log() {
    local _rc=$?
    echo -e "\033[33m=== $SCRIPT3 FINALIZA/INTERRUMPIDO (rc=$_rc): $(date) ===\033[0m"
    kill "$_SYNC_PID" 2>/dev/null || true
    sleep 0.3            # que el consumidor procese y grabe la ultima linea
    sync
}
trap _cerrar_log EXIT
trap 'exit 143' TERM INT HUP

# Envia un mensaje de progreso a TODAS las sesiones abiertas:
#   - graficas Wayland : notify-send (popup) + zenity (ventana), usando
#                        XDG_RUNTIME_DIR + WAYLAND_DISPLAY del usuario.
#   - graficas X11     : zenity con DISPLAY.
#   - SSH / consola    : texto por su terminal (wall).
# La version vieja solo funcionaba en X11 (pasaba DISPLAY + DBUS de
# gnome-session, que en Wayland no sirve). Patron tomado de
# utiles/pruebaMensaje.sh. Best-effort: nunca aborta el script (set -e).
mostrar_mensaje() {
    local MENSAJE="${1:-hola mundo}"
    local TIEMPO="${2:-3000000}"            # se pasa tal cual a zenity --timeout
    local IP MAC PIE MENSAJE2 TITULO
    IP=$(hostname -I 2>/dev/null | awk '{print $1}')
    MAC=$(ip link show 2>/dev/null | awk '/ether/ {print $2}' | head -n 1)
    PIE="[ $MAC ]  -  $(hostname)\n$FLOG\n         ó\n$VERLOGSCRIPT"
    MENSAJE2="$MENSAJE\n\n$PIE"
    TITULO="Actualizando ($IP)"

    # --- 1) Sesiones graficas (Wayland y X11) ---------------------------
    local sid usuario uid tipo disp wdisp
    while read -r sid; do
        [[ -z "$sid" ]] && continue
        tipo=$(loginctl show-session "$sid" -p Type --value 2>/dev/null)
        usuario=$(loginctl show-session "$sid" -p Name --value 2>/dev/null)
        uid=$(loginctl show-session "$sid" -p User --value 2>/dev/null)
        [[ -z "$usuario" || -z "$uid" ]] && continue

        if [[ "$tipo" == "wayland" ]]; then
            # Popup de notificacion (mas estable en Wayland)
            sudo -u "$usuario" \
                DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$uid/bus" \
                notify-send -u critical "$TITULO" "$MENSAJE2" 2>/dev/null || true
            # Ventana zenity sobre el socket Wayland del usuario
            wdisp=$(ls /run/user/"$uid"/wayland-* 2>/dev/null \
                    | head -n1 | xargs -r basename 2>/dev/null)
            if [[ -n "$wdisp" ]]; then
                sudo -u "$usuario" \
                    XDG_RUNTIME_DIR="/run/user/$uid" \
                    WAYLAND_DISPLAY="$wdisp" \
                    zenity --info --text="$MENSAJE2" --title="$TITULO" \
                           --width=350 --timeout="$TIEMPO" 2>/dev/null &
            fi
        elif [[ "$tipo" == "x11" ]]; then
            disp=$(loginctl show-session "$sid" -p Display --value 2>/dev/null)
            [[ -z "$disp" ]] && disp=":0"
            sudo -u "$usuario" DISPLAY="$disp" \
                zenity --info --text="$MENSAJE2" --title="$TITULO" \
                       --width=350 --timeout="$TIEMPO" 2>/dev/null &
        fi
    done < <(loginctl list-sessions --no-legend 2>/dev/null | awk '{print $1}')

    # --- 2) Sesiones SSH / consola (texto por su terminal) --------------
    # `wall` difunde a TODOS los terminales abiertos (pts de SSH y consolas
    # locales); como root ignora el `mesg n` del usuario.
    if command -v wall >/dev/null 2>&1; then
        printf '%b\n' "=== IAC-IESMHP ===\n$MENSAJE\n\n$PIE" \
            | wall 2>/dev/null || true
    fi
    return 0
}

echoverde() {
    local MENSAJE_EN_GUI="${3:-'N'}"
    echo -e "\033[32m$1\033[0m"
    if [[ "$MENSAJE_EN_GUI" == "S" ]]; then
        mostrar_mensaje "$1"
    fi
}
echorojo() {
    echo -e "\033[31m$1\033[0m"
    mostrar_mensaje "ERROR!!! :  $1"
}
echoamarillo() {
    local MENSAJE_EN_GUI="${3:-'N'}"
    echo -e "\033[33m$1\033[0m"
    if [[ "$MENSAJE_EN_GUI" == "S" ]]; then
        mostrar_mensaje "$1"
    fi
}

echo "tail -f $FLOG" > $VERLOGSCRIPT
chmod +x $VERLOGSCRIPT

echoverde "=== $SCRIPT3 (vs$VERSIONSCRIPT) iniciado: $(date) ==="
echoverde "DISTRO=$DISTRO  versionDISTRO=$versionDISTRO  RAIZLOG=$RAIZLOG"
echoverde "RAIZDISTRO=$RAIZDISTRO  RAIZANSIBLE=$RAIZANSIBLE"
_IP_BOOT=$(hostname -I 2>/dev/null | awk '{print $1}') || _IP_BOOT="desconocida"
_MAC_BOOT=$(ip link show 2>/dev/null | awk '/ether/ {print $2}' | head -1) || _MAC_BOOT="desconocida"
echoverde "IP=$_IP_BOOT  MAC=$_MAC_BOOT  hostname=$(hostname)"
echoverde "Kernel: $(uname -r)"

echoverde "Lanzando mensaje en sesiones gráficas activas..." 
mostrar_mensaje "Actualizando: (SSH no disponible)" 
echoverde "Ejecutando actualización del sistema en primer arranque en 5sg.." 
sleep 5 # Espera 5 segundos para asegurar que el sistema esté completamente arrancado

echoverde "Ajustando la hora del sistema..."
timedatectl set-timezone Europe/Madrid 2>/dev/null \
    || echoamarillo "No se pudo fijar la zona horaria con timedatectl."
# Servidores NTP por defecto (NTP= vacío → FallbackNTP de timesyncd).
timedatectl set-ntp true 2>/dev/null || true
systemctl restart systemd-timesyncd 2>/dev/null || true
# Esperar a que NTP confirme sincronización (máx ~30 s) antes de continuar.
for i in $(seq 1 15); do
    [ "$(timedatectl show -p NTPSynchronized --value 2>/dev/null)" = "yes" ] && break
    sleep 2
done
if [ "$(timedatectl show -p NTPSynchronized --value 2>/dev/null)" = "yes" ]; then
    echoverde "Hora sincronizada por NTP: $(date)"
else
    # Fallback HTTP: en las aulas el UDP 123 (NTP) suele estar filtrado, pero el
    # TCP 443 (HTTPS) no. Leemos la hora de la cabecera «Date:» de una petición
    # HTTPS: viene en GMT, así que `date -s` la interpreta y la convierte sola a
    # Europe/Madrid (zona ya fijada). `hwclock --systohc` propaga al RTC.
    echoamarillo "NTP no confirmó sincronización (¿UDP 123 bloqueado?); intento por HTTP..."
    HORA_HTTP=""
    for url in https://www.google.com https://github.com https://www.cloudflare.com; do
        if command -v curl >/dev/null 2>&1; then
            HORA_HTTP="$(curl -sI --max-time 10 "$url" 2>/dev/null \
                | grep -i '^[[:space:]]*date:' | head -n1 \
                | sed -E 's/^[[:space:]]*[Dd]ate:[[:space:]]*//; s/\r$//' || true)"
        else
            HORA_HTTP="$(wget -SqO /dev/null --timeout=10 "$url" 2>&1 \
                | grep -i '^[[:space:]]*date:' | head -n1 \
                | sed -E 's/^[[:space:]]*[Dd]ate:[[:space:]]*//; s/\r$//' || true)"
        fi
        if [ -n "$HORA_HTTP" ] && date -s "$HORA_HTTP" >/dev/null 2>&1; then
            hwclock --systohc 2>/dev/null || true
            echoverde "Hora sincronizada por HTTP ($url): $(date)"
            break
        fi
        HORA_HTTP=""
    done
    [ -n "$HORA_HTTP" ] || echoamarillo "Tampoco se pudo sincronizar por HTTP; se continúa con: $(date)"
fi
# La corrección de hora PERSISTENTE en cada arranque (necesaria porque NTP está
# filtrado y, en VMware con host Windows, el RTC se desajusta tras cada reinicio)
# la instala el rol Ansible 'horaHTTP' (service + timer). Ver Ubuntu/ansible/roles/horaHTTP.

echoverde "=== $SCRIPT3 detenido: $(date) ==="


# echoverde "Arreglando posibles problemas de configuración de paquetes..."
# # Pre-configurar debconf ANTES de dpkg --configure -a para que el postinst de gdm3
# # no regenere /etc/gdm3/custom.conf con auto-login habilitado (valores del Live CD).
# export DEBIAN_FRONTEND=noninteractive
# echo "gdm3 gdm3/daemon_section/AutomaticLoginEnable boolean false" | debconf-set-selections 2>/dev/null || true
# echo "gdm3 gdm3/daemon_section/AutomaticLogin string " | debconf-set-selections 2>/dev/null || true
# dpkg --configure -a -o Dpkg::Options::="--force-confold"

# echoverde "Configuramos proxy de aula si procede..."
# # #Si el tercer octeto de la IP es 72=>estamos en aula IABD:
# # #                                32=>estamos en aula SMRD
# IP3=$(ip addr show $(ip route | grep default | awk '{print $5}') | grep 'inet ' | awk '{print $2}' | cut -d'.' -f3)
# echoverde "IP3=$IP3 (interfaz: $(ip route | grep default | awk '{print $5}'))"
# if [ "$IP3" == "72" ]; then
#     echoverde "Estamos en aula IABD, configuramos proxy 10.0.72.140:3128"
#     rm /etc/apt/apt.conf.d/00aptproxy 2>/dev/null || true
#     echo 'Acquire::http::Proxy "http://10.0.72.140:3128";'> /etc/apt/apt.conf.d/00aptproxy
#     echo 'Acquire::https::Proxy "DIRECT";'> /etc/apt/apt.conf.d/00aptproxy
#     #TODO: usar Acquire::http::Proxy-Auto-Detect script.sh
#     #DONDE script.sh contiene:
#         ##!/bin/sh
#         # IP de tu servidor apt-cacher
#         #SERVER_IP="10.0.72.140"
#         #PORT="3128"
#         # Comprueba si el puerto responde con una espera máxima de 1 segundo (-w 1)
#         #if nc -z -w 1 $SERVER_IP $PORT; then
#         #    echo "http://$SERVER_IP:$PORT"
#         #else
#         #    echo "DIRECT"
#         #fi
# elif [ "$IP3" == "32" ]; then
#     echoverde "Estamos en aula SMRV, configuramos proxy  10.0.32.119:3128"
#     rm /etc/apt/apt.conf.d/00aptproxy 2>/dev/null || true
#     echo 'Acquire::http::Proxy "http://10.0.32.119:3128";'> /etc/apt/apt.conf.d/00aptproxy
#     echo 'Acquire::https::Proxy "DIRECT";'> /etc/apt/apt.conf.d/00aptproxy
# fi

echoverde "Voy a actualizar lista de paquetes"
apt-get update --fix-missing

#Instalado SSH server
echoverde "Instalando servidor SSH+ansible y limpiando..."
# openssh-sftp-server: paquete APARTE (solo "Recommends" de openssh-server) que
# trae el binario /usr/lib/openssh/sftp-server. Sin él, sftp:// en GNOME Files
# (sesión Wayland), 'sftp' y 'scp' (OpenSSH >=9 usa el protocolo SFTP) fallan
# con "subsystem request failed on channel 0".
apt-get install -y -o Dpkg::Options::="--force-confold" ssh openssh-sftp-server ansible
# Configurar SSH para permitir el acceso root
sed -i 's/#PermitRootLogin prohibit-password/PermitRootLogin yes/' /etc/ssh/sshd_config
# Login por SSH de usuarios del DOMINIO (Active Directory): su contraseña vive
# en AD y se valida por PAM->pam_sss, NO en /etc/shadow. El default COMPILADO de
# OpenSSH es "UsePAM no", con el que sshd valida contra el shadow local -> un
# usuario de dominio (sin entrada en shadow) falla SIEMPRE con "Could not get
# shadow information for <user>" + "Failed password", aunque GDM/RDP sí entren
# (esos pasan por PAM). El sshd_config de Ubuntu 26.04 viene SIN línea UsePAM, así
# que cae al default "no". Drop-in que lo fuerza a "yes" (mismo fichero/contenido
# que despliega el rol Ansible preparaAD — mantener en sync):
mkdir -p /etc/ssh/sshd_config.d
cat > /etc/ssh/sshd_config.d/60-iac-ad.conf <<'EOF'
# Desplegado por 3-SetupPrimerInicio.sh y por el rol Ansible preparaAD (mismo
# contenido; mantener en sync). Permite el login SSH de usuarios del dominio AD
# vía PAM->pam_sss (sin esto: "Could not get shadow information for <user>").
UsePAM yes
PasswordAuthentication yes
KbdInteractiveAuthentication yes
EOF
# El drop-in SOLO surte efecto si /etc/ssh/sshd_config tiene la directiva
# `Include /etc/ssh/sshd_config.d/*.conf`. En instalaciones desde squashfs con
# --force-confold puede conservarse un sshd_config viejo SIN esa línea: entonces
# sshd IGNORA sshd_config.d/* y cae al UsePAM=no compilado de OpenSSH -> los
# usuarios del DOMINIO no entran por SSH (su contraseña se valida contra el
# shadow local, donde no existen). La garantizamos al PRINCIPIO del fichero
# (en sshd_config gana la 1ª aparición de cada opción, así que el Include debe
# ir arriba para que los drop-ins manden). Idempotente.
if ! grep -qE '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/\*\.conf' /etc/ssh/sshd_config; then
    echoamarillo "sshd_config SIN 'Include sshd_config.d/*.conf'; lo añado (si no, el drop-in UsePAM se ignora)"
    sed -i '1i Include /etc/ssh/sshd_config.d/*.conf' /etc/ssh/sshd_config
fi
# Subsistema SFTP: el sshd_config reducido de Ubuntu 26.04 (instalación squashfs
# + --force-confold) puede quedarse SIN la línea 'Subsystem sftp', de modo que
# sftp:// en GNOME Files (Wayland), 'sftp' y 'scp' fallan aunque el binario esté
# instalado. OpenSSH ABORTA si 'Subsystem sftp' se define dos veces (sshd_config
# + drop-in), así que solo lo añadimos si NO hay ya uno ACTIVO en ningún sitio.
# Idempotente. MISMO arreglo que el rol Ansible preparaAD (mantener en sync).
if ! grep -rqsE '^[[:space:]]*Subsystem[[:space:]]+sftp' /etc/ssh/sshd_config /etc/ssh/sshd_config.d/ 2>/dev/null; then
    echoamarillo "sshd SIN 'Subsystem sftp' activo; lo añado (si no, sftp:// y scp fallan)"
    echo 'Subsystem sftp /usr/lib/openssh/sftp-server' >> /etc/ssh/sshd_config
fi
# Reiniciar el servicio SSH para aplicar los cambios
service ssh restart
# Verificación en el log: UsePAM DEBE quedar en 'yes' (si no, el login por SSH
# de usuarios del dominio seguirá fallando con "Could not get shadow information").
# 'subsystem-sftp' DEBE apuntar a /usr/lib/openssh/sftp-server (si no, sftp/scp fallan).
echoverde "sshd efectivo -> $(sshd -T 2>/dev/null | grep -iE '^(usepam|passwordauthentication|kbdinteractiveauthentication|subsystem)' | tr '\n' ' ')"

#Obtener la IP de la máquina
IP=$(hostname -I | awk '{print $1}')
MAC=$(ip link show | awk '/ether/ {print $2}' | head -n 1)
mostrar_mensaje "Actualizando: SSH root/root usuario/usuario"

# Limpiar caché de paquetes
echoverde "Limpiando caché de paquetes..."
apt-get clean
apt-get autoremove -y

echoverde "Actualizando el sistema..."
apt-get update -y
apt-get full-upgrade -y -o Dpkg::Options::="--force-confold"
echoverde "Actualizado el sistema..."

# ── Eliminar el instalador de Ubuntu del equipo desplegado ───────────────────
# El squashfs (y por tanto el rsync) incluye el snap 'ubuntu-desktop-bootstrap',
# el asistente "Instalar Ubuntu" (el mismo que aparece en el Live CD). En un
# equipo ya desplegado no debe ofrecerse instalar Ubuntu. 2-SetupSOdesdeLiveCD.sh
# ya desenmascaró snapd y dejó un override de autostart Hidden=true como
# protección del primer login (incluido para usuarios nuevos); aquí, con snapd
# ya en marcha, lo purgamos definitivamente del sistema.
if command -v snap >/dev/null 2>&1; then
    echoverde "Esperando a que snapd termine el seed inicial..."
    snap wait system seed.loaded 2>/dev/null || true
    for _instsnap in ubuntu-desktop-bootstrap ubuntu-desktop-installer; do
        if snap list "$_instsnap" >/dev/null 2>&1; then
            echoverde "Eliminando snap instalador: $_instsnap"
            snap remove --purge "$_instsnap" 2>&1 || true
        fi
    done
    # Limpiar cualquier autostart residual que snapd hubiera expuesto para el snap
    # (el override Hidden=true de /etc/xdg/autostart se conserva como red de seguridad).
    rm -f /var/lib/snapd/desktop/autostart/ubuntu-desktop-bootstrap*.desktop 2>/dev/null || true
    if snap list ubuntu-desktop-bootstrap >/dev/null 2>&1; then
        echorojo "AVISO: ubuntu-desktop-bootstrap sigue presente tras snap remove — revisar"
    else
        echoverde "Instalador de Ubuntu (ubuntu-desktop-bootstrap) eliminado del sistema"
    fi
fi

# Soporte Wayland en VMware: instalar open-vm-tools-desktop (integración clipboard/resize
# en Wayland) y confirmar/añadir LIBGL_ALWAYS_SOFTWARE (por si no se aplicó en el chroot).
_VIRT=$(systemd-detect-virt 2>/dev/null || true)
echoverde "Entorno de virtualización: ${_VIRT:-ninguno}"
if echo "$_VIRT" | grep -qi "vmware"; then
    echoverde "VMware detectado — instalando open-vm-tools-desktop para soporte Wayland..."
    apt-get install -y -o Dpkg::Options::="--force-confold" open-vm-tools-desktop || true
    grep -q 'LIBGL_ALWAYS_SOFTWARE' /etc/environment 2>/dev/null \
        || echo 'LIBGL_ALWAYS_SOFTWARE=1' >> /etc/environment
    echoverde "VMware Wayland: open-vm-tools-desktop instalado, LIBGL_ALWAYS_SOFTWARE=1 confirmado"
fi

# Re-aplicar configuración GDM post-upgrade: si gdm3 se actualizó, su postinst puede
# haber regenerado custom.conf con los valores del Live CD (AutomaticLoginEnable=true).
echoverde "Re-aplicando configuración GDM (deshabilitar auto-login post-upgrade)..."
mkdir -p /etc/gdm3
cat > /etc/gdm3/custom.conf << 'GDM3POSTEOF'
[daemon]
AutomaticLoginEnable=false
TimedLoginEnable=false
InitialSetupEnable=false
WaylandEnable=true

[security]

[xdmcp]

[chooser]

[debug]
GDM3POSTEOF
echoverde "GDM: auto-login e initial-setup deshabilitados, Wayland habilitado (post-upgrade)"

# Limpiar caché de paquetes
echoverde "Limpiando caché de paquetes segunda vez..."
apt-get clean
apt-get autoremove -y


echoverde "Recompilando configuración dconf (fondo de escritorio y ajustes del sistema)..."
dconf update 2>/dev/null || true


mostrar_mensaje "Intentamos cambiar IP y nombre de nuevo"
chmod +x "$SCRIPT4nombreip"
/bin/bash "$SCRIPT4nombreip"

mostrar_mensaje "Intentamos configurar Ansible y SSH"
chmod +x "$SCRIPT5ansible"
/bin/bash "$SCRIPT5ansible"

mostrar_mensaje "Intentamos finalizar autoconfiguración con Ansible"
set +e # desactivamos para que no se pare en errores de ansible
cd "$RAIZANSIBLE/" || exit 1
# El interprete Python cambia con cada version de Ubuntu (26.04 'resolute' ya
# no trae /usr/bin/python3.12). Resolverlo en runtime en vez de codificarlo a
# fuego: el symlink /usr/bin/python3 siempre apunta al Python por defecto.
PYINT="$(command -v python3 || echo /usr/bin/python3)"
echoverde "Interprete Python para Ansible: $PYINT"

# --- Que los errores SIEMPRE queden registrados en el log -----------------
# 1) Frontend NO interactivo para TODO lo que lance ansible (incluidas las
#    tareas 'command:' como el 'dpkg --configure -a' del rol clienteNAS, que
#    NO heredan el noninteractive que el modulo apt si fija por su cuenta).
#    Sin esto, si un paquete quedo a medio configurar y su postinst abre un
#    dialogo debconf, dpkg espera una entrada que nunca llega (no hay TTY) ->
#    ansible se cuelga, NO emite el 'FAILED!' y el log se corta en el TASK
#    sin registrar el error. Con noninteractive el paso falla rapido y el
#    fallo SI queda escrito.
export DEBIAN_FRONTEND=noninteractive
export DEBCONF_NONINTERACTIVE_SEEN=true
export NEEDRESTART_MODE=a
export APT_LISTCHANGES_FRONTEND=none
# 2) Salida de ansible SIN buffer: Python bloquea el buffer de stdout cuando
#    no es una TTY (aqui es la process-substitution del log). Si ansible se
#    cuelga o lo matan con el buffer a medio llenar, esas lineas -incluido el
#    'fatal: [...]: FAILED!'- se PIERDEN y el log se corta en el TASK sin el
#    error. PYTHONUNBUFFERED fuerza el volcado linea a linea al log.
export PYTHONUNBUFFERED=1
export ANSIBLE_FORCE_COLOR=0


# --- Contador de intentos para evitar bucle infinito de reinicios --------
# Si ansible-playbook falla, el bloque de error de mas abajo reinicia SIN
# borrar el servicio para que el siguiente arranque vuelva a intentarlo. Para
# no quedar atrapados en un bucle, contamos los intentos en un fichero
# persistente (sobrevive al reinicio) y rendimos tras el 3er fallo. En el
# 3er fallo se borra el servicio y el equipo queda accesible para diagnostico
# manual.
_ATTEMPT_DIR="/var/lib/IAC-IESMHP"
_ATTEMPT_FILE="$_ATTEMPT_DIR/ansible-attempts"
_MAX_ATTEMPTS=3
mkdir -p "$_ATTEMPT_DIR"
_ATTEMPT_NUM=$(cat "$_ATTEMPT_FILE" 2>/dev/null || echo 0)
_ATTEMPT_NUM=$((_ATTEMPT_NUM + 1))
echo "$_ATTEMPT_NUM" > "$_ATTEMPT_FILE"
sync   # contador a disco YA: si el reinicio matase el flush, no se perderia
echoamarillo "=== Intento $_ATTEMPT_NUM de $_MAX_ATTEMPTS de configuracion Ansible ==="

echoamarillo "=== Lanzando ansible-playbook roles.yaml: $(date) ==="
sync   # marcador garantizado en disco ANTES del paso que suele colgar
ansible-playbook -i localhost, --connection=local roles.yaml \
    -e "ansible_python_interpreter=$PYINT" \
    --ssh-extra-args="-o StrictHostKeyChecking=no"
_RC_ANSIBLE=$?
# Dejar el rc grabado en el log INMEDIATAMENTE. Sin esto, si abajo se llama
# a systemctl reboot tras un fallo, el consumidor del log (la process-
# substitution con `tee`) puede no llegar a vaciar las ultimas lineas
# (incluida la causa del reinicio) antes de que el kernel apague el equipo.
echoamarillo "=== ansible-playbook devolvio rc=$_RC_ANSIBLE (intento $_ATTEMPT_NUM/$_MAX_ATTEMPTS) ==="
sync
if [ "$_RC_ANSIBLE" -ne 0 ]; then
    echorojo "Error en la autoconfiguracion ansible (rc=$_RC_ANSIBLE) - intento $_ATTEMPT_NUM/$_MAX_ATTEMPTS"
    sync
    if [ "$_ATTEMPT_NUM" -ge "$_MAX_ATTEMPTS" ]; then
        # 3er fallo consecutivo: ya no reintentamos. Borramos el servicio
        # para que el equipo arranque normal y se pueda diagnosticar a mano.
        echorojo "Alcanzado el maximo de $_MAX_ATTEMPTS intentos sin exito - desactivando el servicio para diagnostico manual"
        mostrar_mensaje "Configuracion Ansible fallida tras $_MAX_ATTEMPTS intentos. Servicio detenido. Revisar $FLOG"
        rm -f "$_ATTEMPT_FILE"
        systemctl disable 3-SetupPrimerInicio.service || true
        rm -f /etc/systemd/system/3-SetupPrimerInicio.service
        mv "$0" "$0.borrado" || true
        sync
        sleep 2   # dar tiempo al consumidor del log a drenar lo pendiente
        exit 1
    else
        # Intento < MAX: reiniciar para que el servicio vuelva a lanzarse.
        # ANTES del reboot drenamos sync + pequena espera para que las
        # lineas de error de ansible queden en disco (en versiones previas,
        # el reinicio rapido perdia esas lineas y el log no registraba el
        # motivo del bucle).
        mostrar_mensaje "Configuracion con errores (intento $_ATTEMPT_NUM/$_MAX_ATTEMPTS). Reiniciando en 10 s para reintentar..."
        echoamarillo "Reintentando: se reiniciara para repetir el proceso (servicio NO borrado)"
        sync
        sleep 2   # consumidor (tee) drena lineas pendientes
        sync
        sleep 10 && systemctl reboot -i
    fi

else
    echoverde "ansible-playbook finalizo correctamente (rc=0) en el intento $_ATTEMPT_NUM"
    sync   # asegura en disco el resultado (ok o error) de ansible antes de seguir
    # Exito: reseteamos el contador para no acarrearlo si en el futuro este
    # script (o uno equivalente) volviera a ejecutarse.
    rm -f "$_ATTEMPT_FILE"
    echoverde "Desactivando y borrando el servicio de actualización en primer arranque..."
    systemctl disable 3-SetupPrimerInicio.service
    rm /etc/systemd/system/3-SetupPrimerInicio.service
    mv "$0" "$0.borrado" # Renombrar el script para evitar que se ejecute de nuevo

    # Comprobaciones finales del sistema
    SCRIPT4="$RAIZDISTRO/4-Comprobaciones.sh"
    if [ -f "$SCRIPT4" ]; then
        echoverde "Ejecutando comprobaciones finales del sistema..."
        chmod +x "$SCRIPT4"
        # No re-redirigir a $FLOG: stdout/stderr ya pasan por el 'tee -a $FLOG'
        # del exec inicial. Un 'tee -a $FLOG' aqui duplicaria esta seccion.
        bash "$SCRIPT4" || true
    fi

    echoverde "=== $SCRIPT3 finalizado: $(date) ==="

    mostrar_mensaje "Sistema actualizado y configurado. Reiniciando en 5 segundos..."
    rm -f "$VERLOGSCRIPT"
    sleep 5 && systemctl reboot -i
fi







