# Charybdis split-keyboard battery tray.
# Reads both BAS instances exposed by the central via WinRT GATT and shows
# "L:nn% R:nn%" in the system tray. Refreshes every $RefreshSec seconds.

param(
    [string]$DeviceAddress = 'fa:4a:a2:7f:a0:0e',
    [int]$RefreshSec = 60
)

if ($PSVersionTable.PSEdition -ne 'Desktop') {
    throw "Run with Windows PowerShell 5.1 (powershell.exe), not pwsh. WinRT projection is unavailable on .NET 5+."
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Runtime.WindowsRuntime

# Load required WinRT projections.
$null = [Windows.Devices.Bluetooth.BluetoothLEDevice, Windows.Devices.Bluetooth, ContentType=WindowsRuntime]
$null = [Windows.Devices.Bluetooth.GenericAttributeProfile.GattDeviceService, Windows.Devices.Bluetooth, ContentType=WindowsRuntime]
$null = [Windows.Security.Cryptography.CryptographicBuffer, Windows.Security.Cryptography, ContentType=WindowsRuntime]
$null = [Windows.Foundation.IAsyncOperation`1, Windows.Foundation, ContentType=WindowsRuntime]

# WinRT IAsyncOperation<T> -> synchronous result by reflecting AsTask<T>.
$asTaskGeneric = [System.WindowsRuntimeSystemExtensions].GetMethods() |
    Where-Object { $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and
                   $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1' } |
    Select-Object -First 1

function Await($op, $resultType) {
    $task = $asTaskGeneric.MakeGenericMethod($resultType).Invoke($null, @($op))
    $task.Wait(-1) | Out-Null
    return $task.Result
}

# PowerShell can't auto-cast WinRT IBuffer COM to the projection type. Call
# CryptographicBuffer.CopyToByteArray via reflection to skip PS arg conversion.
$copyToByteArrayMI = [Windows.Security.Cryptography.CryptographicBuffer].GetMethod('CopyToByteArray')
function Read-IBuffer($comBuf) {
    $a = [object[]]@($comBuf, $null)
    $copyToByteArrayMI.Invoke($null, $a) | Out-Null
    return $a[1]
}

function Get-BatteryLevels([string]$mac) {
    $addr = [UInt64]::Parse(($mac -replace '[:\-]', ''), 'HexNumber')
    $devOp = [Windows.Devices.Bluetooth.BluetoothLEDevice]::FromBluetoothAddressAsync($addr)
    $dev = Await $devOp ([Windows.Devices.Bluetooth.BluetoothLEDevice])
    if (-not $dev) { return @() }

    $svcUuid  = [Guid]'0000180f-0000-1000-8000-00805f9b34fb'
    $chrUuid  = [Guid]'00002a19-0000-1000-8000-00805f9b34fb'
    $svcType  = [Windows.Devices.Bluetooth.GenericAttributeProfile.GattDeviceServicesResult]
    $chrType  = [Windows.Devices.Bluetooth.GenericAttributeProfile.GattCharacteristicsResult]
    $rdType   = [Windows.Devices.Bluetooth.GenericAttributeProfile.GattReadResult]
    $Uncached = [Windows.Devices.Bluetooth.BluetoothCacheMode]::Uncached

    # Force uncached service enumeration to surface BOTH BAS instances —
    # the cached query collapses duplicate-UUID services into one.
    $svcResAll = Await ($dev.GetGattServicesAsync($Uncached)) $svcType
    $basList = @($svcResAll.Services | Where-Object { $_.Uuid -eq $svcUuid })
    $levels = @()
    foreach ($svc in $basList) {
        $chrRes = Await ($svc.GetCharacteristicsForUuidAsync($chrUuid, $Uncached)) $chrType
        foreach ($chr in $chrRes.Characteristics) {
            $rd = Await ($chr.ReadValueAsync($Uncached)) $rdType
            $bytes = Read-IBuffer $rd.Value
            $levels += [int]$bytes[0]
        }
        $svc.Dispose()
    }
    $dev.Dispose()
    return $levels
}

# Render a small bitmap with two numbers stacked, used as the tray icon.
function New-LevelIcon([int[]]$levels) {
    $bmp = New-Object System.Drawing.Bitmap 16, 16
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = 'AntiAlias'
    $g.Clear([System.Drawing.Color]::Transparent)
    $font = New-Object System.Drawing.Font('Consolas', 7, [System.Drawing.FontStyle]::Bold)
    $brush = [System.Drawing.Brushes]::White
    $top = if ($levels.Count -gt 0) { '{0,2}' -f $levels[0] } else { '--' }
    $bot = if ($levels.Count -gt 1) { '{0,2}' -f $levels[1] } else { '--' }
    $g.DrawString($top, $font, $brush, -2, -2)
    $g.DrawString($bot, $font, $brush, -2,  6)
    $g.Dispose(); $font.Dispose()
    $hicon = $bmp.GetHicon()
    $icon = [System.Drawing.Icon]::FromHandle($hicon)
    $bmp.Dispose()
    return $icon
}

$notify = New-Object System.Windows.Forms.NotifyIcon
$notify.Visible = $true
$notify.Text = 'Charybdis battery'
$menu = New-Object System.Windows.Forms.ContextMenuStrip
[void]$menu.Items.Add('Refresh now', $null, { $script:doRefresh = $true })
[void]$menu.Items.Add('Exit', $null, { $script:running = $false })
$notify.ContextMenuStrip = $menu

$script:running = $true
$script:doRefresh = $true
$lastLevels = @()

while ($script:running) {
    if ($script:doRefresh) {
        try {
            $lastLevels = Get-BatteryLevels $DeviceAddress
            $notify.Text = if ($lastLevels.Count -ge 2) {
                "Charybdis  R:{0}%  L:{1}%" -f $lastLevels[0], $lastLevels[1]
            } elseif ($lastLevels.Count -eq 1) {
                "Charybdis  {0}% (one half)" -f $lastLevels[0]
            } else { 'Charybdis  not connected' }
            $notify.Icon = New-LevelIcon $lastLevels
        } catch {
            $notify.Text = "Charybdis  error: $($_.Exception.Message)".Substring(0, [Math]::Min(63, "Charybdis  error: $($_.Exception.Message)".Length))
        }
        $script:doRefresh = $false
    }
    for ($i = 0; $i -lt $RefreshSec * 10 -and $script:running -and -not $script:doRefresh; $i++) {
        [System.Windows.Forms.Application]::DoEvents()
        Start-Sleep -Milliseconds 100
    }
    $script:doRefresh = $true
}

$notify.Visible = $false
$notify.Dispose()
