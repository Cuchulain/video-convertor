# Video convertor pro TV – Jan Čejka, https://dev.jancejka.cz
# https://github.com/Cuchulain/video-convertor (licence MIT)

# Přidá nebo odebere adresář v uživatelské proměnné PATH (volá instalátor).
# Hodnota se čte a zapisuje přímo v registru jako REG_EXPAND_SZ, aby se
# nerozbily položky jako %USERPROFILE%\bin ([Environment]::SetEnvironmentVariable
# by je rozvinul a uložil jako REG_SZ).
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string] $Directory,
    [switch] $Remove
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$target = $Directory.TrimEnd('\')
$key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment', $true)
try {
    $current = [string]$key.GetValue('Path', '', [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
    $parts = @($current -split ';' | Where-Object { $_ -and $_.TrimEnd('\') -ne $target })
    if (-not $Remove) { $parts += $target }
    $key.SetValue('Path', ($parts -join ';'), [Microsoft.Win32.RegistryValueKind]::ExpandString)
} finally {
    $key.Close()
}

# Nastavení a smazání pomocné proměnné rozešle WM_SETTINGCHANGE, takže změnu
# PATH uvidí Průzkumník i nově otevřené terminály bez odhlášení.
[Environment]::SetEnvironmentVariable('VIDEO_CONVERTOR_REFRESH', '1', 'User')
[Environment]::SetEnvironmentVariable('VIDEO_CONVERTOR_REFRESH', $null, 'User')
