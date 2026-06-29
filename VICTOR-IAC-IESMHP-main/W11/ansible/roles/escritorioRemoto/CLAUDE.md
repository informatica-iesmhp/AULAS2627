# Rol `escritorioRemoto`

## Qué hace
Habilita el **Escritorio Remoto (RDP)** de Windows. No instala nada; toca registro
y firewall:

1. `fDenyTSConnections=0` → permite conexiones RDP entrantes.
2. `UserAuthentication={{ rdp_nla }}` (por defecto `1`) → exige **NLA**.
3. Activa el **grupo de reglas de firewall** de Escritorio Remoto por su id
   (`@FirewallAPI.dll,-28752`), que es independiente del idioma de Windows.

## Estructura
- `tasks/main.yml`
- `defaults/main.yml` → `rdp_nla` (1 = exigir NLA; 0 = no).

## Notas
- El equivalente en Ubuntu es el rol `rdp` (servidor RDP nativo de GNOME).
- Para dar acceso a un usuario no administrador habría que añadirlo al grupo
  "Usuarios de escritorio remoto" (no lo hace este rol).
