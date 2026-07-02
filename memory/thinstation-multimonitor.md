---
name: thinstation-multimonitor
description: En ThinStation-NG 7.2 las variables SET_RESOLUTION_MULTIMONITOR_* están muertas; el multimonitor real va por USE_XRANDR/XRANDR_OPTIONS
metadata:
  type: reference
---

En ThinStation-NG 7.2, las variables `SET_RESOLUTION_MULTIMONITOR_EXPAND` y `SET_RESOLUTION_MULTIMONITOR_AUTOSCALE` que aparecen en las plantillas de `conf/*/thinstation.conf.buildtime` **no las lee ningún script** (solo existen en las plantillas) — son inertes/legacy.

El multimonitor real lo controla la función `use_xrandr()` en `packages/base/etc/thinstation.functions` (chroot: `/build/packages/...`):
- `USE_XRANDR=On` + `XRANDR_OPTIONS="dualscreen"` → autodetecta monitores conectados con `xrandr -q`.
  - 2 monitores → EXTIENDE el escritorio (`--output out1 --left-of out2 --primary ...`).
  - Si NO se fija `SCREEN_RESOLUTION`, no pasa `--mode`, así cada monitor usa su resolución nativa (ideal para monitores heterogéneos).
  - 1 monitor (VM/puesto simple) → `-s $SCREEN_RESOLUTION` normal.
- `XRANDR_OPTIONS` vacío → `-s $SCREEN_RESOLUTION`; cualquier otro valor se pasa verbatim a `xrandr`.

Verificado también: `KEYMAP`/`KEYBOARD_MAP`/`X_KEYBSEL` NO existen en 7.2; el teclado/locale español va solo con `LOCALE=es_ES` + `package locale-es_ES`. La compilación es solo-Fedora (dnf + root real). Tutorial verificado en [[../ThinStation/CLAUDE.md]].
