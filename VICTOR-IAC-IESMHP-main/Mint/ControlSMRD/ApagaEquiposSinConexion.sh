#!/bin/bash
for i in {120..138}; do
    #Si contesta al ping, se intenta apagar:
    if ping -c 1 -W 1 10.0.32.$i &> /dev/null; then
        echo "Detectado encendido de 10.0.32.$i : comprobando conexiones y apagando si no hay..."
        ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=NULL root@10.0.32.$i "HOSTNAME=\$(hostname); R=\$(ss -Htn state established '( sport = :ssh or sport = :3389 )' | grep -v 10.0.32.119); if [ -z \"\$R\" ]; then echo \"Apagando 10.0.32.$i (\$HOSTNAME)\"; poweroff; else echo \"\$R\"; fi" &
    else
        echo "10.0.32.$i no responde"
        continue
    fi
done

##En crontab de la 10.0.32.119: (crontab -e)
# m h  dom mon dow   command
#0 1,3,5,7,21,23 * * * /opt/IAC-IESMHP/Mint/ControlSMRD/ApagaEquiposSinConexion.sh
#--->Apagado diario a las 01:00,03:00,05:00,7:00,21:00,23:00