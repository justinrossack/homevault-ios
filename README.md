# homevault für iPhone

iPhone-App für den homevault-Server: automatisches Foto-Backup, Fotos ansehen, Dateien durchsuchen, Server-Status.
Nur für die Familie, ohne App Store und ohne TestFlight.

## Funktionen

- **Backup**: neue Fotos und Videos automatisch nach `Privat/iPhone/<Jahr>/<Monat>`. Live Photos bleiben Live Photos (Foto + `.MOV` mit gleichem Namen). Was schon auf dem Server liegt, wird übersprungen. Optionen: nur im WLAN, Videos ja/nein, erst ab einem Datum.
- **Fotos**: Zeitleiste, Favoriten, Alben, Vollbild mit Zoom, Videos, Live Photos (LIVE gedrückt halten), Teilen/Sichern.
- **Dateien**: Privat/Gemeinsam durchsuchen, Vorschau (PDF, Office, Bilder, Videos …), hochladen, neuer Ordner, in den Papierkorb.
- **Server**: Speicherplatz, Festplatten-Spiegel, Server-Backups (für Admins), Ablaufdatum der Installation.

## Verteilen an die Familie (Ad Hoc + GitHub Pages)

Kein App Store, kein TestFlight. Die App liegt auf einer Installationsseite (GitHub Pages),
die Familie installiert per Link und bekommt Updates in der App angezeigt.

### Einmalig einrichten

1. **Account in Xcode**: Xcode → Einstellungen → Accounts → „+“ → Apple-ID (bezahlter Developer-Account).
2. **Team setzen**: `HomeVault.xcodeproj` → Target „HomeVault“ → *Signing & Capabilities* → *Team*.
   Ist die Bundle-ID schon vergeben, `de.justinrossack.homevault` ändern
   (dann auch die Kennungen in `Config/Info.plist` und `Backup/BackgroundBackup.swift`).
3. **GitHub-Repo** anlegen und als `origin` verbinden. Nach dem ersten Release:
   GitHub → *Settings → Pages* → Branch `gh-pages` auswählen.

### Neues Familien-iPhone freischalten

1. Die Person öffnet die Installationsseite und folgt „App kann nicht installiert werden?“:
   UDID anzeigen lassen (z. B. über median.co/udid) und dir schicken.
2. Du trägst die UDID ein: [developer.apple.com → Devices → „+“](https://developer.apple.com/account/resources/devices/list).
3. `scripts/release.sh` ausführen, danach kann die Person installieren.

Kein Kabel nötig. Bis zu 100 iPhones pro Jahr.

### Update veröffentlichen

```bash
scripts/release.sh "Was ist neu"
```

Das Skript baut, signiert (inkl. aller registrierten iPhones), erstellt Installationsseite,
`manifest.plist` und `version.json` und lädt alles auf den Branch `gh-pages`.
Die App prüft beim Öffnen `version.json` und zeigt „Update verfügbar → Installieren“.
Fotos, Anmeldung und Einstellungen bleiben erhalten.

**Einmal im Jahr** läuft die Signatur ab. Einfach vorher ein Release machen; das Skript warnt,
wenn das Zertifikat in weniger als 30 Tagen abläuft. In der App steht das Datum unter *Server → App*.

> Die `.ipa` liegt öffentlich auf GitHub Pages, läuft aber nur auf den registrierten iPhones.
> Server-Adresse und Zugangsdaten stehen nicht in der App, sondern gibt jeder selbst ein.

## Hinweise zum Backup

- iOS bestimmt, wann Apps im Hintergrund laufen dürfen: zwischendurch kurz, länger nachts beim Laden im WLAN.
  Den ersten großen Abgleich am besten mit geöffneter App und Ladekabel machen (der Bildschirm bleibt dabei an).
- Ab iOS 26 läuft „Jetzt sichern“ auch weiter, wenn man die App verlässt (mit Fortschritt in der Systemanzeige).
- Der Server ist nur im Heimnetz erreichbar. Für unterwegs: WireGuard oder Tailscale, dann die VPN-Adresse eintragen und „Nur im WLAN“ ggf. ausschalten.
- Die App merkt sich gesicherte Fotos lokal. „Abgleich zurücksetzen“ prüft alles erneut, ohne doppelt hochzuladen.

## Entwickeln

```bash
xcodebuild -project HomeVault.xcodeproj -scheme HomeVault -destination 'platform=iOS Simulator,name=iPhone 18 Pro' build
```

Debug-Builds im Simulator können die Login-Felder per Umgebungsvariable vorbelegen:
`SIMCTL_CHILD_HV_SERVER=localhost:8080 SIMCTL_CHILD_HV_USER=… SIMCTL_CHILD_HV_PASSWORD=… xcrun simctl launch booted de.justinrossack.homevault`
