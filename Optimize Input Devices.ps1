# === Auto-Elevate ===
if (-not ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")) {
    Start-Process powershell "-ExecutionPolicy Bypass -File `"$PSCommandPath`"" -Verb RunAs
    exit
}

# === Logging (console only) ===
function Write-Log {
    param (
        [string]$Message,
        [ConsoleColor]$Color = "White"
    )
    Write-Host $Message -ForegroundColor $Color
}

function Get-USBControllerDevice {
    param ([string]$pnpDeviceId)
    $device = Get-PnpDevice -InstanceId $pnpDeviceId -ErrorAction SilentlyContinue
    while ($device) {
        if ($device.Class -eq "USB" -and $device.FriendlyName -match "Host Controller") {
            return $device
        }
        $parentId = (Get-PnpDeviceProperty -InstanceId $device.InstanceId -KeyName "DEVPKEY_Device_Parent" -ErrorAction SilentlyContinue).Data
        if (-not $parentId) { break }
        $device = Get-PnpDevice -InstanceId $parentId -ErrorAction SilentlyContinue
    }
    return $null
}

function Get-RegistryPathForController {
    param ([string]$controllerId)
    $normalizedId = ($controllerId -replace '^PCI\\', '').ToUpper()
    $regBase = "Registry::HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Enum\PCI"
    $pciKeys = Get-ChildItem -Path $regBase -ErrorAction Stop

    foreach ($key in $pciKeys) {
        $instances = Get-ChildItem -Path $key.PSPath -ErrorAction SilentlyContinue
        foreach ($instance in $instances) {
            $fullPath = ($key.PSChildName + "\\" + $instance.PSChildName).ToUpper()
            if ($normalizedId -eq $fullPath) {
                return $instance.PSPath
            }
        }
    }

    foreach ($key in $pciKeys) {
        if ($normalizedId.StartsWith($key.PSChildName.ToUpper())) {
            $instances = Get-ChildItem -Path $key.PSPath -ErrorAction SilentlyContinue
            foreach ($instance in $instances) {
                if ($normalizedId.Contains($instance.PSChildName.ToUpper())) {
                    return $instance.PSPath
                }
            }
        }
    }
    return $null
}

function Apply-MSIAndAffinity {
    param (
        [string]$regPath
    )
    $msiPath = Join-Path $regPath "Device Parameters\Interrupt Management\MessageSignaledInterruptProperties"
    $affinityPath = Join-Path $regPath "Device Parameters\Interrupt Management\Affinity Policy"

    if (-not (Test-Path $msiPath)) {
        New-Item -Path $msiPath -Force | Out-Null
        Write-Log "Created MSI key: $msiPath" Green
    }
    New-ItemProperty -Path $msiPath -Name "MSISupported" -PropertyType DWord -Value 1 -Force | Out-Null
    New-ItemProperty -Path $msiPath -Name "MessageNumberLimit" -PropertyType DWord -Value 1 -Force | Out-Null
    Write-Log "Set MSISupported=1 and MessageNumberLimit=1 at $msiPath" Green

    if (-not (Test-Path $affinityPath)) {
        New-Item -Path $affinityPath -Force | Out-Null
        Write-Log "Created AffinityPolicy key: $affinityPath" Green
    }
    New-ItemProperty -Path $affinityPath -Name "DevicePolicy" -PropertyType DWord -Value 1 -Force | Out-Null
    New-ItemProperty -Path $affinityPath -Name "DevicePriority" -PropertyType DWord -Value 3 -Force | Out-Null
    Write-Log "Set DevicePolicy=1, DevicePriority=3 at $affinityPath" Green
}

# === Main Execution ===
$hidServices = @("mouhid", "kbdhid")
$inputDevices = Get-PnpDevice | Where-Object { $hidServices -contains $_.Service }
$processedControllers = @{}

foreach ($device in $inputDevices) {
    Write-Log "`nInput Device: $($device.FriendlyName) [$($device.InstanceId)]" Cyan

    $controller = Get-USBControllerDevice -pnpDeviceId $device.InstanceId

    if ($controller) {
        Write-Log " → Traced to USB Controller: $($controller.FriendlyName) [$($controller.InstanceId)]" White

        $controllerKey = $controller.InstanceId.ToUpper()
        if ($processedControllers.ContainsKey($controllerKey)) {
            Write-Log " → Skipped: This controller has already been processed." DarkYellow
            continue
        }

        $controllerRegPath = Get-RegistryPathForController -controllerId $controller.InstanceId

        if ($controllerRegPath) {
            Write-Log " → Registry path: $controllerRegPath" DarkGray
            Apply-MSIAndAffinity -regPath $controllerRegPath

            $associatedDevices = $inputDevices | Where-Object {
                (Get-USBControllerDevice -pnpDeviceId $_.InstanceId).InstanceId -eq $controller.InstanceId
            }
            foreach ($d in $associatedDevices) {
                Write-Log "    ↳ Attached Device: $($d.FriendlyName) [$($d.InstanceId)]" DarkCyan
            }

            $processedControllers[$controllerKey] = $true
        } else {
            Write-Log " Could not locate registry path for controller." Red
        }
    } else {
        Write-Log " Could not trace controller for device." Red
    }
}

Write-Log "`nAll input devices processed." Yellow
