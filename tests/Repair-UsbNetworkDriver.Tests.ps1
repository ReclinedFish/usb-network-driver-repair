$scriptPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'Repair-UsbNetworkDriver.ps1'
. $scriptPath

function New-TestState {
    [pscustomobject]@{
        InstanceId='USB\VID_1234&PID_ABCD\SERIAL'; Name='Test network device'; Class='Net'; Present=$true
        ProblemCode=10; Service='testwifi'; InfName='usb.inf'; DriverVersion='1.2.3.4'; DriverSection='Composite.Dev.NT'
        HardwareIds=@('USB\VID_1234&PID_ABCD'); CompatibleIds=@('USB\COMPOSITE'); ContainerId='test-container'
        Children=@(); Parent='USB\ROOT_HUB30\TEST'; LastArrival=[datetime]'2026-01-01'; LocationPaths=@('test')
    }
}

Describe 'Target validation and diagnosis' {
    It 'accepts arbitrary vendor and interface instance IDs' {
        { Assert-UsbInstanceId 'USB\VID_9876&PID_1234&MI_07\ABC' } | Should Not Throw
    }
    It 'refuses wildcard IDs' { { Assert-UsbInstanceId 'USB\VID_1234&PID_ABCD\*' } | Should Throw }
    It 'refuses non-USB IDs' { { Assert-UsbInstanceId 'PCI\VEN_1234\ABC' } | Should Throw }
    It 'refuses root hubs' { { Assert-UsbInstanceId 'USB\ROOT_HUB30\ABC' } | Should Throw }
    It 'recognizes a failed composite network parent as a candidate, not a proven fault' {
        Get-UsbRepairAssessment (New-TestState) | Should Be 'SuspectedParentMisbind'
    }
    It 'does not flag a healthy vendor-owned composite parent for automatic repair' {
        $state=New-TestState; $state.ProblemCode=0
        Get-UsbRepairAssessment $state | Should Be 'ManualReviewRequired'
    }
    It 'does not auto-repair intentionally disabled devices' {
        $state=New-TestState; $state.ProblemCode=22
        Get-UsbRepairAssessment $state | Should Be 'ManualReviewRequired'
    }
    It 'does not convert a function interface into a composite parent' {
        $state=New-TestState; $state.InstanceId='USB\VID_1234&PID_ABCD&MI_07\ABC'
        Get-UsbRepairAssessment $state | Should Be 'FunctionInterface'
    }
    It 'does not auto-repair a parent with existing children' {
        $state=New-TestState; $state.Children=@('USB\VID_1234&PID_ABCD&MI_07\ABC')
        Get-UsbRepairAssessment $state | Should Be 'ManualReviewRequired'
    }
    It 'does not equate any composite driver error with a misbinding' {
        $state=New-TestState; $state.Service='usbccgp'
        Get-UsbRepairAssessment $state | Should Be 'CompositeParentHasError'
    }
}

Describe 'Activity protection' {
    BeforeEach {
        Mock Get-UsbRelatedIds { @('USB\VID_1234&PID_ABCD\SERIAL','USB\VID_1234&PID_ABCD&MI_07\ABC') }
        Mock Get-PnpDevice { [pscustomobject]@{Class='Net'} }
        Mock Get-CimInstance { @() }
    }
    It 'refuses an active descendant adapter' {
        Mock Get-CimInstance { [pscustomobject]@{PNPDeviceID='USB\VID_1234&PID_ABCD&MI_07\ABC';NetConnectionStatus=2} }
        { Assert-UsbTargetIdle (New-TestState) } | Should Throw
    }
    It 'refuses authenticating descendants' {
        Mock Get-CimInstance { [pscustomobject]@{PNPDeviceID='USB\VID_1234&PID_ABCD&MI_07\ABC';NetConnectionStatus=8} }
        { Assert-UsbTargetIdle (New-TestState) } | Should Throw
    }
    It 'does not block on an unrelated connected network adapter' {
        Mock Get-CimInstance { [pscustomobject]@{PNPDeviceID='PCI\VEN_8086\PRIMARY';NetConnectionStatus=2} }
        { Assert-UsbTargetIdle (New-TestState) } | Should Not Throw
    }
    It 'refuses input-device subtrees' {
        Mock Get-PnpDevice { [pscustomobject]@{Class='Keyboard'} }
        { Assert-UsbTargetIdle (New-TestState) } | Should Throw
    }
    It 'refuses storage subtrees' {
        Mock Get-PnpDevice { [pscustomobject]@{Class='DiskDrive'} }
        { Assert-UsbTargetIdle (New-TestState) } | Should Throw
    }
}

Describe 'Repair orchestration without touching hardware' {
    BeforeEach {
        $script:testState=New-TestState
        $script:testDriver=[pscustomobject]@{InfPath=(Join-Path $env:SystemRoot 'INF\usb.inf');Section='Composite.Dev';Version='1.2.3.4';Provider='Microsoft';Description='Composite'}
        $script:snapshotFile=Join-Path $TestDrive 'report\before.json'
        Mock Get-UsbDeviceState { $script:testState }
        Mock Get-CompatibleUsbDrivers { @($script:testDriver) }
        Mock Assert-UsbTargetIdle { }
        Mock Assert-UsbAdmin { }
        Mock Save-UsbRepairSnapshot {
            New-Item -ItemType Directory -Path (Split-Path $script:snapshotFile) -Force | Out-Null
            Write-UsbJson $script:snapshotFile @{Saved=$true}
            $script:snapshotFile
        }
        Mock Install-UsbSelectedDriver {
            if (-not (Test-Path -LiteralPath $script:snapshotFile)) { throw 'Backup missing before mutation.' }
            $script:testState.ProblemCode=0; $script:testState.Service='usbccgp'
            $false
        }
        Mock Watch-UsbDevice { [pscustomobject]@{AllSamplesOK=$true;ReenumerationObserved=$false} }
        Mock Get-UsbDescendantStatus { @() }
    }
    It 'requires explicit selection for repair' {
        { Invoke-UsbNetworkRepair -Action RepairParent } | Should Throw
        Assert-MockCalled Install-UsbSelectedDriver -Times 0 -Exactly -Scope It
    }
    It 'keeps Inspect read-only' {
        $result=Invoke-UsbNetworkRepair -InstanceId $script:testState.InstanceId
        $result.Assessment | Should Be 'SuspectedParentMisbind'
        Assert-MockCalled Install-UsbSelectedDriver -Times 0 -Exactly -Scope It
        Assert-MockCalled Save-UsbRepairSnapshot -Times 0 -Exactly -Scope It
    }
    It 'exports an identifier-free inspection summary' {
        $script:testState.Name='PRIVATE_SENTINEL'
        $result=Invoke-UsbNetworkRepair -InstanceId $script:testState.InstanceId -ShareSafe
        $result.ShareSafe | Should Be $true
        $result.DeviceLabel | Should Be 'Device-1'
        ($result | ConvertTo-Json -Depth 10) | Should Not Match 'PRIVATE_SENTINEL|VID_1234|test-container|InstanceId|InfPath'
        Assert-MockCalled Install-UsbSelectedDriver -Times 0 -Exactly -Scope It
        Assert-MockCalled Save-UsbRepairSnapshot -Times 0 -Exactly -Scope It
    }
    It 'refuses ShareSafe for repairs before any backup or install' {
        { Invoke-UsbNetworkRepair -Action RepairParent -InstanceId $script:testState.InstanceId -ShareSafe } | Should Throw
        Assert-MockCalled Install-UsbSelectedDriver -Times 0 -Exactly -Scope It
        Assert-MockCalled Save-UsbRepairSnapshot -Times 0 -Exactly -Scope It
    }
    It 'keeps the default report directory relative to the script when invoked elsewhere' {
        $script:expectedReports=Join-Path (Split-Path $scriptPath) 'reports'
        Push-Location $TestDrive
        try { Invoke-UsbNetworkRepair -Action RepairParent -InstanceId $script:testState.InstanceId -Confirm:$false | Out-Null }
        finally { Pop-Location }
        Assert-MockCalled Save-UsbRepairSnapshot -Times 1 -Exactly -Scope It -ParameterFilter { $Root -eq $script:expectedReports }
    }
    It 'does not back up, stage or install on WhatIf' {
        $result=Invoke-UsbNetworkRepair -Action RepairParent -InstanceId $script:testState.InstanceId -WhatIf
        $result.Status | Should Be 'PreviewOnly'
        Assert-MockCalled Save-UsbRepairSnapshot -Times 0 -Exactly -Scope It
        Assert-MockCalled Install-UsbSelectedDriver -Times 0 -Exactly -Scope It
    }
    It 'does not rebind an already correct composite parent' {
        $script:testState.Service='usbccgp'; $script:testState.ProblemCode=0
        (Invoke-UsbNetworkRepair -Action RepairParent -InstanceId $script:testState.InstanceId).Status | Should Be 'AlreadyCorrect'
        Assert-MockCalled Install-UsbSelectedDriver -Times 0 -Exactly -Scope It
    }
    It 'refuses a missing compatible composite driver' {
        Mock Get-CompatibleUsbDrivers { @() }
        { Invoke-UsbNetworkRepair -Action RepairParent -InstanceId $script:testState.InstanceId } | Should Throw
        Assert-MockCalled Install-UsbSelectedDriver -Times 0 -Exactly -Scope It
    }
    It 'backs up before installing and checks the resulting binding' {
        $result=Invoke-UsbNetworkRepair -Action RepairParent -InstanceId $script:testState.InstanceId -Confirm:$false
        $result.Status | Should Be 'BindingApplied'
        Assert-MockCalled Assert-UsbTargetIdle -Times 2 -Exactly -Scope It
        Assert-MockCalled Install-UsbSelectedDriver -Times 1 -Exactly -Scope It
        Test-Path (Join-Path (Split-Path $script:snapshotFile) 'after.json') | Should Be $true
    }
    It 'stops when backup fails' {
        Mock Save-UsbRepairSnapshot { throw 'Export failed.' }
        { Invoke-UsbNetworkRepair -Action RepairParent -InstanceId $script:testState.InstanceId -Confirm:$false } | Should Throw
        Assert-MockCalled Install-UsbSelectedDriver -Times 0 -Exactly -Scope It
    }
    It 'retains a failure report if installation fails' {
        Mock Install-UsbSelectedDriver { throw 'Native install failed.' }
        { Invoke-UsbNetworkRepair -Action RepairParent -InstanceId $script:testState.InstanceId -Confirm:$false } | Should Throw
        Test-Path (Join-Path (Split-Path $script:snapshotFile) 'failure.json') | Should Be $true
    }
    It 'reports unstable observations as NeedsAttention' {
        Mock Watch-UsbDevice { [pscustomobject]@{AllSamplesOK=$true;ReenumerationObserved=$true} }
        (Invoke-UsbNetworkRepair -Action RepairParent -InstanceId $script:testState.InstanceId -Confirm:$false).Status | Should Be 'NeedsAttention'
    }
    It 'does not hide child-device errors behind a healthy parent' {
        Mock Get-UsbDescendantStatus { [pscustomobject]@{ProblemCode=10} }
        (Invoke-UsbNetworkRepair -Action RepairParent -InstanceId $script:testState.InstanceId -Confirm:$false).Status | Should Be 'NeedsAttention'
    }
    It 'preserves intentional disabled children without treating them as fixed' {
        Mock Get-UsbDescendantStatus { [pscustomobject]@{ProblemCode=22} }
        $result=Invoke-UsbNetworkRepair -Action RepairParent -InstanceId $script:testState.InstanceId -Confirm:$false
        $result.Status | Should Be 'BindingApplied'
        $result.Descendants[0].ProblemCode | Should Be 22
    }
    It 'reports reboot requirement without rebooting' {
        Mock Install-UsbSelectedDriver { $true }
        (Invoke-UsbNetworkRepair -Action RepairParent -InstanceId $script:testState.InstanceId -Confirm:$false).Status | Should Be 'RebootRequired'
    }
    It 'refuses BindDriver on a parent' {
        { Invoke-UsbNetworkRepair -Action BindDriver -InstanceId $script:testState.InstanceId -DriverInf 'usb.inf' } | Should Throw
        Assert-MockCalled Install-UsbSelectedDriver -Times 0 -Exactly -Scope It
    }
    It 'refuses a driver not enumerated as compatible with the selected function' {
        $script:testState.InstanceId='USB\VID_1234&PID_ABCD&MI_07\ABC'
        { Invoke-UsbNetworkRepair -Action BindDriver -InstanceId $script:testState.InstanceId -DriverInf 'oem99999.inf' } | Should Throw
        Assert-MockCalled Install-UsbSelectedDriver -Times 0 -Exactly -Scope It
    }
    It 'checks activity again after backup' {
        $script:idleChecks=0
        Mock Assert-UsbTargetIdle {
            $script:idleChecks++
            if ($script:idleChecks -eq 2) { throw 'Target connected during backup.' }
        }
        { Invoke-UsbNetworkRepair -Action RepairParent -InstanceId $script:testState.InstanceId -Confirm:$false } | Should Throw
        Assert-MockCalled Save-UsbRepairSnapshot -Times 1 -Exactly -Scope It
        Assert-MockCalled Install-UsbSelectedDriver -Times 0 -Exactly -Scope It
    }
    It 'stops if the device identity changes during backup' {
        $script:reads=0
        Mock Get-UsbDeviceState {
            $script:reads++
            $copy=$script:testState.PSObject.Copy()
            if ($script:reads -ge 3) { $copy.ContainerId='replacement-device' }
            $copy
        }
        { Invoke-UsbNetworkRepair -Action RepairParent -InstanceId $script:testState.InstanceId -Confirm:$false } | Should Throw
        Assert-MockCalled Install-UsbSelectedDriver -Times 0 -Exactly -Scope It
    }
    It 'refuses ambiguous driver sections' {
        $script:testState.InstanceId='USB\VID_1234&PID_ABCD&MI_07\ABC'
        Mock Get-CompatibleUsbDrivers {
            $script:testDriver
            $copy=$script:testDriver.PSObject.Copy(); $copy.Section='AnotherSection'; $copy
        }
        { Invoke-UsbNetworkRepair -Action BindDriver -InstanceId $script:testState.InstanceId -DriverInf 'usb.inf' } | Should Throw
        Assert-MockCalled Install-UsbSelectedDriver -Times 0 -Exactly -Scope It
    }
    It 'restores an existing compatible driver using saved content identity' {
        Mock Read-UsbRecoverySnapshot { [pscustomobject]@{BackupInf=$null;Device=$script:testState} }
        Mock Find-UsbSavedDriver { @($script:testDriver) }
        Mock Invoke-UsbPnPTool { throw 'No staging should be needed.' }
        $result=Invoke-UsbNetworkRepair -Action Restore -InstanceId $script:testState.InstanceId -Snapshot 'mock-before.json' -Confirm:$false
        $result.Status | Should Be 'BindingApplied'
        Assert-MockCalled Install-UsbSelectedDriver -Times 1 -Exactly -Scope It
        Assert-MockCalled Invoke-UsbPnPTool -Times 0 -Exactly -Scope It
    }
    It 'does not stage an absent old driver during Restore WhatIf' {
        Mock Read-UsbRecoverySnapshot { [pscustomobject]@{BackupInf='backup\old.inf';Device=$script:testState} }
        Mock Find-UsbSavedDriver { @() }
        Mock Invoke-UsbPnPTool { throw 'No staging allowed in preview.' }
        $result=Invoke-UsbNetworkRepair -Action Restore -InstanceId $script:testState.InstanceId -Snapshot 'mock-before.json' -WhatIf
        $result.Status | Should Be 'PreviewOnly'
        Assert-MockCalled Invoke-UsbPnPTool -Times 0 -Exactly -Scope It
        Assert-MockCalled Install-UsbSelectedDriver -Times 0 -Exactly -Scope It
        Assert-MockCalled Save-UsbRepairSnapshot -Times 0 -Exactly -Scope It
    }
    It 'stages an absent original driver without the broad install switch' {
        Mock Read-UsbRecoverySnapshot { [pscustomobject]@{BackupInf='backup\old.inf';Device=$script:testState} }
        $script:findCount=0
        Mock Find-UsbSavedDriver {
            $script:findCount++
            if ($script:findCount -gt 1) { @($script:testDriver) } else { @() }
        }
        Mock Invoke-UsbPnPTool {
            if ($Arguments[0] -ne '/add-driver' -or $Arguments -contains '/install' -or $Arguments.Count -ne 2) {
                throw 'Unexpected broad staging operation.'
            }
            'Driver staged'
        }
        $result=Invoke-UsbNetworkRepair -Action Restore -InstanceId $script:testState.InstanceId -Snapshot 'mock-before.json' -Confirm:$false
        $result.Status | Should Be 'BindingApplied'
        Assert-MockCalled Invoke-UsbPnPTool -Times 1 -Exactly -Scope It
    }
}

Describe 'Privacy and working-directory portability' {
    It 'excludes nested sample identifiers, timestamps and error text' {
        $result=[pscustomobject]@{Device=(New-TestState);Assessment='FunctionInterface';Extra='PRIVATE_SENTINEL'
            Observation=[pscustomobject]@{DurationSeconds=60;AllSamplesOK=$false;ReenumerationObserved=$true
                Samples=@(@{TimeUtc='PRIVATE_SENTINEL';ReadError='PRIVATE_SENTINEL';LastArrival='PRIVATE_SENTINEL'})}}
        $safe=ConvertTo-UsbShareSafeReport $result 2
        $safe.Observation.SampleCount | Should Be 1
        $safe.Observation.ReenumerationObserved | Should Be $true
        ($safe | ConvertTo-Json -Depth 10) | Should Not Match 'PRIVATE_SENTINEL|TimeUtc|LastArrival|ReadError|SERIAL'
    }
    It 'does not copy arbitrary strings in assessment, version or service fields' {
        $state=New-TestState; $state.DriverVersion='PRIVATE_SENTINEL'; $state.Service='PRIVATE_SENTINEL'
        $safe=ConvertTo-UsbShareSafeReport ([pscustomobject]@{Device=$state;Assessment='PRIVATE_SENTINEL'}) 1
        $safe.Assessment | Should Be 'Unclassified'
        ($safe | ConvertTo-Json -Depth 10) | Should Not Match 'PRIVATE_SENTINEL'
    }
    It 'also redacts discovery entries without a nested Device property' {
        $entry=[pscustomobject]@{InstanceId='PRIVATE_SENTINEL';Name='PRIVATE_SENTINEL';Assessment='NotComposite';ProblemCode=0;DriverVersion='1.2.3.4';Service='PRIVATE_SENTINEL'}
        $safe=ConvertTo-UsbShareSafeReport $entry 3
        $safe.DriverVersion | Should Be '1.2.3.4'
        ($safe | ConvertTo-Json -Depth 10) | Should Not Match 'PRIVATE_SENTINEL'
    }
    It 'resolves relative filesystem paths against PowerShell location' {
        Push-Location $TestDrive
        try { Get-UsbFullPath '.\custom-reports' | Should Be (Join-Path $TestDrive 'custom-reports') }
        finally { Pop-Location }
    }
    It 'refuses non-filesystem paths' {
        { Get-UsbFullPath 'HKLM:\SOFTWARE' } | Should Throw
    }
    It 'returns a generic JSON error from ShareSafe CLI without leaking arguments' {
        $output = (& powershell.exe -NoProfile -File $scriptPath -ShareSafe -InstanceId 'PRIVATE_SENTINEL' 2>&1 | Out-String)
        $LASTEXITCODE | Should Be 1
        $output | Should Not Match 'PRIVATE_SENTINEL'
        ($output | ConvertFrom-Json).Status | Should Be 'InspectFailed'
    }
}

Describe 'Visible progress and efficient discovery' {
    BeforeEach {
        $script:progressSeen=$false
        $script:statuses=@()
        Mock Write-Progress {
            if (-not $Completed) { $script:progressSeen=$true; $script:statuses += $Status }
        }
        Mock Get-PnpDevice {
            if (-not $script:progressSeen) { throw 'Device query started before the first progress update.' }
            [pscustomobject]@{InstanceId='USB\VID_1234&PID_ABCD&MI_07\ABC'}
        }
        Mock Get-UsbDeviceState {
            $state=New-TestState
            $state.InstanceId=$Id
            if ($Id -match '&MI_') { $state.Parent='USB\VID_1234&PID_ABCD\SERIAL' }
            $state
        }
        Mock Get-CompatibleUsbDrivers { @() }
    }
    It 'shows progress before the first slow query and reads each device only once' {
        $result=@(Invoke-UsbNetworkRepair)
        $result.Count | Should Be 2
        Assert-MockCalled Get-UsbDeviceState -Times 1 -Exactly -Scope It -ParameterFilter { $Id -eq 'USB\VID_1234&PID_ABCD&MI_07\ABC' }
        Assert-MockCalled Get-UsbDeviceState -Times 1 -Exactly -Scope It -ParameterFilter { $Id -eq 'USB\VID_1234&PID_ABCD\SERIAL' }
        Assert-MockCalled Write-Progress -Times 1 -Exactly -Scope It -ParameterFilter { $Completed }
    }
    It 'clears progress after a query fails' {
        Mock Get-PnpDevice { throw 'Simulated Windows query error.' }
        { Invoke-UsbNetworkRepair } | Should Throw
        Assert-MockCalled Write-Progress -Times 1 -Exactly -Scope It -ParameterFilter { $Completed }
    }
    It 'handles an empty discovery result without a lingering progress bar' {
        Mock Get-PnpDevice { @() }
        @(Invoke-UsbNetworkRepair).Count | Should Be 0
        Assert-MockCalled Write-Progress -Times 1 -Exactly -Scope It -ParameterFilter { $Completed }
    }
    It 'does not leak device identifiers through share-safe progress messages' {
        $safe=@(Invoke-UsbNetworkRepair -ShareSafe)
        ($script:statuses -join '|') | Should Not Match 'VID_|SERIAL|ABC|test-container'
        ($safe | ConvertTo-Json -Depth 10) | Should Not Match 'VID_|SERIAL|ABC|test-container'
    }
    It 'keeps progress off the success stream' {
        @(Write-UsbOperationProgress 'A generic stage').Count | Should Be 0
    }
    It 'honors NoProgress without changing the caller preference' {
        $before=$ProgressPreference
        $script:preferences=@()
        Mock Write-Progress { $script:preferences += [string]$ProgressPreference }
        Invoke-UsbNetworkRepair -InstanceId 'USB\VID_1234&PID_ABCD\SERIAL' -NoProgress | Out-Null
        @($script:preferences | Where-Object { $_ -ne 'SilentlyContinue' }).Count | Should Be 0
        $script:preferences.Count | Should BeGreaterThan 0
        $ProgressPreference | Should Be $before
    }
    It 'reports observation progress without changing the sample format' {
        $result=Watch-UsbDevice 'USB\VID_1234&PID_ABCD\SERIAL' 0
        @($result.Samples).Count | Should Be 1
        $result.Assessment | Should Be 'UnstableOrError'
        Assert-MockCalled Write-Progress -Times 1 -Exactly -Scope It -ParameterFilter { $Status -like 'Observing device:*' }
    }
}

Describe 'Snapshot validation' {
    BeforeEach {
        Mock Get-UsbMachineId { 'test-machine' }
        $script:current=New-TestState
        $script:recovery=[ordered]@{SchemaVersion=1;MachineId='test-machine';Device=$script:current
            OriginalInfSHA256=('A'*64);BackupInf=$null;BackupFiles=@()}
        $script:recoveryFile=Join-Path $TestDrive 'before.json'
    }
    It 'rejects a snapshot from another machine' {
        $script:recovery.MachineId='another-machine'; Write-UsbJson $script:recoveryFile $script:recovery
        { Read-UsbRecoverySnapshot $script:recoveryFile $script:current } | Should Throw
    }
    It 'rejects a snapshot for another physical device' {
        Write-UsbJson $script:recoveryFile $script:recovery
        $script:current.ContainerId='another-container'
        { Read-UsbRecoverySnapshot $script:recoveryFile $script:current } | Should Throw
    }
    It 'accepts a matching snapshot' {
        Write-UsbJson $script:recoveryFile $script:recovery
        (Read-UsbRecoverySnapshot $script:recoveryFile $script:current).MachineId | Should Be 'test-machine'
    }
    It 'rejects a corrupted backup file' {
        'changed' | Set-Content (Join-Path $TestDrive 'original.inf')
        $script:recovery.BackupFiles=@(@{Path='original.inf';SHA256=('A'*64)})
        Write-UsbJson $script:recoveryFile $script:recovery
        { Read-UsbRecoverySnapshot $script:recoveryFile $script:current } | Should Throw
    }
    It 'refuses directory traversal in backup paths' {
        { Resolve-UsbBackupPath $TestDrive '..\outside.inf' } | Should Throw
    }
    It 'finds an original driver after its published OEM name changes' {
        $inf=Join-Path $TestDrive 'oem987.inf'
        'same driver contents' | Set-Content -LiteralPath $inf
        $saved=[pscustomobject]@{Device=$script:current;OriginalInfSHA256=(Get-FileHash -LiteralPath $inf).Hash}
        $driver=[pscustomobject]@{InfPath=$inf;Version='1.2.3.4';Section='Composite.Dev'}
        @(Find-UsbSavedDriver @($driver) $saved).Count | Should Be 1
    }
}
