# WinGet-Automater

Vollautomatische Pipeline: WinGet-Paket → PSADT v4 Deployment-Paket → Intune Win32 App.

```
PackageId (z.B. "VideoLAN.VLC")
    │
    ▼
WinGet GitHub API       YAML-Manifeste aus winget-pkgs Repository lesen
    │
    ▼
PSADT v4 Builder        Paketstruktur + Deploy-Application.ps1 generieren
    │                   Installer herunterladen und einbetten
    ▼
IntuneWinAppUtil.exe    .intunewin Paket erstellen
    │
    ▼
Microsoft Graph API     Win32 App in Intune registrieren
                        Optional: Gruppe zuweisen
```

## Voraussetzungen

- Windows 10/11 oder Windows Server 2019+
- PowerShell 7.x
- Azure App Registration mit Berechtigung `DeviceManagementApps.ReadWrite.All`
- Internetzugang (GitHub, Microsoft Login, Azure Blob Storage)

## Einrichtung

### 1. IntuneWinAppUtil herunterladen

```powershell
.\tools\Get-IntuneWinAppUtil.ps1
```

### 2. Konfiguration erstellen

```powershell
Copy-Item config\config.example.json config\config.json
```

`config\config.json` bearbeiten:

```json
{
  "auth": {
    "tenantId":     "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx",
    "clientId":     "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx",
    "clientSecret": "dein-client-secret"
  }
}
```

### 3. Azure App Registration

Im Azure Portal eine App Registration anlegen mit folgenden API-Berechtigungen (Anwendungsberechtigungen, nicht delegiert):

| Berechtigung | Typ |
|---|---|
| `DeviceManagementApps.ReadWrite.All` | Anwendung |

Admin-Zustimmung (Admin consent) für diese Berechtigung erteilen.

## Verwendung

### Einzelnes Paket

```powershell
.\src\Invoke-WinGetAutomater.ps1 -PackageId "VideoLAN.VLC"
```

### Bestimmte Version

```powershell
.\src\Invoke-WinGetAutomater.ps1 -PackageId "Mozilla.Firefox" -Verbose
```

### Batch-Modus

```powershell
# apps.json anpassen (Vorlage: config\apps.example.json)
.\src\Invoke-WinGetAutomater.ps1 -AppsFile "config\apps.json"
```

### Nur bauen, nicht hochladen

```powershell
.\src\Invoke-WinGetAutomater.ps1 -PackageId "VideoLAN.VLC" -SkipUpload
```

### Ausgabepfad überschreiben

```powershell
.\src\Invoke-WinGetAutomater.ps1 -PackageId "VideoLAN.VLC" -OutputPath "C:\IntunePackages"
```

## Versionspolitik

| Situation | Verhalten |
|---|---|
| App noch nicht in Intune | Neue App anlegen + hochladen |
| Gleiche Version vorhanden | Überspringen |
| Ältere Version vorhanden | Aktualisieren (neue Content Version) |
| Neuere Version vorhanden | Überspringen mit Hinweis |

## Ausgabestruktur

```
output/
└── VideoLAN.VLC/
    └── 3.0.20/
        ├── AppDeployToolkit\    ← PSADT v4 Framework
        ├── Files\
        │   └── vlc-3.0.20-win64.msi
        ├── SupportFiles\
        ├── Deploy-Application.ps1
        └── intunewin\
            └── Deploy-Application.intunewin
```

## Konfigurationsreferenz

| Schlüssel | Beschreibung |
|---|---|
| `auth.tenantId` | Azure/Entra Tenant ID |
| `auth.clientId` | App Registration Client ID |
| `auth.clientSecret` | Client Secret |
| `intune.assignmentGroupId` | AAD-Gruppen-ID für automatische Zuweisung (leer = keine Zuweisung) |
| `intune.assignmentIntent` | `available` oder `required` |
| `build.outputPath` | Ausgabeverzeichnis (relativ oder absolut) |
| `build.psadtVersion` | PSADT v4 Release-Tag (z.B. `4.0.4`) |
| `build.intuneWinToolPath` | Pfad zu IntuneWinAppUtil.exe |
| `github.token` | Optional: GitHub PAT für höheres Rate-Limit |
