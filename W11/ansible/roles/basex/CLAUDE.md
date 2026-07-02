# Rol `basex`

## Qué hace
Instala **BaseX** (base de datos XML, aplicación Java) por **descarga directa**,
porque no está bien empaquetada en Chocolatey/winget:

1. (Opcional) Instala un **JRE** (Temurin) con Choco, ya que BaseX necesita Java.
2. Comprueba si ya existe `…\basex\bin\basex.bat`.
3. Descarga el ZIP oficial de `files.basex.org` y lo descomprime en
   `C:\Program Files`.
4. Añade `…\basex\bin` al **PATH** del sistema.

## Estructura
- `tasks/main.yml`
- `defaults/main.yml` → `basex_version` (`12.4`), `basex_url`, `basex_dest`,
  `basex_dir`, `basex_instala_java`, `basex_java_choco_name`.

## Notas / TODO
- **Verificar `basex_url`**: el patrón es
  `https://files.basex.org/releases/<ver>/BaseX<verSinPuntos>.zip`
  (p.ej. `…/12.4/BaseX124.zip`). Confirmar que la versión deseada existe ahí.
- Si prefieres no depender del JRE Temurin, pon `basex_instala_java: false` y
  asegúrate de que el equipo ya tiene Java.
- Este rol es el **patrón a copiar** para cualquier programa que no esté en
  Choco/winget (descarga directa del instalador/ZIP oficial).
