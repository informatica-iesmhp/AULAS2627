import paramiko
import re
import os

def obtener_historial_conexiones(ip, usuario_ssh, password_ssh=None, puerto=22):
    """
    Se conecta via SSH. 
    - Si password_ssh es None, intentará usar las claves RSA/Ed25519 del usuario actual (~/.ssh/).
    """
    client = paramiko.SSHClient()
    # Acepta automáticamente la huella del servidor si es la primera vez (Cuidado en prod)
    client.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    
    lista_conexiones = []

    try:
        print(f"Conectando a {ip} con usuario '{usuario_ssh}'...")
        
        # Intentamos conectar. 
        # Si password_ssh es None, Paramiko buscará llaves locales o usará ssh-agent.
        client.connect(
            hostname=ip, 
            username=usuario_ssh, 
            password=password_ssh, 
            port=puerto,
            look_for_keys=True,  # Busca en ~/.ssh/id_rsa, etc.
            allow_agent=True     # Usa el agente SSH si está activo
        )
        
        # Ejecutamos 'last -F -i' (Fechas completas e IP)
        stdin, stdout, stderr = client.exec_command('last -F -i')
        
        # Leemos la salida y posibles errores
        salida = stdout.read().decode('utf-8')
        error = stderr.read().decode('utf-8')

        if error:
            print(f"Advertencia del servidor: {error}")

        # Procesamiento de texto (Parsing)
        lines = salida.split('\n')
        for line in lines:
            if not line.strip() or line.startswith('wtmp starts'):
                continue
            
            # Regex para capturar: Usuario, TTY, IP y el resto (fechas)
            parts = re.match(r'^(\S+)\s+(\S+)\s+(\S+)\s+(.+)', line)
            
            if parts:
                user = parts.group(1)
                tty = parts.group(2)
                origen_ip = parts.group(3)
                resto_fechas = parts.group(4)
                
                # Clasificación del tipo de conexión
                tipo = "Desconocido"
                if ":0" in tty or "tty" in tty:
                    tipo = "Local (Gráfica/Consola)"
                elif "pts" in tty:
                    # Si tiene IP suele ser SSH, si no, terminal local
                    if origen_ip == "0.0.0.0" or origen_ip == "-":
                         tipo = "Terminal Local (pts)"
                    else:
                         tipo = f"Remota (SSH/xRDP) [{origen_ip}]"
                elif ":" in tty and tty != ":0":
                    tipo = "Escritorio Remoto (xRDP/VNC)"
                
                # Limpieza de fechas
                if "still logged in" in resto_fechas:
                    inicio = resto_fechas.split("still logged in")[0].strip()
                    fin = "ACTIVO"
                elif "down" in resto_fechas or "crash" in resto_fechas:
                    inicio = resto_fechas.split("-")[0].strip() if "-" in resto_fechas else resto_fechas
                    fin = "Sistema OFF/Crash"
                else:
                    try:
                        fechas_split = resto_fechas.split(" - ")
                        inicio = fechas_split[0].strip()
                        # Quitamos la duración entre paréntesis (00:23)
                        fin = re.sub(r'\s*\(.*\)', '', fechas_split[1]).strip()
                    except:
                        inicio = resto_fechas
                        fin = "?"

                lista_conexiones.append({
                    'usuario': user,
                    'tipo': tipo,
                    'tty': tty,
                    'ip': origen_ip,
                    'inicio': inicio,
                    'fin': fin
                })

    except paramiko.AuthenticationException:
        print("Error: Falló la autenticación. Verifica tu clave SSH o contraseña.")
    except paramiko.SSHException as e:
        print(f"Error de protocolo SSH: {e}")
    except Exception as e:
        print(f"Error general: {e}")
    finally:
        client.close()
        
    return lista_conexiones

# --- EJEMPLO DE USO ---
if __name__ == "__main__":
    # Configuración
    IP_DESTINO = "10.0.32.120"  # Pon la IP de tu Linux Mint
    USUARIO = "root"  # El usuario en la máquina destino
    
    # LLAMADA SIN CONTRASEÑA (Usará ~/.ssh/id_rsa automáticamente)
    resultado = obtener_historial_conexiones(IP_DESTINO, USUARIO)

    # Imprimir resultados
    print(f"{'USUARIO':<12} | {'TIPO':<35} | {'INICIO':<25} | {'FIN'}")
    print("-" * 90)
    
    for con in resultado:
        if con['usuario'] not in ['reboot', 'shutdown']:
            print(f"{con['usuario']:<12} | {con['tipo']:<35} | {con['inicio']:<25} | {con['fin']}")