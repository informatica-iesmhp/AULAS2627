
###XRDP
apt install xrdp xfce4 -y
adduser xrdp ssl-cert

#Crea el fichero /etc/xrdp/startwm.sh, con un contenido estandar:
cat > /etc/xrdp/startwm.sh << 'EOF'
#!/bin/sh
# Cargar variables de entorno
if test -r /etc/profile; then
    . /etc/profile
fi
if test -r ~/.profile; then
    . ~/.profile
fi
# Establecer variables para Cinnamon
export DESKTOP_SESSION=cinnamon
export XDG_CURRENT_DESKTOP=X-Cinnamon
export GNOME_DESKTOP_SESSION_ID=this-is-deprecated
# Intentar iniciar Cinnamon en modo fallback (software rendering)
cinnamon-session --fallback &
sleep 3
# Comprobar si Cinnamon arrancó correctamente (buscamos proceso)
if ! pgrep -x "cinnamon-session" > /dev/null; then
    echo "Cinnamon falló. Iniciando XFCE como alternativa..." >> ~/.xsession-errors
    startxfce4
fi
# Mantener sesión activa si Cinnamon sí arrancó
wait
EOF
chmod +x /etc/xrdp/startwm.sh
systemctl restart xrdp
