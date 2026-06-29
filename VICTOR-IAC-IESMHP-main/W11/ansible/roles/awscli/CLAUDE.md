# Rol `awscli`

## Qué hace
Instala **AWS CLI** (v2) con Chocolatey (`awscli`). Sin versión fija.

## Estructura
- `tasks/main.yml` — sin `defaults/`.

## Notas
- Solo instala el binario; la configuración de credenciales (`aws configure`) es
  por usuario y no la toca este rol. Alternativa: winget `Amazon.AWSCLI`.
