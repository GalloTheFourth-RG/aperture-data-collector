# =========================================================
# Aperture Data Collector -- Helper Functions
# =========================================================
# Source of truth: src/helpers.ps1
# Injected into dist/ by build.ps1
# Also dot-sourced when running directly from source
# =========================================================

# -- Permission Registry --
# Central mapping of every check to its required ARM actions and remediation.
# Used by DryRun probes AND runtime graceful degradation for consistent messaging.
$script:PermissionRegistry = @{
    HostPools = @{
        Actions     = @("Microsoft.DesktopVirtualization/hostpools/read")
        Description = "Read AVD host pools"
        Remediation = "az role assignment create --assignee `"<user>`" --role `"Desktop Virtualization Reader`" --scope `"/subscriptions/<sub-id>`""
    }
    VMs = @{
        Actions     = @("Microsoft.Compute/virtualMachines/read", "Microsoft.Compute/virtualMachines/instanceView/read")
        Description = "Read VM inventory and power state"
        Remediation = "az role assignment create --assignee `"<user>`" --role `"Reader`" --scope `"/subscriptions/<sub-id>`""
    }
    Metrics = @{
        Actions     = @("Microsoft.Insights/metrics/read")
        Description = "Read Azure Monitor metrics"
        Remediation = "az role assignment create --assignee `"<user>`" --role `"Monitoring Reader`" --scope `"/subscriptions/<sub-id>`""
    }
    LogAnalytics = @{
        Actions     = @("Microsoft.OperationalInsights/workspaces/read", "Microsoft.OperationalInsights/workspaces/query/*/read")
        Description = "Query Log Analytics workspaces"
        Remediation = "az role assignment create --assignee `"<user>`" --role `"Log Analytics Reader`" --scope `"<workspace-resource-id>`""
    }
    CostManagement = @{
        Actions     = @("Microsoft.CostManagement/query/action")
        Description = "Query Azure Cost Management"
        Remediation = "az role assignment create --assignee `"<user>`" --role `"Cost Management Reader`" --scope `"/subscriptions/<sub-id>`""
    }
    NetworkTopology = @{
        Actions     = @("Microsoft.Network/virtualNetworks/read", "Microsoft.Network/networkSecurityGroups/read", "Microsoft.Network/privateEndpoints/read")
        Description = "Read VNet, NSG, and private endpoint configuration"
        Remediation = "az role assignment create --assignee `"<user>`" --role `"Reader`" --scope `"/subscriptions/<sub-id>`""
    }
    StorageAnalysis = @{
        Actions     = @("Microsoft.Storage/storageAccounts/read", "Microsoft.Storage/storageAccounts/fileServices/shares/read")
        Description = "Read storage accounts and file shares"
        Remediation = "az role assignment create --assignee `"<user>`" --role `"Reader`" --scope `"/subscriptions/<sub-id>`""
    }
    OrphanedResources = @{
        Actions     = @("Microsoft.Compute/disks/read", "Microsoft.Network/networkInterfaces/read", "Microsoft.Network/publicIPAddresses/read")
        Description = "Scan for unattached disks, NICs, and public IPs"
        Remediation = "az role assignment create --assignee `"<user>`" --role `"Reader`" --scope `"/subscriptions/<sub-id>`""
    }
    DiagnosticSettings = @{
        Actions     = @("Microsoft.Insights/diagnosticSettings/read")
        Description = "Read diagnostic settings on host pools"
        Remediation = "az role assignment create --assignee `"<user>`" --role `"Monitoring Reader`" --scope `"/subscriptions/<sub-id>`""
    }
    AlertRules = @{
        Actions     = @("Microsoft.Insights/metricAlerts/read", "Microsoft.Insights/scheduledQueryRules/read", "Microsoft.Insights/activityLogAlerts/read", "Microsoft.AlertsManagement/alerts/read")
        Description = "Read alert rules and fired alert history"
        Remediation = "az role assignment create --assignee `"<user>`" --role `"Monitoring Reader`" --scope `"/subscriptions/<sub-id>`""
    }
    ActivityLog = @{
        Actions     = @("Microsoft.Insights/eventtypes/values/read")
        Description = "Read Activity Log entries"
        Remediation = "az role assignment create --assignee `"<user>`" --role `"Monitoring Reader`" --scope `"/subscriptions/<sub-id>`""
    }
    PolicyAssignments = @{
        Actions     = @("Microsoft.Authorization/policyAssignments/read")
        Description = "Read Azure Policy assignments"
        Remediation = "az role assignment create --assignee `"<user>`" --role `"Resource Policy Reader`" --scope `"/subscriptions/<sub-id>`""
    }
    ImageAnalysis = @{
        Actions     = @("Microsoft.Compute/galleries/images/versions/read", "Microsoft.Compute/locations/publishers/artifacttypes/offers/skus/versions/read")
        Description = "Read gallery and marketplace image data"
        Remediation = "az role assignment create --assignee `"<user>`" --role `"Reader`" --scope `"/subscriptions/<sub-id>`""
    }
    QuotaUsage = @{
        Actions     = @("Microsoft.Compute/locations/usages/read")
        Description = "Read vCPU quota usage per region"
        Remediation = "az role assignment create --assignee `"<user>`" --role `"Reader`" --scope `"/subscriptions/<sub-id>`""
    }
    CapacityReservations = @{
        Actions     = @("Microsoft.Compute/capacityReservationGroups/read", "Microsoft.Compute/capacityReservationGroups/capacityReservations/read")
        Description = "Read capacity reservation groups"
        Remediation = "az role assignment create --assignee `"<user>`" --role `"Reader`" --scope `"/subscriptions/<sub-id>`""
    }
    ReservedInstances = @{
        Actions     = @("Microsoft.Capacity/reservationorders/read", "Microsoft.Capacity/reservationorders/reservations/read")
        Description = "Read Azure Reserved Instances"
        Remediation = "az role assignment create --assignee `"<user>`" --role `"Reservations Reader`" --scope `"/`""
    }
    IntuneDevices = @{
        Actions     = @("DeviceManagementManagedDevices.Read.All")
        Description = "Read Intune managed devices (Microsoft Graph)"
        Remediation = "Assign Global Reader or Intune Administrator in Entra admin center"
    }
    ConditionalAccess = @{
        Actions     = @("Policy.Read.All")
        Description = "Read Conditional Access policies (Microsoft Graph)"
        Remediation = "Assign Global Reader in Entra admin center"
    }
}

# -- Permission Probe Helper --
# Wraps a scriptblock probe in try/catch and returns a structured result.
# Used by the DryRun section for consistent error classification.
function Test-ProbeAccess {
    param(
        [string]$Check,
        [string]$RegistryKey,
        [scriptblock]$Probe
    )
    $reg = $script:PermissionRegistry[$RegistryKey]
    $actions = if ($reg) { ($reg.Actions -join ", ") } else { "Unknown" }
    $remediation = if ($reg) { $reg.Remediation } else { "" }
    try {
        $detail = & $Probe
        if (-not $detail) { $detail = "Access confirmed" }
        return [PSCustomObject]@{ Check = $Check; Status = "OK"; Detail = $detail; Actions = $actions; Remediation = $remediation }
    }
    catch {
        $errMsg = $_.Exception.Message
        if (Test-IsPermissionError $errMsg) {
            return [PSCustomObject]@{ Check = $Check; Status = "FAIL"; Detail = "Access denied"; Actions = $actions; Remediation = $remediation }
        } elseif ($errMsg -match '404|NotFound|ResourceNotFound') {
            return [PSCustomObject]@{ Check = $Check; Status = "FAIL"; Detail = "Resource not found -- check resource ID"; Actions = $actions; Remediation = $remediation }
        } else {
            return [PSCustomObject]@{ Check = $Check; Status = "WARN"; Detail = $errMsg; Actions = $actions; Remediation = $remediation }
        }
    }
}

# -- Permission Error Classifier --
# Returns $true if an exception message indicates an authorization/permission failure.
function Test-IsPermissionError {
    param([string]$Message)
    if ([string]::IsNullOrEmpty($Message)) { return $false }
    return ($Message -match '403|Forbidden|AuthorizationFailed|AuthorizationPermissionMismatch|InsufficientAccountPermissions')
}

# -- Runtime Permission Failure Tracker --
# Call Add-PermissionFailure during collection to record sections skipped due to
# permission errors. The list is exported as permission-failures.json in the pack.
function Add-PermissionFailure {
    param(
        [string]$Section,
        [string]$RegistryKey,
        [string]$ErrorMessage
    )
    if ($null -eq $script:permissionFailures) { return }
    $reg = $script:PermissionRegistry[$RegistryKey]
    $actions = if ($reg) { ($reg.Actions -join ", ") } else { "Unknown" }
    $remediation = if ($reg) { $reg.Remediation } else { "" }
    $script:permissionFailures.Add([PSCustomObject]@{
        Section      = $Section
        Actions      = $actions
        Remediation  = $remediation
        ErrorMessage = $ErrorMessage
        Timestamp    = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
    })
    Write-Step -Step $Section -Message "Skipped -- permission denied (requires: $actions)" -Status "Warn"
}

# -- Memory Monitoring --
function Get-MemoryMB {
    try {
        $proc = [System.Diagnostics.Process]::GetCurrentProcess()
        [math]::Round($proc.WorkingSet64 / 1MB)
    } catch { 0 }
}

function Write-MemoryUsage {
    param([string]$Label)
    $mb = Get-MemoryMB
    Write-Host "    [MEM] $Label -- Working set: ${mb} MB" -ForegroundColor DarkGray
}

# -- Console Output --
function Write-Step {
    param([string]$Step, [string]$Message, [string]$Status = "Start")
    $prefix = switch ($Status) {
        "Start"    { "  " }
        "Progress" { "    " }
        "Done"     { "  [OK] " }
        "Skip"     { "  [SKIP] " }
        "Warn"     { "  [WARN] " }
        "Error"    { "  [ERR] " }
    }
    $color = switch ($Status) {
        "Start"    { "Cyan" }
        "Progress" { "Gray" }
        "Done"     { "Green" }
        "Skip"     { "Yellow" }
        "Warn"     { "Yellow" }
        "Error"    { "Red" }
    }
    if ($Status -eq "Progress") {
        Write-Host "${prefix}${Message}" -ForegroundColor $color
    } else {
        Write-Host "${prefix}${Step} - ${Message}" -ForegroundColor $color
    }
    # Log to structured diagnostic events
    if ($Status -in @("Warn", "Error", "Skip")) {
        Write-DiagEvent -Severity $Status -Step $Step -Message $Message
    }
}

# -- Structured Diagnostic Log --
function Write-DiagEvent {
    param(
        [string]$Severity,
        [string]$Step,
        [string]$Message,
        [string]$ErrorDetail
    )
    if ($null -eq $script:diagnosticLog) { return }
    $script:diagnosticLog.Add([PSCustomObject]@{
        Timestamp   = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
        Severity    = $Severity
        Step        = $Step
        Message     = $Message
        ErrorDetail = $ErrorDetail
    })
}

# -- Safe Access Helpers --
function SafeCount {
    param([object]$Obj)
    if ($null -eq $Obj) { return 0 }
    if ($Obj -is [System.Collections.ICollection]) { return $Obj.Count }
    return @($Obj).Count
}

function SafeArray {
    param([object]$Obj)
    if ($null -eq $Obj) { return ,@() }
    return ,@($Obj)
}

function SafeProp {
    param([object]$Obj, [string]$Name)
    if ($null -eq $Obj) { return $null }
    if ($Obj.PSObject.Properties.Name -contains $Name) { return $Obj.$Name }
    return $null
}

function SafeArmProp {
    param([object]$Obj, [string]$Name)
    if ($null -eq $Obj) { return $null }
    # Direct property
    if ($Obj.PSObject.Properties.Name -contains $Name) { return $Obj.$Name }
    # Case-insensitive direct check (some module versions return camelCase e.g. hostPoolType)
    $match = $Obj.PSObject.Properties | Where-Object { $_.Name -ieq $Name } | Select-Object -First 1
    if ($match) { return $match.Value }
    # .Properties nesting
    if ($Obj.PSObject.Properties.Name -contains 'Properties') {
        $p = $Obj.Properties
        if ($null -ne $p -and $p.PSObject.Properties.Name -contains $Name) { return $p.$Name }
        if ($null -ne $p) {
            $pm = $p.PSObject.Properties | Where-Object { $_.Name -ieq $Name } | Select-Object -First 1
            if ($pm) { return $pm.Value }
        }
        # Double-nested: .Properties.properties (REST API envelope)
        if ($null -ne $p -and $p.PSObject.Properties.Name -contains 'properties') {
            $pp = $p.properties
            if ($null -ne $pp) {
                $ppm = $pp.PSObject.Properties | Where-Object { $_.Name -ieq $Name } | Select-Object -First 1
                if ($ppm) { return $ppm.Value }
            }
        }
    }
    # .ResourceProperties nesting
    if ($Obj.PSObject.Properties.Name -contains 'ResourceProperties') {
        $rp = $Obj.ResourceProperties
        if ($null -ne $rp -and $rp.PSObject.Properties.Name -contains $Name) { return $rp.$Name }
        if ($null -ne $rp) {
            $rpm = $rp.PSObject.Properties | Where-Object { $_.Name -ieq $Name } | Select-Object -First 1
            if ($rpm) { return $rpm.Value }
        }
    }
    return $null
}

# -- ARM ID Helpers --
function Get-ArmIdSafe {
    param([object]$Obj)
    if ($null -eq $Obj) { return "" }
    if ($Obj.PSObject.Properties.Name -contains 'Id') { return $Obj.Id }
    if ($Obj.PSObject.Properties.Name -contains 'ResourceId') { return $Obj.ResourceId }
    return ""
}

function Get-NameFromArmId {
    param([string]$ArmId)
    if ([string]::IsNullOrEmpty($ArmId)) { return "" }
    $parts = $ArmId -split '/'
    if ($parts.Count -ge 1) { return $parts[-1] }
    return ""
}

function Get-SubFromArmId {
    param([string]$ArmId)
    if ([string]::IsNullOrEmpty($ArmId)) { return "" }
    $parts = $ArmId -split '/'
    if ($parts.Count -ge 3) { return $parts[2] }
    return ""
}

# -- Retry Helper --
function Invoke-WithRetry {
    param(
        [Parameter(Mandatory)] [scriptblock]$ScriptBlock,
        [int]$MaxAttempts = 4
    )
    $attempt = 0
    while ($true) {
        try {
            return & $ScriptBlock
        }
        catch {
            $msg = $_.Exception.Message
            if ($msg -match '429|throttl|503' -and $attempt -lt $MaxAttempts) {
                $attempt++
                $delay = [math]::Pow(2, $attempt) * 5
                Write-Host "    Throttled or transient error, retrying in $delay seconds (attempt $attempt)" -ForegroundColor Yellow
                Start-Sleep -Seconds $delay
                continue
            }
            throw
        }
    }
}

# -- PII Scrubbing --
function Protect-Value {
    param([string]$Value, [string]$Prefix = "Anon", [int]$Length = 4)
    if (-not $ScrubPII) { return $Value }
    if ([string]::IsNullOrEmpty($Value)) { return $Value }
    $key = "${Prefix}:${Value}"
    if ($script:piiCache.ContainsKey($key)) { return $script:piiCache[$key] }
    $hash = [System.Security.Cryptography.SHA256]::Create().ComputeHash(
        [System.Text.Encoding]::UTF8.GetBytes("${Value}:${script:piiSalt}")
    )
    $short = [BitConverter]::ToString($hash[0..($Length/2)]).Replace('-','').Substring(0, $Length).ToUpper()
    $result = "${Prefix}-${short}"
    $script:piiCache[$key] = $result
    return $result
}

function Protect-SubscriptionId {
    param([string]$Value)
    if (-not $ScrubPII) { return $Value }
    if ([string]::IsNullOrEmpty($Value)) { return $Value }
    if ($Value.Length -ge 4) { return "****-****-****-" + $Value.Substring($Value.Length - 4) }
    return "****"
}

function Protect-TenantId {
    param([string]$Value)
    if (-not $ScrubPII) { return $Value }
    if ([string]::IsNullOrEmpty($Value)) { return $Value }
    if ($Value.Length -ge 4) { return "****-****-****-" + $Value.Substring($Value.Length - 4) }
    return "****"
}

function Protect-Email {
    param([string]$Value)
    if (-not $ScrubPII) { return $Value }
    if ([string]::IsNullOrEmpty($Value)) { return $Value }
    if ($Value -match '^(.{2}).*(@.*)$') { return "$($matches[1])****$($matches[2])" }
    return (Protect-Value -Value $Value -Prefix "Email" -Length 4)
}

function Protect-VMName       { param([string]$Value); return (Protect-Value -Value $Value -Prefix "Host" -Length 6) }
function Protect-HostPoolName { param([string]$Value); return (Protect-Value -Value $Value -Prefix "Pool" -Length 4) }
function Protect-ResourceGroup { param([string]$Value); return (Protect-Value -Value $Value -Prefix "RG" -Length 4) }
function Protect-Username     { param([string]$Value); return (Protect-Value -Value $Value -Prefix "User" -Length 4) }

function Protect-IP {
    param([string]$Value)
    if (-not $ScrubPII) { return $Value }
    if ([string]::IsNullOrEmpty($Value)) { return $Value }
    if ($Value -match '^(\d+\.\d+\.\d+)\.\d+$') { return "$($matches[1]).x" }
    return "x.x.x.x"
}

function Protect-ArmId {
    param([string]$Value)
    if (-not $ScrubPII) { return $Value }
    if ([string]::IsNullOrEmpty($Value)) { return $Value }
    return (Protect-Value -Value $Value -Prefix "ArmId" -Length 8)
}

function Protect-StorageAccountName {
    param([string]$Value)
    return (Protect-Value -Value $Value -Prefix "SA" -Length 4)
}

function Protect-SubnetName {
    param([string]$Value)
    return (Protect-Value -Value $Value -Prefix "Subnet" -Length 4)
}

function Protect-SubnetId {
    param([string]$Value)
    if (-not $ScrubPII) { return $Value }
    if ([string]::IsNullOrEmpty($Value)) { return $Value }
    return (Protect-Value -Value $Value -Prefix "Subnet" -Length 6)
}

function Protect-KqlRow {
    param([PSCustomObject]$Row)
    if (-not $ScrubPII) { return $Row }
    foreach ($p in @($Row.PSObject.Properties)) {
        if ($null -eq $p.Value -or $p.Value -eq '') { continue }
        $val = [string]$p.Value
        switch -Regex ($p.Name) {
            '^(UserName|UserPrincipalName|UserId|User|UserDisplayName|ActiveDirectoryUserName)$' {
                $Row.$($p.Name) = Protect-Username $val; break
            }
            '^(SessionHostName|Computer|ComputerName|HostName|HostNameShort)$' {
                # Normalize to short hostname before hashing so KQL FQDNs (vm-001.contoso.com)
                # produce the same hash as session host short names (vm-001)
                $shortVal = ($val -split "\.")[0]
                $Row.$($p.Name) = Protect-VMName $shortVal; break
            }
            '^(_ResourceId|ResourceId)$' {
                $Row.$($p.Name) = Protect-ArmId $val; break
            }
            '^(ClientIP|ClientPublicIP|SourceIP|PrivateIP)$' {
                $Row.$($p.Name) = Protect-IP $val; break
            }
            '^(SubscriptionId|subscriptionId)$' {
                $Row.$($p.Name) = Protect-SubscriptionId $val; break
            }
            '^(HostPool|HostPoolName|PoolName)$' {
                $Row.$($p.Name) = Protect-HostPoolName $val; break
            }
            '^(ResourceGroup|ResourceGroupName)$' {
                $Row.$($p.Name) = Protect-ResourceGroup $val; break
            }
            '^(Hosts)$' {
                # Array of VM names (e.g. make_set(SessionHostName)) -- scrub entirely
                $Row.$($p.Name) = '[SCRUBBED]'; break
            }
            '^(Message|ErrorMsg|Error|ErrorMessage|SampleError|SampleErrors|SampleMessages|UpgradeErrorMsg|SampleSuccessMsg|SessionHostHealthCheckResult)$' {
                # Freeform text fields may contain VM names, UPNs, IPs, resource IDs
                $Row.$($p.Name) = '[SCRUBBED]'; break
            }
            '^(WorkspaceResourceId)$' {
                $Row.$($p.Name) = Protect-ArmId $val; break
            }
        }
    }
    return $Row
}
