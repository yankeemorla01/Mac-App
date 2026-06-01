# ClipShot Pro — In-App Purchase setup en App Store Connect

Antes de que ClipShot 3.1 funcione con compra real, hay que crear el producto
IAP en App Store Connect. **Esto se hace una sola vez**. La app ya tiene el
código StoreKit 2 wireado al product ID — solo falta crearlo.

---

## Product ID a configurar

**`com.jcmorla.clipshot.pro`**

Ese ID está hardcoded en `Settings.proProductID` y `Localizable.strings`. Si lo
cambiás, hay que actualizar ambos lados.

---

## Pasos en App Store Connect (5 min)

### 1. Crear el IAP

1. Ve a [appstoreconnect.apple.com](https://appstoreconnect.apple.com) → **My Apps → ClipShot**
2. En la sección izquierda, click **"In-App Purchases"**
3. Click **"+"** (Crear nuevo)
4. Elige **"Non-Consumable"** (compra una sola vez, no se consume)
5. Configura:
   - **Reference Name:** `ClipShot Pro` (solo para vos, no se ve al user)
   - **Product ID:** `com.jcmorla.clipshot.pro` ← exactamente este
6. Click **Create**

### 2. Configurar pricing

1. Dentro del IAP recién creado, click **Pricing**
2. Elige el tier que quieras:
   - **Tier 10 ($9.99 USD)** — recomendado para empezar
   - O cualquier tier que prefieras
3. Apple convierte automáticamente a 175+ monedas locales
4. Click **Save**

### 3. Localización (mínimo 1 idioma)

Click **App Store Localizations** → **+ Add Localization**:

**English (U.S.):**
- Display Name: `ClipShot Pro`
- Description: `Unlock OCR text extraction from screenshots, the color picker, and unlimited history. One-time purchase, no subscription.`

**Español:**
- Display Name: `ClipShot Pro`
- Description: `Desbloquea la extracción OCR de texto en capturas, el picker de color e historial ilimitado. Compra única, sin suscripción.`

### 4. Review Info

- **Screenshot:** subí una captura de la ventana del Paywall que muestra la app (1280×800 mínimo)
- **Review Notes:** `ClipShot Pro is a one-time unlock for advanced features. Test by tapping "✨ Unlock ClipShot Pro" in the app's menu bar dropdown, or any of the Pro-locked features (OCR toggle in Preferences, Color picker submenu). The paywall window will appear with a StoreKit 2 purchase flow.`

### 5. Status: "Ready to Submit"

Cuando estén todos los campos completos, el estado del IAP cambia a:
- **Missing Metadata** → llenar lo que falte
- **Ready to Submit** → ya está listo

### 6. Submit junto con la app version

Importante: el IAP **NO se aprueba solo**. Se aprueba **junto con una versión de la app que lo use**. Cuando subas el build 7 (versión 3.1) a revisión, el IAP se revisa al mismo tiempo.

En App Store Connect → tu app → **Distribution** → versión 3.1 → en la sección **"In-App Purchases and Subscriptions"** marca el IAP como incluido.

---

## Testing antes de que Apple apruebe

Apple no aprueba IAPs sin testing. Para probar:

### Sandbox Testing (gratis, sin pagar)

1. App Store Connect → **Users and Access** → **Sandbox Testers** → **+**
2. Crear un email tester (ej. `jeantester@example.com`)
3. En tu Mac: **Ajustes del Sistema → Internet Accounts → +** → "Other" → Apple ID → con el email tester
4. Cerrar sesión en App Store del Mac
5. Abrir ClipShot 3.1 → click Pro features → te pide login → meté tester credentials → simula compra gratis
6. Apple maneja todo el flujo de "purchase success" sin cobrarte

### Production después de Apple aprueba

Cuando Apple aprueba la versión 3.1 + el IAP juntos, ya está vivo. Los users pagan real.

---

## Revenue split

- Apple se queda **30%** del primer año
- **15% a partir del año 2** del mismo usuario
- Si te inscribís al **Small Business Program** (apps que facturan < $1M/año), Apple toma solo 15% desde el primer día

[developer.apple.com/app-store/small-business-program/](https://developer.apple.com/app-store/small-business-program/) para inscribirte.

A $9.99:
- Bruto: $9.99
- Apple 30%: $3.00
- Neto: $6.99 por venta
- 100 ventas/mes = ~$700 USD pasivos

---

## Estado actual del proyecto

✅ Código StoreKit 2 wireado a `com.jcmorla.clipshot.pro`
✅ PaywallWindowController con purchase + restore
✅ Lock en OCR + Color picker
✅ Strings localizados (es + en)
✅ Build 3.1 (.pkg) en `~/Downloads/ClipShot-3.1.pkg`

🔲 Crear IAP en App Store Connect (los 6 pasos de arriba)
🔲 Subir .pkg via Transporter
🔲 Marcar IAP como incluido en la versión 3.1
🔲 Submit para revisión
🔲 Testing con sandbox tester antes de salir live
