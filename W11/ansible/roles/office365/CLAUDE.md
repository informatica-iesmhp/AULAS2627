# Rol `office365`

## Qué hace
Instala **Microsoft 365 Apps** (Office) con Chocolatey (`office365business` por
defecto, que internamente usa la *Office Deployment Tool*).

## Estructura
- `tasks/main.yml`
- `defaults/main.yml` → `office_choco_name` (`office365business` / `office365proplus`).

## Notas / TODO
- **Licencia**: instala las aplicaciones, pero **activarlas** requiere iniciar
  sesión con una cuenta Microsoft 365 con licencia. Este rol no activa nada.
- Si se necesita un canal/idioma/edición concretos, lo más controlable es pasar un
  `configuration.xml` de la ODT; se puede ampliar el rol con `package_params`.
- Alternativa: winget `Microsoft.Office`.
