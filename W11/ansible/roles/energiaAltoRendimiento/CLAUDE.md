# Rol `energiaAltoRendimiento`

## Qué hace
Configura la **energía** del equipo. No instala nada; usa `powercfg`:

1. Activa el plan de energía **"Alto rendimiento"** (GUID
   `8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c`, fijo e independiente del idioma de
   Windows) — solo si no es ya el plan activo (idempotente).
2. **Desactiva la suspensión** del equipo (`standby-timeout-ac 0` y
   `standby-timeout-dc 0`) → equivale a "Poner al equipo en estado de suspensión:
   **Nunca**" en el Panel de control.

No toca el apagado de pantalla (`monitor-timeout`): se deja como esté.

## Estructura
- `tasks/main.yml`
- `defaults/main.yml` → `energia_plan_guid` (GUID del plan a activar; por defecto
  "Alto rendimiento". Sobreescribir con el de "Rendimiento máximo"
  `e9a42b02-d5df-448d-aa00-03f14749eb61` si se quisiera).

## Notas
- Idempotencia: `powercfg /setactive` siempre devuelve `rc 0`, así que el rol
  compara primero con `powercfg /getactivescheme` y solo reporta *changed* si hay
  que cambiar de plan. Las tareas de `powercfg /change` van con
  `changed_when: false` (igual que el `Enable-NetFirewallRule` de
  [`escritorioRemoto`](../escritorioRemoto/CLAUDE.md)).
- En equipos de sobremesa no hay batería, por lo que el ajuste `-dc` es inocuo;
  se aplica igualmente para cubrir portátiles.
- En Windows 11 el plan "Alto rendimiento" puede estar oculto en el Panel de
  control, pero sigue siendo activable por su GUID con `powercfg /setactive`.
