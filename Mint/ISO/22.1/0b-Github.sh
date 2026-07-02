#!/bin/bash
#Script que descarga desde GIT la última versión de los scripts de instalación de IESMHP
#y los copia a /LiveCDiesmhp, y ejecuta el script de configuración del LiveCD

# POR HACER: meter una espera de 10 segundos antes de empezar el proceso de update (para dar tiempo a que arranque la red. Avisar si no hay internet)

set -e
VERSIONSCRIPT="22.1-20260127-09:09"       #Versión del script
SCRIPT1NOMBRE="1-SetupLiveCD.sh"
DISTRO="Mint"
RAIZSCRIPTSLIVE="/LiveCDiesmhp"
REPO="IAC-IESMHP"
RAIZLOG="/var/log/$REPO/$DISTRO"
LOG0="$RAIZLOG/$0.log"
GITREPO="https://github.com/victormuelacarriles/IAC-IESMHP.git"
mkdir -p $RAIZLOG
echoverde() {
    TEXTO=$1
    echo -e "\033[32m$TEXTO\033[0m"
    echo $TEXTO >> $LOG0
}
echoverde "($0 vs $VERSIONSCRIPT) $RAIZLOG"

versionDISTRO=$(grep VERSION_ID /etc/os-release | cut -d'"' -f2)
RAIZSCRIPTSLIVEISOS="$RAIZSCRIPTSLIVE/$DISTRO/ISO/$versionDISTRO"
SCRIPT1="$RAIZSCRIPTSLIVEISOS/$SCRIPT1NOMBRE"


echoverde "En español (si se puede) y con usuarios mint:mint root:root por si hay que depurar"
setxkbmap es || true && loadkeys es ||true
echo "mint:prov" | chpasswd
echo "root:prov" | chpasswd
echo "mint:mint" | chpasswd
echo "root:root" | chpasswd

# COMENTAMOS: ya probaremos en versiones siguientes. 
# #Si el tercer octeto de la IP es 32=>estamos en aula SMRDV:  activamos proxy
# IP3=$(ip addr show $(ip route | grep default | awk '{print $5}') | grep 'inet ' | awk '{print $2}' | cut -d'.' -f3)
# if [ "$IP3" == "32" ]; then
#     echoverde "Estamos en aula SMRDV, configuramos proxy"
#     rm /etc/apt/apt.conf.d/00aptproxy 2>/dev/null || true
#     echo 'Acquire::http::Proxy "http://10.0.32.119:3128/";' > /etc/apt/apt.conf.d/00aptproxy
# fi

#TODO: comprobar si hay conexión a internet antes de seguir. Hacer ping a google.com o similar



echoverde "Actualizamos..."
rm /etc/apt/sources.list 2>/dev/null || true
apt-get update 2>&1 | tee -a $LOG0

echoverde "Instalamos ssh y git"
apt-get install -y ssh git 2>&1 | tee -a $LOG0

echoverde "Clonamos:  git clone $GITREPO $RAIZSCRIPTSLIVE "
rm -r $RAIZSCRIPTSLIVE 2>/dev/null || true
git clone $GITREPO $RAIZSCRIPTSLIVE 2>&1 | tee -a $LOG0

echoverde "Hacemos ejecutables los scripts del directorio ( chmod +x $RAIZSCRIPTSLIVEISOS/*.sh )"
chmod +x $RAIZSCRIPTSLIVEISOS/*.sh
mkdir -p $RAIZLOG 2>&1 | tee -a $LOG0

LOGSig="$RAIZLOG/$SCRIPT1NOMBRE.log"
echoverde "Ejecutamos $SCRIPT1 (log en $LOGSig)..." | tee -a $LOG0
/bin/bash $SCRIPT1 2>&1 | tee -a $LOGSig || tee -a $LOG0

cp "$RAIZLOG/*.log" "/mnt$RAIZLOG"
echoverde "Proceso finalizado. Logs en $RAIZLOG y /mnt$RAIZLOG"



