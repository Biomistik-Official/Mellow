# Installs the built Mellow for the current user and registers it for text files.
# Everything goes under the user profile and HKCU; no admin rights are needed.
# Windows itself decides the default app: this script only makes Mellow selectable.
param(
    [string]$Source = "$PSScriptRoot\..\build\windows\x64\runner\Release",
    [string[]]$Extensions = @('.txt', '.log', '.ini', '.md'),
    [switch]$Uninstall
)

$ErrorActionPreference = 'Stop'
$target = Join-Path $env:LOCALAPPDATA 'Programs\Mellow'
$exe = Join-Path $target 'mellow.exe'
$shortcut = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Mellow.lnk'
$classes = 'HKCU:\Software\Classes'
$progId = 'Mellow.Text'

if ($Uninstall) {
    Get-Process mellow -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq $exe } | Stop-Process -Force
    foreach ($ext in $Extensions) {
        Remove-ItemProperty "$classes\$ext\OpenWithProgids" -Name $progId -ErrorAction SilentlyContinue
    }
    Remove-Item "$classes\$progId", "$classes\Applications\mellow.exe", 'HKCU:\Software\Mellow' -Recurse -Force -ErrorAction SilentlyContinue
    Remove-ItemProperty 'HKCU:\Software\RegisteredApplications' -Name 'Mellow' -ErrorAction SilentlyContinue
    Remove-Item $shortcut -Force -ErrorAction SilentlyContinue
    Remove-Item $target -Recurse -Force -ErrorAction SilentlyContinue
    'Mellow removed. Settings and drafts stay in %APPDATA%\Mellow.'
    return
}

if (-not (Test-Path (Join-Path $Source 'mellow.exe'))) { throw "Build not found in $Source. Run: flutter build windows --release" }

Get-Process mellow -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq $exe } | Stop-Process -Force
New-Item -ItemType Directory -Force $target | Out-Null
Copy-Item (Join-Path $Source '*') $target -Recurse -Force

$link = (New-Object -ComObject WScript.Shell).CreateShortcut($shortcut)
$link.TargetPath = $exe
$link.WorkingDirectory = $target
$link.Description = 'Mellow'
$link.Save()

$command = "`"$exe`" `"%1`""
function Set-Default([string]$path, [string]$value) {
    New-Item $path -Force | Out-Null
    Set-ItemProperty -LiteralPath $path -Name '(default)' -Value $value
}

Set-Default "$classes\$progId" 'Mellow text document'
Set-Default "$classes\$progId\DefaultIcon" "`"$exe`",0"
Set-Default "$classes\$progId\shell\open\command" $command

Set-Default "$classes\Applications\mellow.exe\shell\open\command" $command
New-ItemProperty "$classes\Applications\mellow.exe" -Name 'FriendlyAppName' -Value 'Mellow' -Force | Out-Null
New-Item "$classes\Applications\mellow.exe\SupportedTypes" -Force | Out-Null

$caps = 'HKCU:\Software\Mellow\Capabilities'
New-Item "$caps\FileAssociations" -Force | Out-Null
New-ItemProperty $caps -Name 'ApplicationName' -Value 'Mellow' -Force | Out-Null
New-ItemProperty $caps -Name 'ApplicationDescription' -Value 'Soft Material You notepad' -Force | Out-Null

foreach ($ext in $Extensions) {
    New-Item "$classes\$ext\OpenWithProgids" -Force | Out-Null
    New-ItemProperty "$classes\$ext\OpenWithProgids" -Name $progId -Value '' -Force | Out-Null
    New-ItemProperty "$classes\Applications\mellow.exe\SupportedTypes" -Name $ext -Value '' -Force | Out-Null
    New-ItemProperty "$caps\FileAssociations" -Name $ext -Value $progId -Force | Out-Null
}
New-ItemProperty 'HKCU:\Software\RegisteredApplications' -Name 'Mellow' -Value 'Software\Mellow\Capabilities' -Force | Out-Null

"Installed to $target"
"Registered for: $($Extensions -join ', ')"
