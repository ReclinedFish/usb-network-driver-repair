#requires -Version 5.1
<#
.SYNOPSIS
Inspect and repair selected USB network driver bindings on 64-bit Windows.
.DESCRIPTION
Inspect is read-only. RepairParent selects the compatible inbox composite driver
for a failed network-class parent. BindDriver selects an already staged driver
for one network function. Restore rebinds the driver saved before an operation.
See README.md for scope, examples, backup behavior and limitations.
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [ValidateSet('Inspect', 'RepairParent', 'BindDriver', 'Restore')]
    [string]$Action = 'Inspect',
    [string]$InstanceId,
    [string]$DriverInf,
    [string]$DriverSection,
    [string]$Snapshot,
    [string]$ReportRoot,
    [switch]$ShareSafe,
    [switch]$NoProgress,
    [ValidateRange(0, 300)][int]$WatchSeconds = 0
)

function Write-UsbOperationProgress {
    param([string]$Status = 'Working', [int]$Percent = -1, [int]$Remaining = -1, [switch]$Completed)
    # Use the progress stream, not stdout; never include device or machine identifiers.
    Write-Progress -Id 48217 -Activity 'USB network driver check' -Status $Status `
        -PercentComplete $Percent -SecondsRemaining $Remaining -Completed:$Completed
}

function Initialize-UsbRepairNative {
    if ($env:OS -ne 'Windows_NT' -or -not [Environment]::Is64BitProcess) {
        throw 'Use 64-bit Windows PowerShell 5.1 or PowerShell 7 on Windows.'
    }
    if ('UsbNetworkRepair.NativeV1' -as [type]) { return }
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Runtime.InteropServices;
namespace UsbNetworkRepair {
    public sealed class Driver {
        public string Description, Provider, InfPath, Section, Version;
    }
    public static class NativeV1 {
        [StructLayout(LayoutKind.Sequential)]
        struct DeviceInfo {
            public uint Size;
            public Guid ClassGuid;
            public uint DevInst;
            public UIntPtr Reserved;
        }
        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        struct DriverInfo {
            public uint Size, Type;
            public UIntPtr Reserved;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 256)] public string Description;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 256)] public string Manufacturer;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 256)] public string Provider;
            public System.Runtime.InteropServices.ComTypes.FILETIME Date;
            public ulong Version;
        }
        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        struct Detail {
            public uint Size;
            public System.Runtime.InteropServices.ComTypes.FILETIME Date;
            public uint CompatOffset, CompatLength;
            public UIntPtr Reserved;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 256)] public string Section;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 260)] public string Inf;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 256)] public string Description;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 1)] public string HardwareId;
        }
        [DllImport("setupapi.dll", SetLastError = true)]
        static extern IntPtr SetupDiCreateDeviceInfoList(IntPtr guid, IntPtr parent);
        [DllImport("setupapi.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        static extern bool SetupDiOpenDeviceInfo(IntPtr set, string id, IntPtr parent, uint flags, ref DeviceInfo device);
        [DllImport("setupapi.dll", SetLastError = true)]
        static extern bool SetupDiBuildDriverInfoList(IntPtr set, ref DeviceInfo device, uint type);
        [DllImport("setupapi.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        static extern bool SetupDiEnumDriverInfo(IntPtr set, ref DeviceInfo device, uint type, uint index, ref DriverInfo driver);
        [DllImport("setupapi.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        static extern bool SetupDiGetDriverInfoDetail(IntPtr set, ref DeviceInfo device, ref DriverInfo driver, IntPtr detail, uint size, out uint required);
        [DllImport("newdev.dll", SetLastError = true)]
        static extern bool DiInstallDevice(IntPtr parent, IntPtr set, ref DeviceInfo device, ref DriverInfo driver, uint flags, out bool reboot);
        [DllImport("setupapi.dll")]
        static extern bool SetupDiDestroyDriverInfoList(IntPtr set, ref DeviceInfo device, uint type);
        [DllImport("setupapi.dll")]
        static extern bool SetupDiDestroyDeviceInfoList(IntPtr set);
        static void Check(bool ok) { if (!ok) throw new Win32Exception(Marshal.GetLastWin32Error()); }
        static string VersionString(ulong v) {
            return String.Format("{0}.{1}.{2}.{3}", v >> 48, (v >> 32) & 65535, (v >> 16) & 65535, v & 65535);
        }
        static Detail ReadDetail(IntPtr set, ref DeviceInfo device, ref DriverInfo driver) {
            uint required;
            bool ok = SetupDiGetDriverInfoDetail(set, ref device, ref driver, IntPtr.Zero, 0, out required);
            int error = Marshal.GetLastWin32Error();
            if (!ok && error != 122) throw new Win32Exception(error);
            int header = Marshal.SizeOf(typeof(Detail));
            uint size = Math.Max(required, (uint)header);
            IntPtr buffer = Marshal.AllocHGlobal(checked((int)size));
            try {
                Marshal.WriteInt32(buffer, header);
                Check(SetupDiGetDriverInfoDetail(set, ref device, ref driver, buffer, size, out required));
                return (Detail)Marshal.PtrToStructure(buffer, typeof(Detail));
            } finally { Marshal.FreeHGlobal(buffer); }
        }
        static Driver[] Run(string id, Driver requested, out bool reboot) {
            reboot = false;
            var result = new List<Driver>();
            var device = new DeviceInfo { Size = (uint)Marshal.SizeOf(typeof(DeviceInfo)) };
            IntPtr set = SetupDiCreateDeviceInfoList(IntPtr.Zero, IntPtr.Zero);
            if (set == new IntPtr(-1)) throw new Win32Exception(Marshal.GetLastWin32Error());
            bool built = false;
            try {
                Check(SetupDiOpenDeviceInfo(set, id, IntPtr.Zero, 0, ref device));
                Check(SetupDiBuildDriverInfoList(set, ref device, 2));
                built = true;
                for (uint i = 0; ; i++) {
                    var driver = new DriverInfo { Size = (uint)Marshal.SizeOf(typeof(DriverInfo)) };
                    if (!SetupDiEnumDriverInfo(set, ref device, 2, i, ref driver)) {
                        int error = Marshal.GetLastWin32Error();
                        if (error == 259) break;
                        throw new Win32Exception(error);
                    }
                    Detail detail = ReadDetail(set, ref device, ref driver);
                    var candidate = new Driver { Description = driver.Description, Provider = driver.Provider,
                        InfPath = detail.Inf, Section = detail.Section, Version = VersionString(driver.Version) };
                    result.Add(candidate);
                    // Install only a driver freshly enumerated as compatible with this exact instance.
                    if (requested != null && String.Equals(candidate.InfPath, requested.InfPath, StringComparison.OrdinalIgnoreCase)
                        && String.Equals(candidate.Section, requested.Section, StringComparison.OrdinalIgnoreCase)
                        && candidate.Version == requested.Version) {
                        Check(DiInstallDevice(IntPtr.Zero, set, ref device, ref driver, 0, out reboot));
                        return result.ToArray();
                    }
                }
                if (requested != null) throw new InvalidOperationException("Selected compatible driver disappeared; no installation attempted.");
                return result.ToArray();
            } finally {
                if (built) SetupDiDestroyDriverInfoList(set, ref device, 2);
                SetupDiDestroyDeviceInfoList(set);
            }
        }
        public static Driver[] List(string id) { bool reboot; return Run(id, null, out reboot); }
        public static bool Install(string id, string inf, string section, string version) {
            bool reboot;
            Run(id, new Driver { InfPath = inf, Section = section, Version = version }, out reboot);
            return reboot;
        }
    }
}
'@
}

function Assert-UsbInstanceId([string]$Id) {
    if ($Id -notmatch '^USB\\VID_[0-9A-F]{4}&PID_[0-9A-F]{4}[^\\]*\\[^\\]+$' -or $Id -match '[*?\[\]]') {
        throw 'Specify one exact USB VID/PID device instance ID; wildcards and non-USB devices are refused.'
    }
}

function Get-UsbDeviceState([string]$Id) {
    # Keep the outer stage visible without the PnP cmdlet's code-like progress text.
    $ProgressPreference = 'SilentlyContinue'
    $quietProgress = @{}
    if ((Get-Command Get-PnpDeviceProperty).Parameters.ContainsKey('ProgressAction')) {
        $quietProgress.ProgressAction = 'SilentlyContinue'
    }
    Assert-UsbInstanceId $Id
    $device = @(Get-PnpDevice -InstanceId $Id -ErrorAction Stop @quietProgress | Where-Object InstanceId -eq $Id)
    if ($device.Count -ne 1) { throw 'Device instance is missing or ambiguous.' }
    $p = @{}
    foreach ($prop in (Get-PnpDeviceProperty -InstanceId $Id -ErrorAction Stop @quietProgress)) { $p[$prop.KeyName] = $prop.Data }
    [pscustomobject][ordered]@{
        InstanceId = $device[0].InstanceId; Name = $device[0].FriendlyName; Class = $device[0].Class
        Present = ($p['DEVPKEY_Device_IsPresent'] -eq $true)
        ProblemCode = $p['DEVPKEY_Device_ProblemCode']; Service = $p['DEVPKEY_Device_Service']
        InfName = $p['DEVPKEY_Device_DriverInfPath']; DriverVersion = $p['DEVPKEY_Device_DriverVersion']
        DriverSection = $p['DEVPKEY_Device_DriverInfSection']; ContainerId = [string]$p['DEVPKEY_Device_ContainerId']
        HardwareIds = @($p['DEVPKEY_Device_HardwareIds']); CompatibleIds = @($p['DEVPKEY_Device_CompatibleIds'])
        Parent = $p['DEVPKEY_Device_Parent']; Children = @($p['DEVPKEY_Device_Children'] | Where-Object { $_ })
        LastArrival = $p['DEVPKEY_Device_LastArrivalDate']; LocationPaths = @($p['DEVPKEY_Device_LocationPaths'])
    }
}

function Get-CompatibleUsbDrivers([string]$Id) {
    Write-UsbOperationProgress 'Reading compatible drivers from Windows; this can take several seconds.'
    Initialize-UsbRepairNative
    @([UsbNetworkRepair.NativeV1]::List($Id) | Sort-Object InfPath, Section, Version -Unique)
}

function Get-UsbRepairAssessment($State) {
    if (-not $State.Present) { return 'NotPresent' }
    if ($State.InstanceId -match '&MI_[0-9A-F]{2}\\') { return 'FunctionInterface' }
    if ($State.CompatibleIds -notcontains 'USB\COMPOSITE') { return 'NotComposite' }
    if ($State.Service -eq 'usbccgp') {
        if ($State.ProblemCode -eq 0) { return 'CompositeParentOK' }
        return 'CompositeParentHasError'
    }
    if ($State.Class -eq 'Net' -and $null -ne $State.ProblemCode -and
        $State.ProblemCode -ne 0 -and $State.ProblemCode -ne 22 -and @($State.Children).Count -eq 0) {
        return 'SuspectedParentMisbind'
    }
    return 'ManualReviewRequired'
}

function Get-UsbRelatedIds([string]$Id) {
    $queue = New-Object 'System.Collections.Generic.Queue[string]'
    $seen = @{}
    $queue.Enqueue($Id)
    while ($queue.Count -gt 0) {
        $current = $queue.Dequeue()
        if ($seen.ContainsKey($current)) { continue }
        $seen[$current] = $true
        if ($seen.Count -gt 256) { throw 'Unexpectedly large device tree; refusing operation.' }
        $current
        $children = Get-PnpDeviceProperty -InstanceId $current -KeyName DEVPKEY_Device_Children -ErrorAction Stop
        foreach ($child in @($children.Data)) { if ($child) { $queue.Enqueue($child) } }
    }
}

function Assert-UsbTargetIdle($State) {
    if (-not $State.Present) { throw 'Target is not present.' }
    $ids = @(Get-UsbRelatedIds $State.InstanceId)
    $devices = @(foreach ($id in $ids) { Get-PnpDevice -InstanceId $id -ErrorAction Stop })
    if (@($devices | Where-Object { $_.Class -in @('HIDClass','Keyboard','Mouse','DiskDrive','Volume','SCSIAdapter','HDC','WPD') }).Count) {
        throw 'Input, storage or portable-device functions are in the target subtree; refusing operation.'
    }
    $connected = @(Get-CimInstance Win32_NetworkAdapter -ErrorAction Stop | Where-Object {
        $_.PNPDeviceID -in $ids -and $_.NetConnectionStatus -in @(1,2,3,8,9,10,11)
    })
    if ($connected.Count) { throw 'Target or descendant network adapter is active; disconnect it first.' }
}

function Assert-UsbAdmin {
    $principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Run this repair operation in an elevated PowerShell window.'
    }
}

function Get-UsbMachineId {
    (Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Cryptography' -ErrorAction Stop).MachineGuid
}

function Get-UsbFullPath([string]$Path) {
    $provider = $null
    $drive = $null
    $resolved = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path, [ref]$provider, [ref]$drive)
    if ($provider.Name -ne 'FileSystem') { throw 'Use a filesystem path.' }
    return $resolved
}

function ConvertTo-UsbShareSafeReport($Result, [int]$Index) {
    # Construct a new allowlisted summary; never copy identifiers or raw errors.
    $device = if ($Result.Device) { $Result.Device } else { $Result }
    $version = if ($device.DriverVersion -match '^\d+\.\d+\.\d+\.\d+$') { $device.DriverVersion } else { $null }
    $observation = $null
    if ($Result.Observation) {
        $o = $Result.Observation
        $observation = [pscustomobject]@{
            DurationSeconds = [double]$o.DurationSeconds; SampleCount = @($o.Samples).Count
            AllSamplesOK = [bool]$o.AllSamplesOK; ReenumerationObserved = [bool]$o.ReenumerationObserved
        }
    }
    $knownAssessments = @('NotPresent','FunctionInterface','NotComposite','CompositeParentOK',
        'CompositeParentHasError','SuspectedParentMisbind','ManualReviewRequired')
    [pscustomobject][ordered]@{
        ShareSafe = $true; DeviceLabel = ('Device-{0}' -f $Index)
        Assessment = $(if ($Result.Assessment -in $knownAssessments) { $Result.Assessment } else { 'Unclassified' })
        ProblemCode = $(if ($null -ne $device.ProblemCode) { [int]$device.ProblemCode } else { $null })
        DriverVersion = $version; CompositeDriverBound = ($device.Service -eq 'usbccgp')
        Observation = $observation
    }
}

function Write-UsbJson([string]$Path, $Value) {
    $temporary = $Path + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
    $Value | ConvertTo-Json -Depth 16 | Set-Content -LiteralPath $temporary -Encoding UTF8 -ErrorAction Stop
    Move-Item -LiteralPath $temporary -Destination $Path -Force -ErrorAction Stop
}

function Invoke-UsbPnPTool([string[]]$Arguments) {
    $output = & (Join-Path $env:SystemRoot 'System32\pnputil.exe') @Arguments 2>&1
    $code = $LASTEXITCODE
    if ($code -notin @(0,3010)) { throw ('PnPUtil failed ({0}): {1}' -f $code, ($output -join "`n")) }
    return ($output -join "`n")
}

function Save-UsbRepairSnapshot($State, $Selected, [string]$Root, [string]$Operation) {
    $folder = Join-Path (Get-UsbFullPath $Root) ((Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N').Substring(0,8))
    New-Item -ItemType Directory -Path $folder -ErrorAction Stop | Out-Null
    $originalInf = Join-Path $env:SystemRoot ('INF\' + $State.InfName)
    if (-not $State.InfName -or -not (Test-Path -LiteralPath $originalInf)) { throw 'Original INF unavailable; no device change made.' }
    $originalHash = (Get-FileHash -LiteralPath $originalInf -Algorithm SHA256 -ErrorAction Stop).Hash
    $manifest = @()
    $backupInf = $null
    if ($State.InfName -match '^oem\d+\.inf$') {
        $backup = Join-Path $folder 'driver-backup'
        New-Item -ItemType Directory -Path $backup -ErrorAction Stop | Out-Null
        Invoke-UsbPnPTool @('/export-driver', $State.InfName, $backup) |
            Set-Content -LiteralPath (Join-Path $folder 'export.log') -Encoding UTF8
        $manifest = @(Get-ChildItem -LiteralPath $backup -Recurse -File | ForEach-Object {
            [pscustomobject]@{ Path = $_.FullName.Substring($folder.Length + 1); SHA256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash }
        })
        $matches = @($manifest | Where-Object { $_.Path -match '\.inf$' -and $_.SHA256 -eq $originalHash })
        if ($matches.Count -ne 1) { throw 'Original driver backup could not be verified; no device change made.' }
        $backupInf = $matches[0].Path
    }
    $path = Join-Path $folder 'before.json'
    Write-UsbJson $path ([ordered]@{
        SchemaVersion = 1; MachineId = Get-UsbMachineId; CreatedUtc = [DateTime]::UtcNow.ToString('o')
        Operation = $Operation; Device = $State; Selected = $Selected; OriginalInfSHA256 = $originalHash
        BackupInf = $backupInf; BackupFiles = $manifest
    })
    return $path
}

function Resolve-UsbBackupPath([string]$Folder, [string]$Relative) {
    $root = [IO.Path]::GetFullPath($Folder).TrimEnd('\') + '\'
    $path = [IO.Path]::GetFullPath((Join-Path $root $Relative))
    if ([IO.Path]::IsPathRooted($Relative) -or -not $path.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Backup path escapes its snapshot directory.'
    }
    return $path
}

function Read-UsbRecoverySnapshot([string]$Path, $Current) {
    $saved = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    if ($saved.SchemaVersion -ne 1 -or $saved.MachineId -ne (Get-UsbMachineId) -or
        $saved.Device.InstanceId -ne $Current.InstanceId -or $saved.Device.ContainerId -ne $Current.ContainerId -or
        ($saved.Device.HardwareIds -join '|') -ne ($Current.HardwareIds -join '|')) {
        throw 'Snapshot does not match this machine and device.'
    }
    if ($saved.OriginalInfSHA256 -notmatch '^[0-9A-F]{64}$' -or -not $saved.Device.DriverVersion -or -not $saved.Device.DriverSection) {
        throw 'Snapshot is missing original driver identity.'
    }
    $folder = Split-Path -Parent (Get-UsbFullPath $Path)
    foreach ($file in @($saved.BackupFiles)) {
        $backupPath = Resolve-UsbBackupPath $folder $file.Path
        if ((Get-FileHash -LiteralPath $backupPath -Algorithm SHA256 -ErrorAction Stop).Hash -ne $file.SHA256) {
            throw 'Driver backup hash mismatch; restore refused.'
        }
    }
    if ($saved.BackupInf) {
        $backupInfPath = Resolve-UsbBackupPath $folder $saved.BackupInf
        if ((Get-FileHash -LiteralPath $backupInfPath -Algorithm SHA256).Hash -ne $saved.OriginalInfSHA256) {
            throw 'Backup INF does not match the original driver.'
        }
    }
    return $saved
}

function Find-UsbSavedDriver($Drivers, $Saved) {
    @($Drivers | Where-Object {
        $_.Version -eq $Saved.Device.DriverVersion -and
        ($Saved.Device.DriverSection -eq $_.Section -or $Saved.Device.DriverSection.StartsWith($_.Section + '.', [StringComparison]::OrdinalIgnoreCase)) -and
        (Get-FileHash -LiteralPath $_.InfPath -Algorithm SHA256 -ErrorAction Stop).Hash -eq $Saved.OriginalInfSHA256
    } | Select-Object -First 1)
}

function Install-UsbSelectedDriver([string]$Id, $Selected) {
    Initialize-UsbRepairNative
    [UsbNetworkRepair.NativeV1]::Install($Id, $Selected.InfPath, $Selected.Section, $Selected.Version)
}

function Get-UsbDescendantStatus([string]$Id) {
    foreach ($child in @(Get-UsbRelatedIds $Id | Where-Object { $_ -ne $Id })) {
        $device = Get-PnpDevice -InstanceId $child -ErrorAction Stop
        [pscustomobject]@{ InstanceId = $child; Name = $device.FriendlyName; Class = $device.Class
            ProblemCode = [int]$device.Problem; Status = [string]$device.Status }
    }
}

function Watch-UsbDevice([string]$Id, [int]$Seconds) {
    $samples = New-Object 'System.Collections.Generic.List[object]'
    $clock = [Diagnostics.Stopwatch]::StartNew()
    do {
        $remaining = [Math]::Max(0, [Math]::Ceiling($Seconds - $clock.Elapsed.TotalSeconds))
        $percent = if ($Seconds) { [Math]::Min(99, [int](100 * $clock.Elapsed.TotalSeconds / $Seconds)) } else { -1 }
        Write-UsbOperationProgress -Status ('Observing device: {0} sample(s); {1}s elapsed. Querying Windows.' -f $samples.Count, [int]$clock.Elapsed.TotalSeconds) -Percent $percent -Remaining $remaining
        try {
            $state = Get-UsbDeviceState $Id
            $samples.Add([pscustomobject]@{ TimeUtc = [DateTime]::UtcNow.ToString('o'); Present = $state.Present
                ProblemCode = $state.ProblemCode; LastArrival = $state.LastArrival; ReadError = $null })
        } catch {
            $samples.Add([pscustomobject]@{ TimeUtc = [DateTime]::UtcNow.ToString('o'); Present = $false
                ProblemCode = $null; LastArrival = $null; ReadError = $_.Exception.Message })
        }
        if ($clock.Elapsed.TotalSeconds -ge $Seconds) { break }
        $pauseUntil = [Math]::Min($Seconds, $clock.Elapsed.TotalSeconds + 3)
        while ($clock.Elapsed.TotalSeconds -lt $pauseUntil) {
            $remaining = [Math]::Max(0, [Math]::Ceiling($Seconds - $clock.Elapsed.TotalSeconds))
            $percent = [Math]::Min(99, [int](100 * $clock.Elapsed.TotalSeconds / $Seconds))
            Write-UsbOperationProgress -Status ('Observing device: {0} sample(s); {1}s elapsed.' -f $samples.Count, [int]$clock.Elapsed.TotalSeconds) -Percent $percent -Remaining $remaining
            Start-Sleep -Milliseconds 250
        }
    } while ($true)
    $arrivals = @($samples | Where-Object LastArrival | Select-Object -ExpandProperty LastArrival -Unique)
    $bad = @($samples | Where-Object { -not $_.Present -or $null -eq $_.ProblemCode -or $_.ProblemCode -ne 0 })
    [pscustomobject]@{ DurationSeconds = [Math]::Round($clock.Elapsed.TotalSeconds,1); Samples = $samples.ToArray()
        ReenumerationObserved = ($arrivals.Count -gt 1); AllSamplesOK = ($bad.Count -eq 0)
        Assessment = $(if ($bad.Count -or $arrivals.Count -gt 1) { 'UnstableOrError' } elseif ($Seconds -eq 0) { 'SingleSampleOnly' } else { 'NoIssueObservedDuringWindow' }) }
}

function Invoke-UsbNetworkRepair {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [ValidateSet('Inspect','RepairParent','BindDriver','Restore')][string]$Action = 'Inspect',
        [string]$InstanceId, [string]$DriverInf, [string]$DriverSection, [string]$Snapshot,
        [string]$ReportRoot,
        [switch]$ShareSafe,
        [switch]$NoProgress,
        [ValidateRange(0,300)][int]$WatchSeconds = 0
    )
    $ErrorActionPreference = 'Stop'
    if ($NoProgress) { $ProgressPreference = 'SilentlyContinue' }
    if (-not $ReportRoot) { $ReportRoot = Join-Path $PSScriptRoot 'reports' }
    if ($ShareSafe) {
        if ($Action -ne 'Inspect') { throw 'ShareSafe is only accepted for Inspect; recovery snapshots must retain exact identifiers.' }
        $privateParameters = @{}
        foreach ($key in $PSBoundParameters.Keys) {
            if ($key -ne 'ShareSafe') { $privateParameters[$key] = $PSBoundParameters[$key] }
        }
        $index = 0
        foreach ($result in @(Invoke-UsbNetworkRepair @privateParameters)) {
            $index++
            ConvertTo-UsbShareSafeReport $result $index
        }
        return
    }
    if ($Action -ne 'Restore' -and $Snapshot) { throw 'Snapshot is only accepted for Restore.' }
    if ($Action -ne 'BindDriver' -and ($DriverInf -or $DriverSection)) { throw 'Driver selection is only accepted for BindDriver.' }
    if ($Action -eq 'Restore' -and (-not $Snapshot -or -not $InstanceId)) { throw 'Restore requires Snapshot and the original InstanceId.' }
    if (-not $InstanceId) {
        if ($Action -ne 'Inspect' -or $WatchSeconds) { throw 'Specify InstanceId for changes or timed observation.' }
        try {
            Write-UsbOperationProgress 'Finding USB network adapters. Read-only; Windows queries can take tens of seconds.'
            $ids = @{}
            $states = @{}
            $devices = @(Get-PnpDevice -PresentOnly -Class Net -ErrorAction Stop | Where-Object InstanceId -match '^USB\\VID_')
            $index = 0
            foreach ($device in $devices) {
                $index++
                Write-UsbOperationProgress ('Reading adapter {0} of {1}. No network settings are changed.' -f $index, $devices.Count)
                if (-not $states.ContainsKey($device.InstanceId)) { $states[$device.InstanceId] = Get-UsbDeviceState $device.InstanceId }
                $state = $states[$device.InstanceId]
                $ids[$state.InstanceId] = $true
                if ($state.Parent -match '^USB\\VID_') { $ids[$state.Parent] = $true }
            }
            foreach ($id in ($ids.Keys | Sort-Object)) {
                if (-not $states.ContainsKey($id)) {
                    Write-UsbOperationProgress 'Reading USB parent device. No network settings are changed.'
                    $states[$id] = Get-UsbDeviceState $id
                }
                $state = $states[$id]
                [pscustomobject]@{ InstanceId = $id; Name = $state.Name; ProblemCode = $state.ProblemCode
                    Service = $state.Service; DriverVersion = $state.DriverVersion; Assessment = Get-UsbRepairAssessment $state }
            }
        } finally { Write-UsbOperationProgress -Completed }
        return
    }
    Assert-UsbInstanceId $InstanceId
    if ($Action -eq 'Inspect') {
        try {
            Write-UsbOperationProgress 'Reading selected device. Read-only; Windows queries can take tens of seconds.'
            $state = Get-UsbDeviceState $InstanceId
            $drivers = @()
            if ($state.Present) { $drivers = @(Get-CompatibleUsbDrivers $InstanceId) }
            $observation = $null
            if ($WatchSeconds) { $observation = Watch-UsbDevice $InstanceId $WatchSeconds }
            return [pscustomobject]@{ Device = $state; Assessment = Get-UsbRepairAssessment $state
                CompatibleDrivers = $drivers; Observation = $observation }
        } finally { Write-UsbOperationProgress -Completed }
    }
    Write-UsbOperationProgress 'Checking repair target and safety conditions.'
    $state = Get-UsbDeviceState $InstanceId
    $mutex = New-Object Threading.Mutex($false, 'Global\UsbNetworkDriverRepair-v1')
    $owned = $false
    $snapshotPath = $null
    try {
        try { $owned = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $owned = $true }
        if (-not $owned) { throw 'Another USB driver repair is running.' }
        $state = Get-UsbDeviceState $InstanceId
        $drivers = @(Get-CompatibleUsbDrivers $InstanceId)
        $selected = $null
        $saved = $null
        if ($Action -eq 'RepairParent') {
            $assessment = Get-UsbRepairAssessment $state
            if ($assessment -eq 'CompositeParentOK') { return [pscustomobject]@{ Status = 'AlreadyCorrect'; Device = $state } }
            if ($assessment -ne 'SuspectedParentMisbind') { throw ('Automatic parent repair refused: ' + $assessment) }
            $usbInf = Join-Path $env:SystemRoot 'INF\usb.inf'
            $choices = @($drivers | Where-Object { $_.InfPath -eq $usbInf -and $_.Section -eq 'Composite.Dev' })
        } elseif ($Action -eq 'BindDriver') {
            if ($state.Class -ne 'Net' -or $InstanceId -notmatch '&MI_[0-9A-F]{2}\\') {
                throw 'BindDriver is restricted to a network-class USB function interface.'
            }
            if (-not $DriverInf) { throw 'Select an already staged INF from Inspect output.' }
            if ($state.ProblemCode -eq 22) { throw 'Target is disabled; this script does not change its enabled state.' }
            $infPath = if ([IO.Path]::IsPathRooted($DriverInf)) { [IO.Path]::GetFullPath($DriverInf) } else { Join-Path $env:SystemRoot ('INF\' + $DriverInf) }
            $choices = @($drivers | Where-Object { $_.InfPath -eq $infPath -and (-not $DriverSection -or $_.Section -eq $DriverSection) })
        } else {
            $saved = Read-UsbRecoverySnapshot $Snapshot $state
            $choices = @(Find-UsbSavedDriver $drivers $saved)
            if (-not $choices.Count -and -not $saved.BackupInf) { throw 'Original compatible driver is unavailable and has no exported backup.' }
        }
        if ($choices.Count -gt 1) { throw 'Driver selection is ambiguous; supply DriverSection from Inspect.' }
        if (-not $choices.Count -and $Action -ne 'Restore') { throw 'Requested driver is not in this device compatible-driver list.' }
        if ($choices.Count) { $selected = $choices[0] }
        Assert-UsbTargetIdle $state
        $description = if ($selected) { '{0}: {1} [{2}] {3}' -f $Action, $selected.InfPath, $selected.Section, $selected.Version } else { 'Restore: stage verified backup and restore original binding' }
        if (-not $PSCmdlet.ShouldProcess($InstanceId, $description)) {
            return [pscustomobject]@{ Status = 'PreviewOnly'; Device = $state; Selected = $selected }
        }
        Assert-UsbAdmin
        # Persist recovery before staging or changing any driver binding.
        Write-UsbOperationProgress 'Backing up the original driver before any change.'
        $snapshotPath = Save-UsbRepairSnapshot $state $selected $ReportRoot $Action
        if (-not $selected) {
            $backupInf = Resolve-UsbBackupPath (Split-Path -Parent (Get-UsbFullPath $Snapshot)) $saved.BackupInf
            Invoke-UsbPnPTool @('/add-driver', $backupInf) | Set-Content -LiteralPath (Join-Path (Split-Path $snapshotPath) 'stage.log') -Encoding UTF8
            $choices = @(Find-UsbSavedDriver @(Get-CompatibleUsbDrivers $InstanceId) $saved)
            if ($choices.Count -ne 1) { throw 'Original driver is still unavailable after staging.' }
            $selected = $choices[0]
        }
        $current = Get-UsbDeviceState $InstanceId
        if ($current.ContainerId -ne $state.ContainerId -or ($current.HardwareIds -join '|') -ne ($state.HardwareIds -join '|') -or
            $current.InfName -ne $state.InfName -or $current.DriverVersion -ne $state.DriverVersion) {
            throw 'Device identity or binding changed during preparation; stopped.'
        }
        Assert-UsbTargetIdle $current
        Write-UsbOperationProgress 'Applying selected driver. Do not unplug the device during installation.'
        $reboot = Install-UsbSelectedDriver $InstanceId $selected
        $observation = Watch-UsbDevice $InstanceId ([Math]::Max(10,$WatchSeconds))
        $after = Get-UsbDeviceState $InstanceId
        $bindingMatches = $after.InfName -eq [IO.Path]::GetFileName($selected.InfPath) -and $after.DriverVersion -eq $selected.Version
        $descendants = @(Get-UsbDescendantStatus $InstanceId)
        $childErrors = @($descendants | Where-Object { $_.ProblemCode -notin @(0,22) })
        $status = if ($reboot) { 'RebootRequired' } elseif (-not $bindingMatches -or -not $observation.AllSamplesOK -or $observation.ReenumerationObserved -or $childErrors.Count) { 'NeedsAttention' } else { 'BindingApplied' }
        $result = [pscustomobject]@{ Status = $status; RebootRequired = $reboot; Snapshot = $snapshotPath
            BindingMatches = $bindingMatches; Device = $after; Descendants = $descendants; Observation = $observation }
        Write-UsbJson (Join-Path (Split-Path $snapshotPath) 'after.json') $result
        return $result
    } catch {
        if ($snapshotPath) {
            $failure = $_.Exception.Message
            Write-UsbJson (Join-Path (Split-Path $snapshotPath) 'failure.json') @{ Error = $failure; Snapshot = $snapshotPath; TimeUtc = [DateTime]::UtcNow.ToString('o') }
            Write-Warning ('Recovery snapshot retained: ' + $snapshotPath)
        }
        throw
    } finally {
        if ($owned) { $mutex.ReleaseMutex() }
        $mutex.Dispose()
        Write-UsbOperationProgress -Completed
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    if ($NoProgress) { $ProgressPreference = 'SilentlyContinue' }
    try {
        $result = @(Invoke-UsbNetworkRepair @PSBoundParameters)
        if ($result.Count) { $result | ConvertTo-Json -Depth 16 } else { '[]' }
    } catch {
        if ($ShareSafe) {
            [pscustomobject]@{ ShareSafe = $true; Status = 'InspectFailed'; Message = 'Inspection failed. Run without ShareSafe locally for details; do not publish raw errors.' } | ConvertTo-Json
            exit 1
        }
        Write-Error -Message $_.Exception.Message -ErrorAction Continue
        exit 1
    } finally { Write-UsbOperationProgress -Completed }
}
