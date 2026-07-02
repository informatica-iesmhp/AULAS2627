# Rol `chocolatey`

## Qué hace
Deja **Chocolatey** instalado y configurado en el equipo. Es el **primer rol** del
playbook porque casi todos los demás instalan software con `win_chocolatey`.

1. Comprueba si existe `C:\ProgramData\chocolatey\bin\choco.exe`.
2. Si no está, **descarga** `community.chocolatey.org/install.ps1` a `C:\Windows\Temp`
   (con `win_get_url`, usando el proxy del aula si toca) y **ejecuta el fichero**,
   forzando TLS 1.2 (`SecurityProtocol -bor 3072`).
3. Calcula el **proxy del aula** según `iac_aula` (variable que fija `roles.yaml`
   en `pre_tasks` a partir del 3er octeto de la IP):
   - `IABD` (`10.0.72.x`) → candidato `http://10.0.72.140:3128`
   - `SMRD` (`10.0.32.x`) → candidato `http://10.0.32.119:3128`
   - cualquier otra red → sin proxy (acceso directo).
4. **Autodetecta si ese proxy es alcanzable** (`Test-NetConnection … -Port 3128
   -InformationLevel Quiet`) y guarda en `choco_proxy_url` la URL **solo si responde**;
   si no, cadena vacía = **salida directa**. Esa misma `choco_proxy_url` se usa tanto
   en la descarga de `install.ps1` (`win_get_url proxy_url`) como en la config de proxy
   de Chocolatey para descargar paquetes. Así el mismo rol vale para un equipo físico
   del aula (detrás del Squid) y para una VM de pruebas con salida directa, aunque su
   IP caiga en la red del aula.

> Mismos proxys que usa el Ubuntu (`3-SetupPrimerInicio.sh`).

## Estructura
- `tasks/main.yml` — sin `defaults/`.

## Notas
- `win_chocolatey` sabe autoinstalar Choco, pero lo hacemos explícito para poder
  fijar el proxy **antes** de la primera descarga de paquetes.
- **No se usa el "download cradle" `iex (New-Object Net.WebClient).DownloadString(...)`**:
  Microsoft Defender lo detecta como `Trojan:Win32/Goptaju.D` (firma AMSI sobre la
  línea de comandos que genera `win_shell` como `-encodedcommand`), mata el proceso y
  la API devuelve `CreateProcessW() Access denied (Win32ErrorCode 5)`. Síntoma típico:
  `Gathering Facts`/`win_stat`/`win_ping` van bien (no lanzan ese patrón) pero la tarea
  de instalar Choco falla con *Access denied*. **No es UAC ni permisos** (el token SSH
  es de integridad alta) ni ASR/CFA; es la firma AMSI. Como Tamper Protection suele
  estar activo, no se puede bajar Defender por script: la solución es bajar `install.ps1`
  a fichero y ejecutarlo (no matchea la firma). Ver evento Defender 1116/1117.
- **Proxy autodetectado**: el proxy del aula solo se usa si responde en el puerto
  3128 (`choco_proxy_host` → `Test-NetConnection` → `choco_proxy_url`). Una VM de
  pruebas en `10.0.72.x` con salida directa (Squid no alcanzable, `TcpTestSucceeded
  = False`) cae automáticamente a descarga directa y se le **quita** el proxy de Choco.
- Si añades un aula nueva, actualiza `choco_proxy_host` (la condición del proxy en
  `tasks/main.yml`) y la detección de `iac_aula` en `roles.yaml`.
