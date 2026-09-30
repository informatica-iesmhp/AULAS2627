# Escritorio remoto (xrdp) en el PC del profesor — IF01-IF04

**Fecha:** 2026-09-30 · **Estado:** sin probar en hardware real (probar primero en IF03).

## Decisión
RDP solo en el equipo del profesor (`*-00`) de cada aula. Los equipos de alumnos no llevan servicio de escritorio remoto: a ellos se llega desde el PC del profesor con Veyon (gráfico) y Ansible (SSH). Es como la recepción de un hotel: una sola puerta con acceso desde fuera, y dentro están las llaves maestras.

## Cambios respecto al playbook anterior (04/08 sin probar)
- `hosts: "*-00"`: solo el PC del profesor, aunque el inventario tenga toda el aula.
- Ya no activa ufw por defecto (`firewall_modo: nft`): una tabla nftables propia que solo filtra el 3389/TCP (permitido desde `rdp_redes_permitidas` y loopback; descartado para el resto). No toca SSH, Veyon ni nada más, y es compatible con activar ufw más adelante. `ufw` queda como opción; `ninguno` solo para pruebas.
- Acceso por grupo del AD (`pam_succeed_if ... ingroup grupoprofesores`) en vez de lista de usuarios por aula: el mismo grupo que da acceso a la clave de Veyon, así Veyon Master funciona dentro de la sesión RDP.
- Root no puede entrar por RDP (`AllowRootLogin=false`).
- Regla polkit para evitar los avisos de colord en sesiones RDP.
- Handlers en vez de reiniciar xrdp siempre; comprobación final de que escucha en 3389.

## Pendiente
- Probar en IF03 (sesión Cinnamon por xrdp, pantalla negra, Veyon Master dentro de la sesión).
- Comprobar que `getent group grupoprofesores` lista los miembros vía SSSD.
- Un mismo usuario no debe tener a la vez sesión local y RDP en el mismo equipo.
- Decidir cómo se accede desde el resto del centro (VLAN por aula → enrutamiento/ACL entre VLAN, o salto por SSH).

## Playbook
```yaml
---
# 08_habilitar_escritorio_remoto.yml
# ---------------------------------------------------------------------------
# Escritorio remoto (RDP con xrdp) SOLO en el equipo del profesor de cada
# aula (los que terminan en -00). Los equipos de alumnos no se tocan: a
# ellos se llega desde el PC del profesor con Veyon (gráfico) y Ansible (SSH).
#
# Analogía: el PC del profesor es la recepción del hotel. Es la única puerta
# con acceso desde fuera del aula; una vez dentro, Veyon y Ansible son las
# llaves maestras del resto de habitaciones.
#
# Cómo funciona:
#   - xrdp + xorgxrdp: cada conexión remota abre una sesión gráfica NUEVA,
#     independiente de la que haya en el monitor físico. Si alguien está
#     dando clase, otro profesor puede entrar en remoto sin pisarle.
#   - Solo pueden entrar por RDP los miembros de un grupo del AD
#     (xrdp_grupo_permitido, por defecto el mismo "grupoprofesores" que ya da
#     acceso a la clave de Veyon). Así, quien entra por RDP puede además
#     abrir Veyon Master en esa sesión. Dar o quitar acceso = gestionarlo en
#     el AD, no tocar los PCs.
#   - Root nunca puede entrar por RDP.
#
# Cortafuegos (variable firewall_modo):
#   - "nft" (POR DEFECTO): NO activa ufw ni ningún cortafuegos general. Crea
#     una tabla nftables propia y mínima que solo filtra el puerto 3389:
#     lo permite desde rdp_redes_permitidas y desde el propio equipo
#     (loopback, para túneles SSH), y lo descarta para el resto. Todo lo
#     demás (SSH, Veyon, WoL, comparte-aula...) sigue exactamente igual.
#     Es compatible con activar ufw más adelante: son tablas distintas.
#   - "ninguno": no filtra nada. RDP abierto a cualquiera que llegue por red
#     (solo protegido por usuario/contraseña del AD). Solo para pruebas.
#   - "ufw": el comportamiento del playbook antiguo (activa ufw, abre
#     OpenSSH y 3389 desde rdp_redes_permitidas). Para cuando se termine de
#     diseñar el cortafuegos de las aulas: ojo, en ese momento habrá que
#     abrir también Veyon (11100/TCP) y lo demás que se use.
#
# Uso (primero en UN aula, mejor IF03 que ya tiene Veyon validado):
#
#   ansible-playbook -i inventarios/if03.ini playbooks/08_habilitar_escritorio_remoto.yml \
#       -u ansible-admin -e '{"rdp_redes_permitidas": ["10.0.10.0/24"]}'
#
# Mejor aún: define las variables en group_vars (p.ej. group_vars/all.yml):
#
#   rdp_redes_permitidas:
#     - 10.0.10.0/24     # <-- AJUSTA: redes/VLAN desde las que se permite RDP
#   xrdp_grupo_permitido: grupoprofesores
#
# El playbook solo actúa sobre los hosts cuyo nombre termina en "-00"
# aunque el inventario tenga todo el aula, así que no hace falta --limit.
# ---------------------------------------------------------------------------

- name: Escritorio remoto (xrdp) solo en el equipo del profesor
  hosts: "*-00"
  become: true
  gather_facts: false

  vars:
    firewall_modo: nft                     # nft | ninguno | ufw
    rdp_redes_permitidas: []               # lista de CIDR, p.ej. ["10.0.10.0/24"]
    xrdp_grupo_permitido: grupoprofesores  # grupo del AD autorizado a entrar por RDP
    rdp_puerto: 3389

  handlers:
    - name: Reiniciar xrdp
      ansible.builtin.systemd:
        name: xrdp
        state: restarted

    - name: Recargar restricción RDP
      ansible.builtin.systemd:
        name: xrdp-restriccion
        state: restarted
        daemon_reload: true

  tasks:
    # ---------------------------------------------------------------- checks
    - name: Comprobar el modo de cortafuegos
      ansible.builtin.assert:
        that: firewall_modo in ['nft', 'ninguno', 'ufw']
        fail_msg: "firewall_modo debe ser nft, ninguno o ufw (es '{{ firewall_modo }}')."
      run_once: true

    - name: Exigir redes permitidas si se filtra el puerto RDP
      ansible.builtin.assert:
        that: rdp_redes_permitidas | length > 0
        fail_msg: >-
          rdp_redes_permitidas está vacía. Indica las redes (CIDR) desde las
          que se permitirá RDP, o usa firewall_modo=ninguno solo para pruebas.
      run_once: true
      when: firewall_modo != 'ninguno'

    - name: Comprobar que el grupo del AD se resuelve en el equipo (SSSD)
      ansible.builtin.command: getent group {{ xrdp_grupo_permitido }}
      register: grupo_ad
      changed_when: false
      failed_when: grupo_ad.rc != 0

    - name: Avisar si el grupo aparece sin miembros (pam_succeed_if los necesita)
      ansible.builtin.debug:
        msg: >-
          OJO: 'getent group {{ xrdp_grupo_permitido }}' no lista miembros.
          Comprueba en este equipo con 'getent group' e 'id <profesor>' que
          SSSD devuelve los miembros; si no, nadie podrá entrar por RDP.
      when: grupo_ad.stdout.split(':')[-1] | length == 0

    # ------------------------------------------------------------------ xrdp
    - name: Instalar xrdp y xorgxrdp (sesión propia, no comparte pantalla)
      ansible.builtin.apt:
        name:
          - xrdp
          - xorgxrdp
        state: present
        update_cache: true
        cache_valid_time: 3600

    - name: Añadir el usuario xrdp al grupo ssl-cert (certificado TLS)
      ansible.builtin.user:
        name: xrdp
        groups: ssl-cert
        append: true
      notify: Reiniciar xrdp

    - name: Prohibir el acceso de root por RDP
      community.general.ini_file:
        path: /etc/xrdp/sesman.ini
        section: Security
        option: AllowRootLogin
        value: "false"
        no_extra_spaces: true
        mode: "0644"
      notify: Reiniciar xrdp

    - name: Permitir RDP solo al grupo del AD autorizado (PAM)
      ansible.builtin.blockinfile:
        path: /etc/pam.d/xrdp-sesman
        marker: "# {mark} ANSIBLE MANAGED BLOCK -- acceso RDP por grupo"
        insertafter: '^#%PAM-1.0'
        block: |
          account required pam_succeed_if.so user ingroup {{ xrdp_grupo_permitido }}

    - name: 'Cinnamon + xrdp: desactivar cursor por hardware (evita pantalla negra)'
      ansible.builtin.lineinfile:
        path: /etc/xrdp/startwm.sh
        insertafter: '^#!'
        line: "export MUFFIN_DISABLE_HW_CURSOR=1"

    - name: Evitar las ventanas de "Autenticación requerida" de colord en sesiones RDP
      ansible.builtin.copy:
        dest: /etc/polkit-1/rules.d/45-xrdp-colord.rules
        mode: "0644"
        content: |
          // Generado por 08_habilitar_escritorio_remoto.yml
          polkit.addRule(function(action, subject) {
              if (action.id.indexOf("org.freedesktop.color-manager.") == 0 &&
                  subject.isInGroup("{{ xrdp_grupo_permitido }}")) {
                  return polkit.Result.YES;
              }
          });

    - name: Habilitar y arrancar xrdp
      ansible.builtin.systemd:
        name: xrdp
        state: started
        enabled: true

    # ------------------------------------------- cortafuegos: modo "nft"
    - name: "[nft] Instalar nftables (solo el comando nft; no se activa nftables.service)"
      ansible.builtin.apt:
        name: nftables
        state: present
      when: firewall_modo == 'nft'

    - name: "[nft] Reglas mínimas: puerto RDP solo desde las redes permitidas"
      ansible.builtin.copy:
        dest: /etc/xrdp/restriccion-rdp.nft
        mode: "0644"
        content: |
          #!/usr/sbin/nft -f
          # Generado por 08_habilitar_escritorio_remoto.yml -- no editar a mano.
          # Solo afecta al puerto {{ rdp_puerto }}/TCP. No es un cortafuegos general.
          table inet xrdp_restriccion {}
          delete table inet xrdp_restriccion
          table inet xrdp_restriccion {
              set redes_permitidas {
                  type ipv4_addr
                  flags interval
                  elements = { {{ rdp_redes_permitidas | join(', ') }} }
              }
              chain entrada {
                  type filter hook input priority 0; policy accept;
                  iif "lo" tcp dport {{ rdp_puerto }} accept
                  ip saddr @redes_permitidas tcp dport {{ rdp_puerto }} accept
                  tcp dport {{ rdp_puerto }} drop
              }
          }
      when: firewall_modo == 'nft'
      notify: Recargar restricción RDP

    - name: "[nft] Servicio que aplica la restricción en cada arranque"
      ansible.builtin.copy:
        dest: /etc/systemd/system/xrdp-restriccion.service
        mode: "0644"
        content: |
          [Unit]
          Description=Restringe el puerto RDP (xrdp) a las redes permitidas
          After=nftables.service
          Before=xrdp.service

          [Service]
          Type=oneshot
          RemainAfterExit=yes
          ExecStart=/usr/sbin/nft -f /etc/xrdp/restriccion-rdp.nft
          ExecStop=/usr/sbin/nft delete table inet xrdp_restriccion

          [Install]
          WantedBy=multi-user.target
      when: firewall_modo == 'nft'
      notify: Recargar restricción RDP

    - name: "[nft] Habilitar y arrancar la restricción"
      ansible.builtin.systemd:
        name: xrdp-restriccion
        state: started
        enabled: true
        daemon_reload: true
      when: firewall_modo == 'nft'

    # -------------------- si se cambia de modo, quitar la restricción nft
    - name: Quitar la restricción nft si ya no se usa ese modo
      when: firewall_modo != 'nft'
      block:
        - name: Parar y deshabilitar xrdp-restriccion (si existe)
          ansible.builtin.systemd:
            name: xrdp-restriccion
            state: stopped
            enabled: false
          failed_when: false

        - name: Borrar ficheros de la restricción nft
          ansible.builtin.file:
            path: "{{ item }}"
            state: absent
          loop:
            - /etc/systemd/system/xrdp-restriccion.service
            - /etc/xrdp/restriccion-rdp.nft

    # ------------------------------------------- cortafuegos: modo "ufw"
    - name: "[ufw] Mantener SSH permitido ANTES de activar ufw"
      community.general.ufw:
        rule: allow
        name: OpenSSH
      when: firewall_modo == 'ufw'

    - name: "[ufw] Abrir RDP solo desde las redes permitidas"
      community.general.ufw:
        rule: allow
        port: "{{ rdp_puerto | string }}"
        proto: tcp
        from_ip: "{{ item }}"
      loop: "{{ rdp_redes_permitidas }}"
      when: firewall_modo == 'ufw'

    - name: "[ufw] Activar ufw (RECUERDA abrir también Veyon y el resto de servicios)"
      community.general.ufw:
        state: enabled
        logging: low
      when: firewall_modo == 'ufw'

    # ------------------------------------------------------- comprobación
    - name: Comprobar que xrdp escucha en el puerto RDP
      ansible.builtin.wait_for:
        port: "{{ rdp_puerto }}"
        timeout: 15

- name: Aviso final
  hosts: localhost
  connection: local
  gather_facts: false
  tasks:
    - name: Recordatorio
      ansible.builtin.debug:
        msg: >-
          xrdp activo en los equipos de profesor (-00). Prueba con un cliente
          RDP contra la IP del -00 usando una cuenta de dominio del grupo
          autorizado que NO tenga sesión abierta en ese momento en ese equipo.
          Si sale pantalla negra, revisa /var/log/xrdp-sesman.log y
          /var/log/xrdp.log. Para ver la restricción de red:
          sudo nft list table inet xrdp_restriccion
```
