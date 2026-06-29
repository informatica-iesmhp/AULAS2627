# Rol `horaHTTP`

## Qué hace
Mantiene la hora del sistema **correcta en cada arranque** (y periódicamente),
aunque el NTP esté bloqueado.

### Por qué hace falta
- En las aulas el **UDP 123 (NTP) está filtrado**, así que `systemd-timesyncd`
  nunca confirma `NTPSynchronized=yes`.
- En **VMware con host Windows** el RTC lleva hora local pero Linux lo
  interpreta como UTC: tras cada reinicio el reloj vuelve a desajustarse.
- Los scripts `0b-Github.sh`, `1-SetupLiveCD.sh` y `3-SetupPrimerInicio.sh` solo
  corrigen la hora **durante la instalación/primer arranque**; `3-Setup...` se
  autodeshabilita, así que no hay nada que recorrija la hora en arranques
  posteriores. Este rol cubre justo ese hueco.

### Cómo lo hace
Instala tres artefactos (idempotente, vía `template`):

1. **`{{ horahttp_script }}`** (`/usr/local/sbin/iac-sincroniza-hora.sh`) — el
   mismo algoritmo que los scripts de instalación:
   - `timedatectl set-timezone` + `set-ntp true` + reinicia `systemd-timesyncd`;
   - espera a NTP (`horahttp_ntp_intentos` × 2 s);
   - si NTP no cuaja → **fallback HTTP**: `curl -sI` (o `wget -SqO` si no hay
     curl) a las URLs de `horahttp_urls`, extrae la cabecera `Date:` (GMT) y la
     fija con `date -s`; luego `hwclock --systohc` para propagar al RTC.
   - Registra todo con `logger -t iac-hora` (se ve con `journalctl -t iac-hora`).
2. **`iac-sincroniza-hora.service`** (oneshot, `After=network-online.target`,
   `WantedBy=multi-user.target`) → ejecuta el script **en cada arranque**.
3. **`iac-sincroniza-hora.timer`** → re-ejecuta el script cada
   `horahttp_timer_intervalo` (deriva en equipos con mucho uptime).

El rol además habilita y **arranca el service en el momento** (`state: started`),
así que corrige la hora durante el propio `ansible-playbook` (un `oneshot` que
puede tardar hasta ~30 s si NTP está bloqueado, por la espera previa al HTTP).

## Estructura
- `tasks/main.yml` — instala curl, fija zona, despliega script + unidades, habilita service y timer.
- `defaults/main.yml` — `horahttp_zona`, `horahttp_urls`, `horahttp_ntp_intentos`, `horahttp_timer_intervalo`, rutas (`horahttp_script`, `horahttp_unidad`).
- `templates/` — `iac-sincroniza-hora.sh.j2`, `iac-sincroniza-hora.service.j2`, `iac-sincroniza-hora.timer.j2`.

## Notas
- **En máquinas virtuales VMware: activar "Synchronize guest time with host"**
  (Settings → Options → VMware Tools). Hace que el host mantenga la hora del guest
  correcta sin depender del NTP del aula (UDP 123 filtrado) y evita la deriva del
  RTC entre reinicios. **Complementa** a este rol (no lo sustituye): el rol cubre
  los equipos físicos y los arranques donde el host no ajusta la hora. Requiere
  `open-vm-tools` instalado. Relevante sobre todo si el equipo se une a un dominio
  AD (Kerberos exige <5 min de desfase con el DC — ver
  [`../preparaAD/CLAUDE.md`](../preparaAD/CLAUDE.md)).
- **Idempotente** salvo el `state: started` del service (re-lanza el oneshot en
  cada ejecución del playbook para garantizar hora correcta; no marca el sistema
  como roto si falla, el script termina siempre con `exit 0`).
- No depende de colecciones externas (`community.general`): usa
  `ansible.builtin.command` para la zona y `ansible.builtin.systemd`.
- Diagnóstico en el equipo: `journalctl -t iac-hora`,
  `systemctl status iac-sincroniza-hora.service`,
  `systemctl list-timers iac-sincroniza-hora.timer`.
- Si algún día el NTP deja de estar filtrado, el rol sigue siendo correcto: el
  fallback HTTP simplemente no se usa (NTP confirma primero).
