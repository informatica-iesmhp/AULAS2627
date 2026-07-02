#!/bin/bash

#"set -e" significa que el script se detendrá si ocurre un error
set -e # lo desactivamos para que no se pare en errores de 

VERSIONSCRIPT="22.1-20260126-17:05"       #Versión del script
SCRIPT3=$(basename "$0")
echo "$SCRIPT3 (vs$VERSIONSCRIPT)"
#Nos quedamos solo con el nombre del script sin ruta

REPO="IAC-IESMHP"
DISTRO="Mint"
versionDISTRO=$(grep VERSION_ID /etc/os-release | cut -d'"' -f2)
RAIZSCRIPTS="/opt/$REPO"
RAIZLOG="/var/log/$REPO/$DISTRO"
RAIZDISTRO="$RAIZSCRIPTS/$DISTRO/ISO/$versionDISTRO"
RAIZANSIBLE="$RAIZSCRIPTS/$DISTRO/ansible"

SCRIPT4nombreip="$RAIZDISTRO/utiles/NombreIP.sh"
SCRIPT5ansible="$RAIZDISTRO/utiles/Auto-Ansible.sh"

VERLOGSCRIPT="/home/usuario/verLog.sh"

#Fichero de log del servicio
FLOG="$RAIZLOG/$SCRIPT3.log"

# Function to show a message to all graphical sessions
mostrar_mensaje() {
    local MENSAJE="${1:-'hola mundo'}"
    local TIEMPO="${2:-3000000}"
    IP=$(hostname -I | awk '{print $1}')
    MAC=$(ip link show | awk '/ether/ {print $2}' | head -n 1)

    local IPMAC="[ $MAC ]  -  $(hostname)\n$FLOG\n         ó\n$VERLOGSCRIPT"
    MENSAJE2="$MENSAJE\n\n$IPMAC"
    while read -r sid; do
        USERNAME=$(loginctl show-session "$sid" -p Name --value)
        DISPLAY=$(loginctl show-session "$sid" -p Display --value)
        TYPE=$(loginctl show-session "$sid" -p Type --value)
        # Continuar solo si hay DISPLAY
        [[ -z "$DISPLAY" ]] && continue
        # Obtener UID
        USER_ID=$(id -u "$USERNAME")
        # Obtener DBUS address de la sesión (si existe)
        DBUS_ADDRESS=$(grep -z DBUS_SESSION_BUS_ADDRESS /proc/$(pgrep -u "$USERNAME" -n gnome-session 2>/dev/null || pgrep -u "$USERNAME" -n xfce4-session 2>/dev/null || echo 0)/environ 2>/dev/null | tr '\0' '\n' | grep DBUS_SESSION_BUS_ADDRESS= | cut -d= -f2-)
        # Ejecutar zenity como el usuario
        sudo -u "$USERNAME" DISPLAY="$DISPLAY" DBUS_SESSION_BUS_ADDRESS="$DBUS_ADDRESS" \
            zenity --info --text="$MENSAJE2" --title="Actualizando ($IP)" --timeout=$TIEMPO &
    done < <(loginctl list-sessions --no-legend | awk '{print $1}')
}

echoverde() {
    local MENSAJE_EN_GUI="${3:-'N'}"  
    echo -e "\033[32m$1\033[0m" 
    echo $1 >> $FLOG
    if [[ "$MENSAJE_EN_GUI" == "S" ]]; then
        mostrar_mensaje "$1"
    fi
}
echorojo()  {
    echo -e "\033[31m$1\033[0m"
    echo $1 >> $FLOG 
    mostrar_mensaje "ERROR!!! :  $1"
}
echoamarillo() {  
        local MENSAJE_EN_GUI="${3:-'N'}"  
    echo -e "\033[33m$1\033[0m" 
    echo $1 >> $FLOG
    if [[ "$MENSAJE_EN_GUI" == "S" ]]; then
        mostrar_mensaje "$1"
    fi
}

echo "tail -f $FLOG" > $VERLOGSCRIPT
chmod +x $VERLOGSCRIPT

echoverde "Lanzando mensaje en sesiones gráficas activas..." 
mostrar_mensaje "Actualizando: (SSH no disponible)" 
echoverde "Ejecutando actualización del sistema en primer arranque en 20sg.." 
sleep 20 # Espera 20 segundos para asegurar que el sistema esté completamente arrancado

echoverde "Ajustadando la hora del sistema..."
timedatectl set-timezone Europe/Madrid
timedatectl set-ntp true

echoverde "Arreglando posibles problemas de configuración de paquetes..." 
dpkg --configure -a >> $FLOG

echoverde "Configuramos proxy de aula si procede..." 
# #Si el tercer octeto de la IP es 72=>estamos en aula IABD:
# #                                32=>estamos en aula IABD
IP3=$(ip addr show $(ip route | grep default | awk '{print $5}') | grep 'inet ' | awk '{print $2}' | cut -d'.' -f3)
if [ "$IP3" == "72" ]; then
    echoverde "Estamos en aula IABD, configuramos proxy 10.0.72.140:3128"
    rm /etc/apt/apt.conf.d/00aptproxy 2>/dev/null || true
    echo 'Acquire::http::Proxy "http://10.0.72.140:3128";'> /etc/apt/apt.conf.d/00aptproxy
    echo 'Acquire::https::Proxy "DIRECT";'> /etc/apt/apt.conf.d/00aptproxy
    #TODO: usar Acquire::http::Proxy-Auto-Detect script.sh
    #DONDE script.sh contiene:
        ##!/bin/sh
        # IP de tu servidor apt-cacher
        #SERVER_IP="10.0.72.140"
        #PORT="3128"
        # Comprueba si el puerto responde con una espera máxima de 1 segundo (-w 1)
        #if nc -z -w 1 $SERVER_IP $PORT; then
        #    echo "http://$SERVER_IP:$PORT"
        #else
        #    echo "DIRECT"
        #fi


elif [ "$IP3" == "32" ]; then
    echoverde "Estamos en aula SMRV, configuramos proxy  10.0.32.119:3128"
    rm /etc/apt/apt.conf.d/00aptproxy 2>/dev/null || true
    echo 'Acquire::http::Proxy "http://10.0.32.119:3128";'> /etc/apt/apt.conf.d/00aptproxy
    echo 'Acquire::https::Proxy "DIRECT";'> /etc/apt/apt.conf.d/00aptproxy
fi

echoverde "Voy a actualizar lista de paquetes" 
apt-get update --fix-missing >> $FLOG




#Instalado SSH server
echoverde "Instalando servidor SSH+ansible y limpiando..."
apt-get install -y ssh ansible >> $FLOG
# Configurar SSH para permitir el acceso root
sed -i 's/#PermitRootLogin prohibit-password/PermitRootLogin yes/' /etc/ssh/sshd_config
# Reiniciar el servicio SSH para aplicar los cambios
service ssh restart >> $FLOG

#Obtener la IP de la máquina
IP=$(hostname -I | awk '{print $1}')
MAC=$(ip link show | awk '/ether/ {print $2}' | head -n 1)
mostrar_mensaje "Actualizando: SSH root/root usuario/usuario" 

# Limpiar caché de paquetes
echoverde "Limpiando caché de paquetes..."
apt-get clean >> $FLOG
apt-get autoremove -y >> $FLOG


echoverde "Actualizando el sistema..." 
apt-get update -y >> $FLOG
apt-get full-upgrade -y >> $FLOG
echoverde "Actualizado el sistema..." 

# Limpiar caché de paquetes
echoverde "Limpiando caché de paquetes segunda vez..."
apt-get clean >> $FLOG
apt-get autoremove -y >> $FLOG


echoverde "Desactivando y borrando el servicio de actualización en primer arranque..." >> $FLOG
systemctl disable 3-SetupPrimerInicio.service
rm /etc/systemd/system/3-SetupPrimerInicio.service
mv "$0" "$0.borrado" # Renombrar el script para evitar que se ejecute de nuevo

mostrar_mensaje "Intentamos cambiar IP y nombre de nuevo" >> $FLOG
chmod +x "$SCRIPT4nombreip"
/bin/bash "$SCRIPT4nombreip"  >> $FLOG 

mostrar_mensaje "Intentamos configurar Ansible y SSH" >> $FLOG
chmod +x "$SCRIPT5ansible"
/bin/bash "$SCRIPT5ansible"  >> $FLOG 

mostrar_mensaje "Intentamos finalizar autoconfiguración con Ansible" >> $FLOG
set +e # desactivamos para que no se pare en errores de ansible
cd "$RAIZANSIBLE/" || exit 1
ansible-playbook -i localhost, --connection=local roles.yaml -e 'ansible_python_interpreter=/usr/bin/python3.12' --ssh-extra-args="-o StrictHostKeyChecking=no" >> $FLOG || echorojo "Error en la autoconfiguración ansible" && true

#Reinciando en 30 segundos y avisando a los usuarios
mostrar_mensaje "Sistema actualizado. SSH root/root" 

echoverde "Reiniciando el sistema en 30 segundos..." >> $FLOG
sleep 30
rm $VERLOGSCRIPT
echo "Reiniciando el sistema..." >> $FLOG
reboot now