# =========================================================
# Aperture Data Collector -- Helper Functions
# =========================================================
# Source of truth: src/helpers.ps1
# Injected into dist/ by build.ps1
# Also dot-sourced when running directly from source
# =========================================================

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
