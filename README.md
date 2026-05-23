# ClipShot

Aplicación de barra de menú para macOS que guarda automáticamente cada screenshot en un historial local, accesible al instante desde la barra superior.

## Características

- **Captura automática** desde el portapapeles y desde la carpeta de screenshots de macOS
- **Historial visual** con miniaturas, accesible desde la barra de menú
- **Miniatura flotante** propia (igual a la de Apple) — click para editar en Vista Previa, arrastrar para mover el archivo
- **Organización por mes/año**: los archivos se guardan en `~/Library/Application Support/ClipShot/history/<Mes Año>/Captura YYYY-MM-DD a las HH-MM-SS_xxxxxx.png`
- **Dos modos**: instantáneo (recomendado) o conservar el comportamiento de Apple (~5s)
- **Preferencias completas**: toggle de miniatura, abrir al iniciar sesión, etc.
- **Privacidad total**: 100% local, sin internet, sin telemetría

## Estructura del proyecto

```
Mac App/
├── src/
│   └── main.swift              # Código fuente único
├── Resources/
│   ├── Info.plist              # Bundle metadata
│   ├── icon.svg                # Fuente del icono
│   ├── AppIcon.icns            # Icono compilado
│   └── AppIcon.iconset/        # Tamaños individuales
├── scripts/
│   ├── build.sh                # Compila .app en build/
│   ├── install.sh              # Copia a /Applications y abre
│   ├── regen_icon.sh           # Re-genera AppIcon.icns desde icon.svg
│   └── render_icon.swift       # Helper SVG → PNG
├── docs/
│   ├── APPSTORE.md             # Checklist completo para Mac App Store
│   └── SECURITY.md             # Auditoría de seguridad
├── assets/
│   ├── source/                 # Fuentes originales
│   ├── appstore/               # Assets para envío a App Store
│   └── marketing/              # Material de marketing
├── build/                      # .app generado (gitignored)
├── Makefile
└── README.md
```

## Instalación rápida

```bash
make install
```

Esto compila la app, la copia a `/Applications/ClipShot.app` y la abre. La primera vez verás una ventana de bienvenida de 6 pasos para configurarla.

## Comandos

| Comando             | Acción                                                          |
|---------------------|-----------------------------------------------------------------|
| `make build`        | Compila la app en `build/ClipShot.app`                          |
| `make install`      | Compila + copia a `/Applications` + abre                        |
| `make icon`         | Regenera `AppIcon.icns` desde `Resources/icon.svg`              |
| `make clean`        | Borra `build/`                                                  |

## Requisitos

- macOS 12.0 o superior (arm64 / Apple Silicon)
- Xcode Command Line Tools (`xcode-select --install`)

## Privacidad

Toda la actividad de ClipShot ocurre localmente en tu Mac. No hay servidores, no hay cuentas, no hay telemetría. Los desarrolladores no tienen ningún acceso a tus imágenes ni a tu actividad.

## Licencia

Privado — todos los derechos reservados.
