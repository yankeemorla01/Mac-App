# Política de privacidad de ClipShot

**Fecha de vigencia**: 23 de mayo de 2026
**Última actualización**: 23 de mayo de 2026

ClipShot está diseñada con un principio: **tus datos son tuyos y solo tuyos**. Esta política explica exactamente qué hace ClipShot con tu información y qué NO hace.

## Qué datos accede ClipShot

ClipShot lee los siguientes datos **solo localmente en tu Mac**:

- **Imágenes en el portapapeles**: cuando copias una imagen o tomas un screenshot al portapapeles, ClipShot la detecta para guardarla en su historial.
- **Archivos de screenshots**: ClipShot vigila la carpeta donde macOS guarda los screenshots (por defecto el Escritorio) para detectar capturas nuevas.
- **Preferencia del sistema `com.apple.screencapture/show-thumbnail`**: ClipShot la modifica solo en el modo "guardado instantáneo" y la restaura al cerrarse.

## Qué hace ClipShot con esos datos

- **Guarda screenshots e imágenes copiadas localmente** en `~/Library/Application Support/ClipShot/history/`, organizados por mes/año.
- **Mantiene un historial de las últimas 30 capturas** accesible desde la barra de menú.
- **NO envía nada a internet**. Nunca. ClipShot no contiene ningún cliente HTTP, socket, ni SDK de analítica.

## Qué NO hace ClipShot

- ❌ NO envía tus screenshots a ningún servidor.
- ❌ NO envía telemetría, métricas de uso, ni reportes de crash automáticos.
- ❌ NO sincroniza con iCloud, Dropbox, ni ninguna nube por defecto.
- ❌ NO tiene cuentas de usuario, login, ni autenticación.
- ❌ NO comparte tus datos con terceros — los desarrolladores no tienen acceso a tu información.
- ❌ NO usa cookies, IDs publicitarios, ni fingerprinting.

## Logs

ClipShot escribe un archivo de log técnico en `~/Library/Logs/ClipShot.log` (rotado a 1 MB máx, permisos 0600 — solo tu usuario puede leerlo). Contiene únicamente eventos técnicos no-PII como: timestamps de cambios de configuración, errores de E/S, y advertencias internas. Nunca contiene contenido de imágenes ni rutas que revelen actividad del usuario.

## Eliminación de datos

Puedes borrar tu historial en cualquier momento desde el menú **ClipShot → Limpiar historial**, con opciones para borrar todo o solo capturas de más de 30 días. La desinstalación de la app elimina automáticamente sus datos al borrar `~/Library/Application Support/ClipShot/`.

## Permisos del sistema

ClipShot puede pedir permisos de macOS para acceder al Escritorio, Descargas, Documentos o Imágenes — solo si has configurado macOS para guardar screenshots ahí. Estos permisos los gestiona macOS, no la app, y se otorgan/revocan en **Ajustes del Sistema → Privacidad y seguridad**.

## Cambios

Esta política puede actualizarse en futuras versiones. La fecha "Última actualización" arriba refleja la última modificación. Cambios materiales serán comunicados en las release notes de la versión correspondiente.

## Contacto

Para preguntas sobre privacidad o seguridad: abre un issue en el repositorio del proyecto.

---

Esta política aplica a ClipShot v1.0 y posteriores. Versiones futuras pueden añadir features opcionales (ej. sync a iCloud), siempre con opt-in explícito y esta política actualizada.
