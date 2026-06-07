# WinGet-Automater

> **⚠ Entwicklungsstatus: Work in Progress**
>
> Dieses Projekt befindet sich aktiv in der Entwicklung. Funktionen, Konfigurationsstruktur und
> Skript-Interfaces können sich ohne Vorankündigung ändern. Nicht für den produktiven Einsatz empfohlen.

Vollautomatische Pipeline: WinGet-Paket-ID eingeben → PSADT v4 Deployment-Paket wird gebaut → als Win32 App in Microsoft Intune registriert.

```
PackageId  z.B. "VideoLAN.VLC"
    │
    ▼
WinGet GitHub API        YAML-Manifeste aus winget-pkgs lesen
    │                    (Name, Version, Installer-URL, Metadaten)
    ▼
PSADT v4 Builder         Paketordner anlegen, Installer herunterladen,
    │                    Deploy-Application.ps1 aus Template generieren
    ▼
Review (optional)        Skript prüfen und anpassen bevor es verpackt wird
    │
    ▼
IntuneWinAppUtil.exe     .intunewin Paket erstellen
    │
    ▼
Microsoft Graph API      Win32 App in Intune anlegen, Datei hochladen,
                         committen – optional Gruppe zuweisen
```

---

## Inhaltsverzeichnis

- [Voraussetzungen](#voraussetzungen)
- [Einrichtung](#einrichtung)
  - [1. Repository klonen](#1-repository-klonen)
  - [2. IntuneWinAppUtil herunterladen](#2-intunewinapputil-herunterladen)
  - [3. Entra App Registration anlegen](#3-entra-app-registration-anlegen)
  - [4. Konfigurationsdatei erstellen](#4-konfigurationsdatei-erstellen)
- [Verwendung](#verwendung)
  - [Einzelnes Paket](#einzelnes-paket)
  - [Bestimmte Version](#bestimmte-version)
  - [Mit Review-Pause](#mit-review-pause)
  - [Nur bauen, nicht hochladen](#nur-bauen-nicht-hochladen)
  - [Batch-Modus](#batch-modus)
  - [Paket neu bauen (Force)](#paket-neu-bauen-force)
- [Deploy-Application.ps1 anpassen](#deploy-applicationps1-anpassen)
  - [Wann anpassen?](#wann-anpassen)
  - [Aufbau des generierten Skripts](#aufbau-des-generierten-skripts)
  - [Template-Platzhalter](#template-platzhalter)
  - [Eigenes Template verwenden](#eigenes-template-verwenden)
- [Konfigurationsreferenz](#konfigurationsreferenz)
- [Ausgabestruktur](#ausgabestruktur)
- [Versionspolitik](#versionspolitik)
- [Tests](#tests)

---

## Voraussetzungen

| Anforderung | Details |
|---|---|
| Betriebssystem | Windows 10/11 oder Windows Server 2019+ |
| PowerShell | Version 7.x (`winget install Microsoft.PowerShell`) |
| Entra ID | App Registration mit Admin-Consent (siehe unten) |
| Internetzugang | GitHub API, `login.microsoftonline.com`, Azure Blob Storage |

---

## Einrichtung

### 1. Repository klonen

```powershell
git clone https://github.com/debold/WinGet-Automater.git
cd WinGet-Automater
```

### 2. IntuneWinAppUtil herunterladen

Microsoft stellt das Win32 Content Prep Tool kostenlos bereit. Das mitgelieferte Hilfsskript lädt es herunter:

```powershell
.\tools\Get-IntuneWinAppUtil.ps1
```

Das Tool wird unter `tools\IntuneWinAppUtil.exe` abgelegt. Der Pfad kann in `config.json` überschrieben werden.

### 3. Entra App Registration anlegen

WinGet-Automater benötigt eine **App Registration** in Entra ID (ehemals Azure AD), die im Hintergrund ohne Benutzeranmeldung mit der Intune-API spricht (Client Credentials Flow).

**Schritt-für-Schritt im Azure Portal (`portal.azure.com`):**

1. **Entra ID** → **App-Registrierungen** → **Neue Registrierung**
   - Name: z.B. `WinGet-Automater`
   - Unterstützte Kontotypen: *Nur Konten in diesem Organisationsverzeichnis*
   - Umleitungs-URI: leer lassen
   - **Registrieren**

2. **API-Berechtigungen** → **Berechtigung hinzufügen** → **Microsoft Graph** → **Anwendungsberechtigungen**

   | Berechtigung | Zweck |
   |---|---|
   | `DeviceManagementApps.ReadWrite.All` | Apps in Intune anlegen, hochladen, aktualisieren |

   Danach: **Administratorzustimmung erteilen** (der Knopf „Admin-Zustimmung für \<Tenant\> erteilen")

3. **Zertifikate & Geheimnisse** → **Neuer geheimer Clientschlüssel**
   - Beschreibung: z.B. `WinGet-Automater-Secret`
   - Ablauf: nach eigenem Ermessen (Empfehlung: 12 Monate, dann rotieren)
   - Den angezeigten **Wert** sofort kopieren – er ist danach nicht mehr sichtbar

4. **Übersicht** der App Registration: **Anwendungs-ID (Client)** und **Verzeichnis-ID (Mandant)** notieren

### 4. Konfigurationsdatei erstellen

```powershell
Copy-Item config\config.example.json config\config.json
```

`config\config.json` mit den notierten Werten befüllen:

```json
{
  "auth": {
    "tenantId":     "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx",
    "clientId":     "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx",
    "clientSecret": "hier-das-client-secret-eintragen"
  },
  "intune": {
    "assignmentGroupId": "",
    "assignmentIntent": "available",
    "defaultPublisher": "WinGet-Automater"
  },
  "build": {
    "outputPath": "./output",
    "psadtVersion": "4.0.4",
    "keepBuildArtifacts": true,
    "intuneWinToolPath": "./tools/IntuneWinAppUtil.exe"
  },
  "github": {
    "token": ""
  }
}
```

> **Hinweis:** `config\config.json` ist in `.gitignore` eingetragen und wird nicht eingecheckt.
> Niemals Credentials in die Versionskontrolle einchecken.

**Optionale Felder:**

| Feld | Beschreibung |
|---|---|
| `intune.assignmentGroupId` | Objekt-ID einer Entra-Gruppe. Wenn gesetzt, wird die App nach dem Upload dieser Gruppe zugewiesen. Leer lassen für manuelle Zuweisung im Portal. |
| `intune.assignmentIntent` | `available` (App erscheint im Unternehmensportal) oder `required` (Pflichtinstallation) |
| `github.token` | GitHub Personal Access Token (klassisch, kein Scope nötig). Erhöht das API-Rate-Limit von 60 auf 5.000 Anfragen/Stunde. Sinnvoll im Batch-Betrieb. |

---

## Verwendung

Alle Beispiele aus dem Projektverzeichnis ausführen. PowerShell 7 ist erforderlich (`pwsh`).

### Einzelnes Paket

```powershell
.\src\Invoke-WinGetAutomater.ps1 -PackageId "VideoLAN.VLC"
```

### Bestimmte Version

Ohne `-Version` wird automatisch die neueste Version aus dem WinGet-Repository verwendet.

```powershell
.\src\Invoke-WinGetAutomater.ps1 -PackageId "VideoLAN.VLC" -Version "3.0.20"  # nicht unterstützt – Version in apps.json angeben
```

Über die Batch-Datei `config\apps.json`:

```json
{
  "packages": [
    { "PackageId": "VideoLAN.VLC",   "Version": "3.0.20" },
    { "PackageId": "Mozilla.Firefox", "Version": null }
  ]
}
```

```powershell
.\src\Invoke-WinGetAutomater.ps1 -AppsFile "config\apps.json"
```

### Mit Review-Pause

Der Schalter `-Review` pausiert den Prozess nach dem PSADT-Build und öffnet den Paketordner im Explorer. So kann `Deploy-Application.ps1` vor dem Verpacken und Hochladen geprüft und bearbeitet werden.

```powershell
.\src\Invoke-WinGetAutomater.ps1 -PackageId "VideoLAN.VLC" -Review
```

Im Terminal erscheint dann:

```
  ┌─────────────────────────────────────────────────────────┐
  │  REVIEW MODE – Inspect and edit before packaging        │
  ├─────────────────────────────────────────────────────────┤
  │  Package folder:                                        │
  │  C:\...\output\VideoLAN.VLC\3.0.21                      │
  │                                                         │
  │  Main script:                                           │
  │  C:\...\output\VideoLAN.VLC\3.0.21\Deploy-Application.ps1 │
  └─────────────────────────────────────────────────────────┘

  Press [Enter] to continue, [S] to skip this package, [A] to abort all
```

### Nur bauen, nicht hochladen

Nützlich zum Testen des Paketbaus ohne Intune-Zugang.

```powershell
.\src\Invoke-WinGetAutomater.ps1 -PackageId "VideoLAN.VLC" -SkipUpload
.\src\Invoke-WinGetAutomater.ps1 -PackageId "VideoLAN.VLC" -SkipUpload -OutputPath "C:\IntunePackages"
```

### Batch-Modus

```powershell
# Alle Pakete in apps.json verarbeiten
.\src\Invoke-WinGetAutomater.ps1 -AppsFile "config\apps.json"

# Mit Review-Pause für jedes Paket
.\src\Invoke-WinGetAutomater.ps1 -AppsFile "config\apps.json" -Review

# Verbose-Ausgabe (zeigt API-Calls, Versionauflösung, etc.)
.\src\Invoke-WinGetAutomater.ps1 -AppsFile "config\apps.json" -Verbose
```

### Paket neu bauen (Force)

Wenn der Paketordner bereits existiert, wird der Build-Schritt standardmäßig übersprungen. `-Force` erzwingt einen Neubau.

```powershell
.\src\Invoke-WinGetAutomater.ps1 -PackageId "VideoLAN.VLC" -Force
```

---

## Deploy-Application.ps1 anpassen

### Wann anpassen?

Das generierte `Deploy-Application.ps1` deckt Standardfälle ab (MSI silent install, EXE mit `/S`, MSIX via `Add-AppxPackage`). Manuelle Anpassung ist in folgenden Situationen sinnvoll:

- **Nicht-standardkonforme Silent-Switches** (z.B. `/VERYSILENT /SUPPRESSMSGBOXES` bei Inno Setup)
- **Zusätzliche Schritte** vor/nach der Installation (Dienste stoppen, Registry-Keys setzen, Lizenzdateien ablegen)
- **Abhängigkeiten** die vorher installiert werden müssen
- **Uninstall-Befehl fehlt** (bei EXE-Paketen ohne ProductCode generiert der Builder einen TODO-Kommentar)

Am einfachsten mit `-Review`: Nach dem Build öffnet sich der Ordner, das Skript kann direkt bearbeitet werden, dann Enter drücken zum Weitermachen.

### Aufbau des generierten Skripts

```powershell
## ── App Metadata ──────────────────────────────────────────────
$appVendor    = 'VideoLAN'
$appName      = 'VLC media player'
$appVersion   = '3.0.21'
$appSetupFile = 'vlc-3.0.21-win64.exe'

## ── Import PSADT Module ───────────────────────────────────────
Import-Module (Join-Path $PSScriptRoot 'AppDeployToolkit\PSAppDeployToolkit.psd1') -Force

## ── Open Session ─────────────────────────────────────────────
$adtSession = Open-ADTSession ...

## ── Deployment Logic ─────────────────────────────────────────
switch ($DeploymentType) {
    'Install'   { ... }   # ← hier anpassen
    'Uninstall' { ... }   # ← hier anpassen
    'Repair'    { ... }   # ← hier anpassen
}
```

Die `$appSetupFile`-Variable enthält den Dateinamen des Installers im `Files\`-Unterordner. Der vollständige Pfad lautet `$dirFiles\$appSetupFile` (PSADT-Variable).

### Template-Platzhalter

Die Datei `templates\Deploy-Application.ps1.template` wird für jedes Paket verwendet. Folgende Platzhalter werden beim Build ersetzt:

| Platzhalter | Ersetzt durch |
|---|---|
| `{{PACKAGE_ID}}` | WinGet Package-ID, z.B. `VideoLAN.VLC` |
| `{{APP_NAME}}` | App-Name aus dem Manifest |
| `{{PUBLISHER}}` | Publisher aus dem Manifest |
| `{{VERSION}}` | Versionsnummer |
| `{{ARCHITECTURE}}` | Installer-Architektur (`x64`, `x86`, `arm64`) |
| `{{SETUP_FILE}}` | Dateiname des Installers in `Files\` |
| `{{CLOSE_APPS}}` | Prozessname zum Schließen vor der Installation |
| `{{INSTALL_BLOCK}}` | Generierter Install-Befehl (Msiexec/Start-ADTProcess/Add-AppxPackage) |
| `{{UNINSTALL_BLOCK}}` | Generierter Uninstall-Befehl |
| `{{REPAIR_BLOCK}}` | Generierter Repair-Befehl |

### Eigenes Template verwenden

Das Standard-Template kann komplett ersetzt werden. Solange alle Platzhalter aus der Tabelle oben enthalten sind, funktioniert der Builder:

```powershell
# Eigenes Template für MSI-Pakete mit erweiterten Optionen
.\src\Invoke-WinGetAutomater.ps1 -PackageId "7zip.7zip" -SkipUpload
# Danach templates\Deploy-Application.ps1.template nach Bedarf anpassen
```

---

## Konfigurationsreferenz

Vollständige `config.json` mit allen Feldern und Standardwerten:

```json
{
  "auth": {
    "tenantId":     "<Entra Tenant ID>",
    "clientId":     "<App Registration Client ID>",
    "clientSecret": "<Client Secret>"
  },
  "intune": {
    "assignmentGroupId": "",
    "assignmentIntent":  "available",
    "defaultPublisher":  "WinGet-Automater"
  },
  "build": {
    "outputPath":          "./output",
    "psadtVersion":        "4.0.4",
    "keepBuildArtifacts":  true,
    "intuneWinToolPath":   "./tools/IntuneWinAppUtil.exe"
  },
  "github": {
    "token": ""
  }
}
```

| Schlüssel | Typ | Beschreibung |
|---|---|---|
| `auth.tenantId` | string | Verzeichnis-ID (GUID) aus der Entra App Registration |
| `auth.clientId` | string | Anwendungs-ID (GUID) aus der Entra App Registration |
| `auth.clientSecret` | string | Geheimer Clientschlüssel |
| `intune.assignmentGroupId` | string | Objekt-ID der Ziel-Entra-Gruppe. Leer = keine automatische Zuweisung |
| `intune.assignmentIntent` | string | `available` oder `required` |
| `intune.defaultPublisher` | string | Fallback-Publisher wenn WinGet keinen liefert |
| `build.outputPath` | string | Ausgabeverzeichnis (relativ zum Projektordner oder absolut) |
| `build.psadtVersion` | string | PSADT v4 Release-Tag von GitHub (z.B. `4.0.4`) |
| `build.keepBuildArtifacts` | bool | `true` = Paketordner nach dem Upload behalten |
| `build.intuneWinToolPath` | string | Pfad zu `IntuneWinAppUtil.exe` |
| `github.token` | string | GitHub PAT für erhöhtes API-Rate-Limit (optional) |

---

## Ausgabestruktur

```
output/
└── VideoLAN.VLC/
    └── 3.0.21/
        ├── AppDeployToolkit\        ← PSADT v4 Framework (automatisch heruntergeladen)
        ├── Files\
        │   └── vlc-3.0.21-win64.exe ← heruntergeladener Installer
        ├── SupportFiles\            ← Ablage für eigene Zusatzdateien
        ├── Deploy-Application.ps1   ← generiertes Deployment-Skript
        └── intunewin\
            └── Deploy-Application.intunewin  ← fertiges Intune-Paket
```

---

## Versionspolitik

| Situation | Verhalten |
|---|---|
| App noch nicht in Intune vorhanden | Neue App anlegen und hochladen |
| Identische Version bereits vorhanden | Überspringen (kein erneuter Upload) |
| Ältere Version vorhanden | Vorhandene App aktualisieren (neue Content Version) |
| Neuere Version bereits vorhanden | Überspringen mit Hinweis |

---

## Tests

Pester 5 ist erforderlich. Es wird automatisch installiert wenn nicht vorhanden.

```powershell
# Alle Tests (öffentliche GitHub-APIs, kein Intune-Zugang nötig)
.\tests\Run-Tests.ps1

# Nur Unit-Tests (kein Netzwerk außer Moduldownload)
.\tests\Run-Tests.ps1 -Suite Unit

# Nur Integrationstests gegen live winget-pkgs + PSADT GitHub
.\tests\Run-Tests.ps1 -Suite Integration

# Ausführliche Ausgabe
.\tests\Run-Tests.ps1 -OutputFormat Diagnostic
```

| Suite | Netzwerk | Credentials |
|---|---|---|
| Unit (`IntuneUploader`) | nein | nein |
| Integration (`WinGetHelper`, `PSADTBuilder`) | GitHub (public) | nein |
