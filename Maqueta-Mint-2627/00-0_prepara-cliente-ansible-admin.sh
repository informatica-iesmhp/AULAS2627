#!/bin/bash

# Configuración - Cambia esto si prefieres otro nombre de usuario
USUARIO_ANSIBLE="ansible-admin"

echo "=== Iniciando preparación del cliente para Ansible ==="

# 1. Crear el usuario para Ansible si no existe
if ! id "$USUARIO_ANSIBLE" &>/dev/null; then
    echo "[+] Creando el usuario: $USUARIO_ANSIBLE"
    # Crea el usuario con un directorio home y usando bash por defecto
    sudo useradd -m -s /bin/bash "$USUARIO_ANSIBLE"
    # Le asigna una contraseña temporal (cámbiala si lo deseas)
    echo "$USUARIO_ANSIBLE:AulaAnsible2026" | sudo chpasswd
else
    echo "[*] El usuario $USUARIO_ANSIBLE ya existe."
fi

# 2. Añadir al grupo sudo
echo "[+] Añadiendo $USUARIO_ANSIBLE al grupo sudo..."
sudo usermod -aG sudo "$USUARIO_ANSIBLE"

# 3. Configurar sudo sin contraseña para este usuario específico
echo "[+] Configurando sudo sin contraseña..."
SUDOERS_FILE="/etc/sudoers.d/90-ansible-users"
echo "$USUARIO_ANSIBLE ALL=(ALL) NOPASSWD:ALL" | sudo tee "$SUDOERS_FILE" > /dev/null
sudo chmod 0440 "$SUDOERS_FILE"

# 4. Crear el directorio .ssh y asegurar permisos correctos
echo "[+] Preparando el directorio SSH para el usuario..."
HOME_DIR="/home/$USUARIO_ANSIBLE"
sudo mkdir -p "$HOME_DIR/.ssh"
sudo chmod 700 "$HOME_DIR/.ssh"
sudo touch "$HOME_DIR/.ssh/authorized_keys"
sudo chmod 600 "$HOME_DIR/.ssh/authorized_keys"

# Corregir propietario de la carpeta personal del usuario creado
sudo chown -R "$USUARIO_ANSIBLE:$USUARIO_ANSIBLE" "$HOME_DIR/.ssh"

# 5. Asegurar que el servicio SSH está activo (por si acaso)
echo "[+] Asegurando que el servicio SSH está activo..."
sudo systemctl enable --now ssh

echo "=== ¡Cliente preparado con éxito! ==="
echo "Usuario creado: $USUARIO_ANSIBLE"
echo "Contraseña temporal: AulaAnsible2026"
echo "Ya puedes lanzar 'ssh-copy-id' desde el nodo central."
