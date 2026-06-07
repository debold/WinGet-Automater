# Verbleibende Registry-Einträge nach Deinstallation bereinigen
$paths = @(
    'HKLM:\SOFTWARE\Adobe\Acrobat Reader'
    'HKLM:\SOFTWARE\Policies\Adobe\Acrobat Reader'
    'HKCU:\SOFTWARE\Adobe\Acrobat Reader'
)
foreach ($p in $paths) {
    if (Test-Path $p) {
        Remove-Item $p -Recurse -Force -ErrorAction SilentlyContinue
        Write-ADTLogEntry -Message "Removed registry path: $p"
    }
}
