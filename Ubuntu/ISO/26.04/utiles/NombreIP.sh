#!/bin/bash
#"set -e" significa que el script se detendrá si ocurre un error
#vs 11/6/2026
set -e

# Variables comunes del proyecto (REPO, DISTRO, RAIZSCRIPTS, RAIZLOG, URL_MACS,
# redes de aula RED_IABD/RED_SMRD...). Único punto de definición: comun.sh
# (este script vive en ISO/26.04/utiles/, de ahí el "/.." para subir a 26.04).
_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$_DIR/comun.sh"

RAIZLOGS="$RAIZLOG"   # alias histórico usado por el resto del script
mkdir -p "$RAIZLOGS"

# Funciones de colores
echoverde() {  
    echo -e "\033[32m$1\033[0m" 
}
echorojo()  {
      echo -e "\033[31m$1\033[0m" 
}  

#Función para cambiar la ip estática
cambiar_ip_estatica() {
    local ncCONEX="$1"
    local IPESTATICAN="$2"
    local IPGATEWAY="$3"
    local IPDNS1="$4"
    local IPDNS2="$5"
        echo "La IP actual ($IP_RED) es dinámica, vamos a convertirla en estática."
        nmcli con modify "$ncCONEX" ipv4.addresses "$IPESTATICAN"
        nmcli con modify "$ncCONEX" ipv4.gateway "$IPGATEWAY"
        nmcli con modify "$ncCONEX" ipv4.dns "$IPDNS1 $IPDNS2"  
        nmcli con modify "$ncCONEX" ipv4.method manual
        nmcli con down "$ncCONEX" && nmcli connection up "$ncCONEX"
}

MAC=$(ip link show | awk '/ether/ {print $2}' | head -n 1)
echo "0-MAC: $MAC"
#DOING: descargar desde github usuarios autorizados y claves ssh
# URL_MACS lo define comun.sh (https://raw.githubusercontent.com/.../macs.csv).
# Se descarga a RAIZLOGS (no al clon git de $RAIZSCRIPTS): más abajo este
# fichero se sobreescribe dejando solo la línea de la MAC, y hacerlo sobre
# /opt/IAC-IESMHP/macs.csv ensuciaría el repo clonado.
LOCAL_MACS="$RAIZLOGS/macs.csv"
echo "2-variales cargadas / descargando archivos desde GitHub"
wget --header="Cache-Control: no-cache" -O $LOCAL_MACS $URL_MACS

# Compruebo si la MAC está en el repositorio. Si NO está, se conserva el nombre
# que asignó la instalación en 2-SetupSOdesdeLiveCD.sh (ld+fecha, p. ej.
# ld202606160934), de modo que el hostname único por equipo no cambia en cada
# arranque. Si el equipo aún tiene un nombre genérico (residuo del Live CD o de
# versiones antiguas), se genera uno nuevo ld+AAAAMMDDHHMM.
EQUIPOENMACS="$(hostname)"
case "$EQUIPOENMACS" in
    ubuntu|Ubuntu|mint|Mint|localhost|"") EQUIPOENMACS="ld$(date +%Y%m%d%H%M)" ;;
esac
if [ ! -f $LOCAL_MACS ]; then
    echorojo "No se ha encontrado el archivo de MACs: $LOCAL_MACS"
    echo "Por favor, compruebe la conexión a Internet y que el archivo está disponible en el repositorio."
else
    # Compruebo si la MAC está en el repositorio
    if ! grep -q -i "$MAC" "$LOCAL_MACS"; then
        echorojo "La MAC $MAC no se encuentra en el repositorio."
        echo            "Por favor, compruebe la conexión a Internet y que la MAC está registrada en el repositorio."
    else
        INFO_MACS=$(cat $LOCAL_MACS | grep -i $MAC )
        #Sustituyo el contenido de $LOCAL_MACS por la información de la MAC
        echo "Información de la MAC: $INFO_MACS"
        echo "$INFO_MACS" > $LOCAL_MACS
        #Si se encuentra la MAC, extraigo el nombre del equipo
        EQUIPOENMACS=$(echo $INFO_MACS | cut -d',' -f2 | xargs)
        IPFINALENMACS=$(echo $INFO_MACS | cut -d',' -f3 | xargs)
    fi
fi

EQUIPOACTUAL=$(hostname)
if [ "$EQUIPOACTUAL" != "$EQUIPOENMACS" ]; then
    echo "Equipo identificado: '$EQUIPOENMACS'  Nombre actual del equipo: '$EQUIPOACTUAL'"    

    #Pido confirmación para cambiar el nombre del equipo
    #read -p "¿Desea cambiar el nombre del equipo a '$EQUIPOENMACS'? (s/n): " CONFIRMACION
    CONFIRMACION="S"
    if [[ ! "$CONFIRMACION " != ^[Ss]$ ]]; then
         echorojo "Cambio de nombre del equipo cancelado."
        sleep 100 && exit 0
    else  
        #Cambio el nombre del equipo a $EQUIPOENMACS
        echo "Renombrando el equipo a: $EQUIPOENMACS"
        echo "$EQUIPOENMACS" > /etc/hostname
        echo "127.0.0.1 localhost" > /etc/hosts
        echo "127.0.1.1 $EQUIPOENMACS" >> /etc/hosts
        hostnamectl set-hostname "$EQUIPOENMACS"
    fi
else
    echo "El nombre del equipo ya es correcto: '$EQUIPOENMACS'" 
fi

#IP: vamos a averiguar en que red estamos y a configurar la IP

#usando nmcli, ver cual es la conexión activa
ncCONEXION=$(nmcli -f NAME,TYPE connection show |grep ethernet| sed 's/ethernet//g' | xargs)
if [ -z "$ncCONEXION" ]; then
    echorojo "No se ha encontrado una conexión Ethernet activa."
    exit 1
fi
echo "Conexión Ethernet activa: $ncCONEXION"
#Me quedo con la info de la conexión activa
AULA=$(echo $EQUIPOENMACS | cut -d'-' -f1 | xargs)
IP_INTERFAZ=$(nmcli connection show "$ncCONEXION"|grep connection.interface-name|head -n 1 | awk '{print $2}' | xargs )
IP_METHOD=$(nmcli connection show "$ncCONEXION" | grep ipv4.method | awk '{print $2}' | xargs)
IP_RED=$(nmcli connection show "$ncCONEXION"| grep IP4.ADDRESS|head -n 1|awk '{print $2}'|xargs)
IP_REDAULA=$(echo "$IP_RED"| cut -d'.' -f1-3 | xargs)
IP_IP=$(echo $IP_RED|cut -d'/' -f1|xargs)
IP_SOLOFINAL=$(echo $IP_RED | cut -d'.' -f4| cut -d'/' -f1| xargs)
IP_MASCARA=$(echo $IP_RED | cut -d'.' -f4| cut -d'/' -f2| xargs)
IP_GATEWAY=$(nmcli connection show "$ncCONEXION" | grep IP4.GATEWAY|head -n 1 | awk '{print $2}' | xargs)
IP_DNS1=$(nmcli connection show "$ncCONEXION" | grep "IP4.DNS\[1\]"|head -n 1 | awk '{print $2}' | xargs)
IP_DNS2=$(nmcli connection show "$ncCONEXION" | grep "IP4.DNS\[2\]"|head -n 1 | awk '{print $2}' | xargs)
echo "IP Actual (nmcli): $IP_RED ($IP_METHOD) - Gateway: $IP_GATEWAY - DNS: $IP_DNS1, $IP_DNS2 -> $IP_SOLOFINAL"
echo "Aula: $AULA - IP_REDAULA: $IP_REDAULA"


#Activamos WOL
###  ethtool -s $IP_INTERFAZ wol g  ###por probar si funciona sin el: está dando problemas en nuevas versiones de Linux
nmcli c modify "$ncCONEXION" 802-3-ethernet.wake-on-lan magic
nmcli c modify "$ncCONEXION" 802-3-ethernet.accept-all-mac-addresses 1


BNECESARIORESTABLECERRED="N"
#Compramos si la dirección actual está asociada al aula que corrsponde
if [[ ("$IP_REDAULA" == "$RED_IABD" && "$AULA" == "IABD") ||
      ("$IP_REDAULA" == "$RED_SMRD" && "$AULA" == "SMRD") ||
      ("$IP_REDAULA" == "$RED_IF04" && "$AULA" == "IF04") ]]; then
    if [ -z "$IPFINALENMACS" ]; then
        # Equipo sin IPf asignada en macs.csv (p.ej. IF04-17): se deja en DHCP
        # puro, sin tocar la red. Sin esta guarda, IPESTATICANUEVA quedaría
        # mal formada (p.ej. "10.0.22./24") y cambiar_ip_estatica fallaría.
        echo "Equipo $EQUIPOENMACS sin IPf en macs.csv: se deja en DHCP, no se toca la red."
    else
    IPESTATICANUEVA="$IP_REDAULA.$IPFINALENMACS/24"
    if [ "$IP_METHOD" == "auto" ]; then
        echoverde "La IP actual ($IP_RED) es dinámica, vamos a convertirla en estática (-> $IPESTATICANUEVA)"
        echorojo '(la conexión ssh se perderá durante el proceso!)'
        cambiar_ip_estatica "$ncCONEXION" "$IPESTATICANUEVA" "$IP_GATEWAY" "$IP_DNS1" "$IP_DNS2"
        BNECESARIORESTABLECERRED="S"
    else

        if [ "$IP_RED" != "$IPESTATICANUEVA" ]; then
            echo "La IP actual ($IP_IP) no es la correcta ($IPESTATICANUEVA). La cambiamos."
            cambiar_ip_estatica "$ncCONEXION" "$IPESTATICANUEVA" "$IP_GATEWAY" "$IP_DNS1" "$IP_DNS2"
            BNECESARIORESTABLECERRED="S"
        else
            echo "La IP actual ($IP_IP) es la correcta ($IPESTATICANUEVA)."
        fi
    fi
    fi
else
    if [ "$IP_METHOD" != "auto" ]; then
        echo "La IP actual ($IP_RED) no corresponde al aula $AULA, y tiene una IP estática. Convertimos a dinámica."
        nmcli con modify "$ncCONEXION" ipv4.method auto
        BNECESARIORESTABLECERRED="S"
    else
        echo "La IP actual ($IP_RED) no es de $AULA (pero ya es IP dinámica: nada que hacer)."
    fi
fi

if [ "$BNECESARIORESTABLECERRED" == "S" ]; then
    echorojo "Reseteo la red: podría perderse la conexión"
    nmcli con down "$ncCONEXION" && nmcli connection up "$ncCONEXION"
fi





echoverde "Proceso finalizado correctamente."

###
###fwupdmgr update -y
