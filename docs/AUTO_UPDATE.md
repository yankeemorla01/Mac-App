# ClipShot — Auto-update con Sparkle (Developer ID build)

Desde la 1.3 la app trae embebido [Sparkle 2.9.2](https://sparkle-project.org).
Cuando publiquemos 1.4 (o cualquier futura versión), los usuarios verán un
popup *"ClipShot 1.4 disponible — Instalar y Reiniciar"* y se actualizará solo.

Esta guía es solo para tu **build Developer ID** (el `.dmg` que se distribuye
fuera del Mac App Store). La build del Mac App Store no usa Sparkle —
Apple maneja las actualizaciones automáticamente por ti.

---

## Lo que ya está configurado en la 1.3

- ✅ `Sparkle.framework` embebido en `ClipShot.app/Contents/Frameworks/`
- ✅ Firmado inside-out con Developer ID + hardened runtime + timestamp
- ✅ Notarizado
- ✅ `Info.plist` tiene:
  - `SUFeedURL = https://josegcasadogenao.github.io/clipshot/appcast.xml`
  - `SUPublicEDKey = WEbBbBRnUX8PXRUzhk2OHG4JDbEJRJAfO539CPmTA7k=`
  - `SUEnableAutomaticChecks = true`
  - `SUScheduledCheckInterval = 86400` (1 vez al día)
- ✅ Menú **Preferencias → "Buscar actualizaciones…"** que dispara el chequeo manual
- ✅ Llave privada EdDSA guardada en tu llavero (`sparkle_ed_secret`)

---

## Cómo publicar una versión nueva (ej. 1.4)

### 1. Bumpear versión

Edita `Resources/Info.plist`:
```xml
<key>CFBundleShortVersionString</key>
<string>1.4</string>
<key>CFBundleVersion</key>
<string>1.4</string>
```

Y actualiza el "About" en `src/main.swift`:
```swift
alert.messageText = "ClipShot 1.4"
```

### 2. Build + notarize + DMG

```bash
make release
```

Esto produce `build/ClipShot-1.4.dmg` ya firmado y notarizado.

### 3. Firmar el DMG con Sparkle (EdDSA)

```bash
./vendor/Sparkle/bin/sign_update build/ClipShot-1.4.dmg
```

Te imprime algo así:

```
sparkle:edSignature="MEYCIQDxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx==" length="1843200"
```

Copia ese fragmento — lo necesitas en el siguiente paso.

### 4. Agregar entrada al `appcast.xml`

El feed vive en GitHub Pages, en el repo de la página de marketing. Edita el
`appcast.xml` y agrega una entrada nueva ARRIBA (más recientes primero):

```xml
<item>
    <title>ClipShot 1.4</title>
    <pubDate>Tue, 03 Jun 2026 14:00:00 -0400</pubDate>
    <sparkle:version>1.4</sparkle:version>
    <sparkle:shortVersionString>1.4</sparkle:shortVersionString>
    <sparkle:minimumSystemVersion>13.0</sparkle:minimumSystemVersion>
    <description><![CDATA[
        <h3>Novedades</h3>
        <ul>
            <li>(escribe aquí qué cambió)</li>
        </ul>
    ]]></description>
    <enclosure
        url="https://josegcasadogenao.github.io/clipshot/downloads/ClipShot-1.4.dmg"
        sparkle:edSignature="MEYCIQDxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx=="
        length="1843200"
        type="application/octet-stream"/>
</item>
```

### 5. Subir el DMG y el appcast al sitio

- Sube `ClipShot-1.4.dmg` a `downloads/` del repo de GitHub Pages
- Sube el `appcast.xml` actualizado a la raíz del repo de GitHub Pages
- `git push` — GitHub Pages publica automáticamente

### 6. Listo

Cuando tus usuarios abran ClipShot en las próximas 24 horas, Sparkle verá
la entrada nueva en el `appcast.xml`, validará la firma con el `SUPublicEDKey`
que tienen embebido, y les mostrará el popup.

---

## Estructura inicial del `appcast.xml`

La primera vez, crea este archivo en la raíz del repo de GitHub Pages
`josegcasadogenao.github.io/clipshot`:

```xml
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
    <channel>
        <title>ClipShot updates</title>
        <link>https://josegcasadogenao.github.io/clipshot/appcast.xml</link>
        <description>Auto-update feed for ClipShot Developer ID build.</description>
        <language>en</language>

        <!-- Entradas más recientes primero. Cuando publiques 1.4, ponla arriba de la 1.3. -->

        <item>
            <title>ClipShot 1.3</title>
            <pubDate>Wed, 27 May 2026 09:54:00 -0400</pubDate>
            <sparkle:version>1.3</sparkle:version>
            <sparkle:shortVersionString>1.3</sparkle:shortVersionString>
            <sparkle:minimumSystemVersion>13.0</sparkle:minimumSystemVersion>
            <description><![CDATA[
                <h3>Auto-update integrado</h3>
                <p>A partir de esta versión, ClipShot puede actualizarse automáticamente.</p>
            ]]></description>
            <enclosure
                url="https://josegcasadogenao.github.io/clipshot/downloads/ClipShot-1.3.dmg"
                sparkle:edSignature="(corre sign_update y pega la firma aquí)"
                length="(tamaño en bytes del DMG; lo imprime sign_update)"
                type="application/octet-stream"/>
        </item>

    </channel>
</rss>
```

Para conseguir la firma y el `length` de la 1.3:

```bash
./vendor/Sparkle/bin/sign_update build/ClipShot-1.3.dmg
```

---

## Seguridad — la llave privada

Tu llave privada EdDSA está guardada **en tu llavero de macOS** con la
etiqueta `sparkle_ed_secret`. **Nunca** la pongas en el repo, ni en variables
de entorno expuestas, ni la pierdas — si la pierdes, no podrás publicar
actualizaciones que las versiones existentes acepten como válidas (tendrías
que generar una nueva llave y forzar a todos a reinstalar manualmente).

Para hacer backup, exporta desde Keychain Access (Acceso a Llaveros):
- Busca `ed25519_secret` → click derecho → Exportar → guarda el `.p12` con
  una contraseña fuerte en un lugar seguro.

---

## ¿Y si necesito quitar/recrear la llave?

```bash
# Borra de llavero (irreversible para esa llave):
security delete-generic-password -s "https://sparkle-project.org" -a "ed25519"

# Genera una nueva:
./vendor/Sparkle/bin/generate_keys -p
# Toma la nueva public key y actualízala en Resources/Info.plist (SUPublicEDKey),
# luego haz nuevo release. Pero las versiones viejas YA INSTALADAS verán las firmas
# como inválidas y no podrán actualizarse — tus usuarios tendrán que reinstalar manualmente.
```
