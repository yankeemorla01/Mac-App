# ClipShot — Recomendaciones para el próximo lanzamiento

Documento consolidado de los 3 análisis realizados (App Store, assets, seguridad) más la organización del proyecto.

---

## 0. Estado actual

✅ **Proyecto organizado** — estructura limpia, `make install` funciona, README escrito.
✅ **Seguridad: 3 fixes aplicados al código** — backup/restore del `show-thumbnail` original, validación `kMDItemIsScreenCapture` + creación reciente, rotación del log a 1 MB.
⚠️ **Sin Developer ID** — la app está firmada ad-hoc; cualquier usuario verá una advertencia de Gatekeeper al instalarla.
⚠️ **No sandboxed** — bloquea el camino directo al Mac App Store.

---

## 1. Decisión estratégica: dos caminos posibles

Antes de seguir, decide qué camino tomar. Cada uno tiene trade-offs muy distintos:

### Camino A — Distribución directa (DMG / web download)

**Quién**: tú regalas o vendes el `.dmg` directamente.
**Pros**: rápido (1–3 días), funcionalidad completa (modo instantáneo + reemplazo de miniatura de Apple).
**Contras**: necesitas Developer ID + notarización ($99/año + ~1 día de configuración). Sin esto, los usuarios deben hacer right-click → Open en cada instalación.

### Camino B — Mac App Store

**Quién**: distribución masiva con descubrimiento orgánico.
**Pros**: confianza del usuario, actualizaciones automáticas, billing manejado por Apple.
**Contras**: 2–4 semanas de trabajo + Apple toma 15–30%. **Hay que quitar el modo instantáneo** (Apple no permite modificar defaults de otras apps ni matar SystemUIServer). La app perdería su mejor feature.

**Mi recomendación**: arrancar con **Camino A** (Developer ID + DMG) ahora, y posiblemente abrir Camino B en una v2 con feature set reducido si quieres exposure orgánico. Mantén ambos paths en paralelo eventualmente.

---

## 2. Acción inmediata: Top 10 (esta semana)

Ordenado por impacto. Lo primero es lo que más mueve la aguja.

1. **Sacar Apple Developer Program ($99/año)** — bloquea casi todo lo demás. Demora 24–48h en aprobarse.
2. **Crear Developer ID Application certificate** en developer.apple.com/account → firmar `build/ClipShot.app` con él en lugar de ad-hoc.
3. **Notarizar el `.app`** con `xcrun notarytool submit` y stapler. Ahora cualquier usuario lo abre sin Gatekeeper.
4. **Capturar las 3 screenshots reales para App Store / web** corriendo ClipShot a retina: (a) menú con historial abierto, (b) miniatura flotante apareciendo, (c) ventana de bienvenida. Guardarlas en `assets/appstore/needed/` a 2880×1800.
5. **Subir el icono `appstore_icon_1024_appstore_ready.png`** (ya generado por el asset agent) — está listo, sin alpha, fondo cuadrado lleno.
6. **Generar las imágenes de marketing faltantes** con los prompts de [assets/appstore/gemini_prompts.json](../assets/appstore/gemini_prompts.json) en Gemini Imagen 3 / DALL-E 3. Solo necesitas la hero (1) y el frame de preview (1). Las 3 screenshots de UI mejor captúralas en vivo.
7. **Crear DMG instalable bonito** — fondo con instrucciones de arrastrar a Applications. Tools: `create-dmg` (Homebrew) o `dmgbuild` (pip).
8. **Comprar dominio + landing page** con descarga del DMG + privacy policy. Para Apple Developer Program necesitas URL pública de privacy policy obligatoriamente.
9. **Actualizar `Resources/Info.plist`** con: `LSApplicationCategoryType=public.app-category.productivity`, `NSHumanReadableCopyright`, `ITSAppUsesNonExemptEncryption=false` (estos no rompen nada y son required para Store futuramente).
10. **Hacer pruebas de instalación limpia** en una cuenta de macOS fresca (o VM): abrir el DMG, arrastrar a Applications, otorgar permisos, verificar que el welcome aparezca y la app capture screenshots correctamente.

---

## 3. Documentos generados — cómo usarlos

| Documento | Para qué | Cuándo leerlo |
|---|---|---|
| [docs/APPSTORE.md](APPSTORE.md) | 11 secciones detalladas: developer setup, conversión a Xcode, sandbox audit, entitlements XML, privacy manifest, marketing assets, predicciones de rechazo, timeline | Cuando decidas ir al App Store (Camino B) |
| [docs/SECURITY.md](SECURITY.md) | Auditoría completa: 0 críticos, 0 altos, 7 medios, 7 bajos, 4 informativos | Antes de cada release público |
| [assets/appstore/ASSETS_REPORT.md](../assets/appstore/ASSETS_REPORT.md) | Qué assets se encontraron en el sistema + qué generar con Gemini | Para preparar la marketing kit |
| [assets/appstore/gemini_prompts.json](../assets/appstore/gemini_prompts.json) | 5 prompts listos para pegar en Gemini Imagen 3 / DALL-E 3 con dimensiones, paleta, negative prompts | Cuando generes los assets faltantes |

---

## 4. Tareas pendientes de seguridad (no son blockers)

Los 3 fixes críticos ya están aplicados al código. Lo que queda del reporte de seguridad para iterar después:

- Reducir polling del portapapeles de 100ms a 500ms (menor impacto energético — importante para review de Apple)
- Considerar `NSMetadataQuery` o `DispatchSource` en vez de polling de la carpeta de screenshots
- Documentar en la pantalla de privacidad del welcome el path real donde se guarda el historial
- Agregar TCC usage strings explícitos en `Info.plist` aunque no estés sandboxed (mejora UX cuando macOS prompts)

Detalles en [docs/SECURITY.md](SECURITY.md).

---

## 5. Riesgos a anticipar

### Apple Developer review (Camino A — para notarización)

La notarización es automática, no hay review humano. Si el binario no tiene malware obvio y está firmado, pasa en minutos. **Riesgo bajo.**

### Mac App Store review (Camino B)

12 razones de rechazo predichas por el agente App Store:

1. **Guideline 2.5.1 / 2.5.9** — modificar UserDefaults de Apple y matar SystemUIServer es rechazo automático. *Fix*: quitar el modo instantáneo para v1.0 Store.
2. **Guideline 2.4.5(iii)** — opt-in automático al login. *Fix*: el toggle ya está OFF por defecto en welcome.
3. **Sandbox**: leer `~/Desktop` necesita entitlement `com.apple.security.files.desktop.read-only`.
4. **Energy impact**: polling agresivo. *Fix*: bajar a 500ms.
5. **Privacy manifest** `PrivacyInfo.xcprivacy` con razones `CA92.1` (file timestamps) y `C617.1` (user defaults). Required desde 2024.
6. ... resto en [docs/APPSTORE.md](APPSTORE.md).

---

## 6. Timeline realista

### Camino A — Developer ID + DMG (recomendado primero)
- Día 1: pagar developer program
- Día 2–3: esperar aprobación
- Día 4: crear cert, configurar notary, ajustar `build.sh` para firmar+notarizar
- Día 5–6: capturar screenshots, generar hero image, armar DMG
- Día 7: lanzar landing + DMG → **listo**

### Camino B — Mac App Store (después)
- Semana 1: convertir a Xcode project, agregar sandbox, quitar modo instantáneo, entitlements, privacy manifest
- Semana 2: testing en sandbox, capturar nuevas screenshots, llenar App Store Connect
- Semana 3: submit + ronda de review (típicamente 1–3 rejections en primer envío) → **listo**

---

## 7. Próximos features sugeridos (post-lanzamiento)

Ideas para v1.1+ basadas en el análisis:

- **OCR del texto en screenshots** (Vision framework + búsqueda en historial)
- **Quick markup** integrado sin tener que abrir Vista Previa
- **Subir a iCloud / Drive / Slack** desde el menú (con consentimiento explícito)
- **Atajo global configurable** para que el usuario elija sus teclas
- **Modo "annotate before save"** opcional
- **Compresión / conversión a WebP** automática para liberar espacio
- **Sync entre Macs** vía iCloud (requiere `com.apple.developer.icloud-container-identifiers`)

---

## 8. Comandos útiles para desarrollo

```bash
# Compilar y reinstalar
make install

# Solo compilar
make build

# Regenerar el icono desde el SVG
make icon

# Ver el log
tail -f ~/Library/Logs/ClipShot.log

# Resetear el welcome para volver a verlo
defaults delete com.josecasadogenao.clipshot clipshot.hasSeenIntro

# Resetear los permisos de Accesibilidad (si los necesitas)
tccutil reset Accessibility com.josecasadogenao.clipshot
```

---

## TL;DR

1. ✅ Estructura limpia, fixes de seguridad aplicados.
2. 🎯 Próxima acción: comprar Apple Developer Program ($99) → Developer ID + notarización (camino A).
3. 📦 Lanzamiento DMG en ~1 semana es realista.
4. 🏪 Mac App Store es opcional y requiere quitar el modo instantáneo — abordar después.
5. 📄 Todos los detalles operativos están en `docs/APPSTORE.md`, `docs/SECURITY.md`, `assets/appstore/ASSETS_REPORT.md`.
