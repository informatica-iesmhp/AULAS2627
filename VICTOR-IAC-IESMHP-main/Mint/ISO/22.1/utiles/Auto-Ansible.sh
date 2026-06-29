#!/bin/bash
set -e
#Instalamos un cerftifico propio, y configuramos SSH para que funcione con Ansible. 


# Asegurar que ~/.ssh existe con permisos correctos
mkdir -p /root/.ssh
chmod 700 /root/.ssh
chown root:root /root/.ssh

# Verificar si ya existe la clave privada
KEY_FILE="/root/.ssh/id_ed25519"
if [[ ! -f "$KEY_FILE" ]]; then
    ssh-keygen -t ed25519 -C "root@$(hostname)" -f "$KEY_FILE" -N "" 1>&2 2>/dev/null
fi

# Leer la clave pública
PUB_KEY_FILE="${KEY_FILE}.pub"
if [[ ! -f "$PUB_KEY_FILE" ]]; then
    echo "ERROR: no se encuentra la clave pública en $PUB_KEY_FILE" 
    exit 1
fi
PUB_KEY_CONTENT=$(<"$PUB_KEY_FILE")

# Añadir la clave pública a authorized_keys si no está
AUTHORIZED_KEYS="/root/.ssh/authorized_keys"
grep -qF "$PUB_KEY_CONTENT" "$AUTHORIZED_KEYS" 2>/dev/null || {
    echo "$PUB_KEY_CONTENT" >> "$AUTHORIZED_KEYS"
    chmod 600 "$AUTHORIZED_KEYS"
    chown root:root "$AUTHORIZED_KEYS"
}

# Verificar si el host está en known_hosts ####FALLA 
KNOWN_HOSTS="/root/.ssh/known_hosts"
touch "$KNOWN_HOSTS"  # Asegurarse de que el archivo existe
HOSTNAME=$(hostname)
# Comprobar si la clave ya está
if ! ssh-keygen -F "$HOSTNAME" -f "$KNOWN_HOSTS" > /dev/null; then
    echo "Añadiendo la clave SSH de localhost ($HOSTNAME) a known_hosts..."
    ssh-keyscan -H "$HOSTNAME" >> "$KNOWN_HOSTS" 2>/dev/null || \
    ssh-keyscan -H localhost >> "$KNOWN_HOSTS" 2>/dev/null
    chmod 644 "$KNOWN_HOSTS"
fi

#Instalamos Ansible
apt install -y ansible