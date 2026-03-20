# Pester tests for src/helpers.ps1
# Run: Invoke-Pester ./tests/Helpers.Tests.ps1
# Requires Pester v5+

BeforeAll {
    # Dot-source the helpers under test
    $root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
    if (-not $root) { $root = (Get-Location).Path }
    $helpersFile = Join-Path (Split-Path $root -Parent) 'src' 'helpers.ps1'
    . $helpersFile

    # Initialize PII runtime state (required by Protect-* functions)
    # Must be global because Protect-* functions reference bare $ScrubPII
    # (in the real script it's a parameter, visible everywhere)
    $script:piiSalt = 'test-salt-12345'
    $script:piiCache = @{}
    $global:ScrubPII = $false
}

AfterAll {
    # Clean up global variable
    Remove-Variable -Name ScrubPII -Scope Global -ErrorAction SilentlyContinue
}

Describe 'SafeCount' {
    It 'Returns 0 for $null' {
        SafeCount $null | Should -Be 0
    }
    It 'Returns 0 for empty array' {
        SafeCount @() | Should -Be 0
    }
    It 'Returns count for array with items' {
        SafeCount @(1, 2, 3) | Should -Be 3
    }
    It 'Returns 1 for scalar' {
        SafeCount 'hello' | Should -Be 1
    }
    It 'Returns count for Generic.List' {
        $list = [System.Collections.Generic.List[object]]::new()
        $list.Add('a')
        $list.Add('b')
        SafeCount $list | Should -Be 2
    }
    It 'Returns 0 for empty Generic.List' {
        $list = [System.Collections.Generic.List[object]]::new()
        SafeCount $list | Should -Be 0
    }
}

Describe 'SafeArray' {
    It 'Returns empty array for $null' {
        $result = SafeArray $null
        $result.GetType().Name | Should -Be 'Object[]'
        $result.Count | Should -Be 0
    }
    It 'Returns array for empty array input' {
        $result = SafeArray @()
        $result.GetType().Name | Should -Be 'Object[]'
        $result.Count | Should -Be 0
    }
    It 'Wraps scalar in array' {
        $result = SafeArray 'single'
        $result.GetType().Name | Should -Be 'Object[]'
        $result.Count | Should -Be 1
        $result[0] | Should -Be 'single'
    }
    It 'Preserves array with multiple items' {
        $result = SafeArray @('a', 'b', 'c')
        $result.Count | Should -Be 3
    }
    It 'Result .Count works in strict mode' {
        Set-StrictMode -Version Latest
        $result = SafeArray $null
        $result.Count | Should -Be 0
        Set-StrictMode -Off
    }
    It 'Handles Generic.List' {
        $list = [System.Collections.Generic.List[object]]::new()
        $list.Add('x')
        $result = SafeArray $list
        $result.GetType().Name | Should -Be 'Object[]'
        $result.Count | Should -Be 1
    }
}

Describe 'SafeProp' {
    It 'Returns $null for $null object' {
        SafeProp $null 'Name' | Should -BeNullOrEmpty
    }
    It 'Returns property value when it exists' {
        $obj = [PSCustomObject]@{ Name = 'test'; Value = 42 }
        SafeProp $obj 'Name' | Should -Be 'test'
        SafeProp $obj 'Value' | Should -Be 42
    }
    It 'Returns $null for missing property' {
        $obj = [PSCustomObject]@{ Name = 'test' }
        SafeProp $obj 'MissingProp' | Should -BeNullOrEmpty
    }
    It 'Is case-insensitive (PowerShell -contains behavior)' {
        # PowerShell -contains is case-insensitive, so SafeProp finds properties regardless of casing
        $obj = [PSCustomObject]@{ Name = 'test' }
        SafeProp $obj 'name' | Should -Be 'test'
    }
}

Describe 'SafeArmProp' {
    It 'Returns $null for $null object' {
        SafeArmProp $null 'Name' | Should -BeNullOrEmpty
    }
    It 'Returns direct property' {
        $obj = [PSCustomObject]@{ HostPoolType = 'Pooled' }
        SafeArmProp $obj 'HostPoolType' | Should -Be 'Pooled'
    }
    It 'Handles case-insensitive match (camelCase)' {
        $obj = [PSCustomObject]@{ hostPoolType = 'Personal' }
        SafeArmProp $obj 'HostPoolType' | Should -Be 'Personal'
    }
    It 'Returns nested .Properties value' {
        $obj = [PSCustomObject]@{
            Properties = [PSCustomObject]@{
                MaxSessionLimit = 10
            }
        }
        SafeArmProp $obj 'MaxSessionLimit' | Should -Be 10
    }
    It 'Returns double-nested .Properties.properties value' {
        $obj = [PSCustomObject]@{
            Properties = [PSCustomObject]@{
                properties = [PSCustomObject]@{
                    StartVMOnConnect = $true
                }
            }
        }
        SafeArmProp $obj 'StartVMOnConnect' | Should -Be $true
    }
    It 'Returns .ResourceProperties value' {
        $obj = [PSCustomObject]@{
            ResourceProperties = [PSCustomObject]@{
                CustomRdpProperty = 'audiocapturemode:i:1'
            }
        }
        SafeArmProp $obj 'CustomRdpProperty' | Should -Be 'audiocapturemode:i:1'
    }
    It 'Returns $null for missing property in all layers' {
        $obj = [PSCustomObject]@{ Name = 'pool1' }
        SafeArmProp $obj 'NonExistent' | Should -BeNullOrEmpty
    }
    It 'Prefers direct property over nested' {
        $obj = [PSCustomObject]@{
            Name = 'direct'
            Properties = [PSCustomObject]@{ Name = 'nested' }
        }
        SafeArmProp $obj 'Name' | Should -Be 'direct'
    }
}

Describe 'Get-ArmIdSafe' {
    It 'Returns empty string for $null' {
        Get-ArmIdSafe $null | Should -Be ''
    }
    It 'Returns Id property' {
        $obj = [PSCustomObject]@{ Id = '/subscriptions/sub1/resourceGroups/rg1/providers/Microsoft.DesktopVirtualization/hostpools/pool1' }
        Get-ArmIdSafe $obj | Should -BeLike '/subscriptions/*'
    }
    It 'Falls back to ResourceId' {
        $obj = [PSCustomObject]@{ ResourceId = '/subscriptions/sub1/resourceGroups/rg1/providers/X/y/z' }
        Get-ArmIdSafe $obj | Should -BeLike '/subscriptions/*'
    }
    It 'Returns empty string when neither Id nor ResourceId' {
        $obj = [PSCustomObject]@{ Name = 'noId' }
        Get-ArmIdSafe $obj | Should -Be ''
    }
}

Describe 'Get-NameFromArmId' {
    It 'Returns empty string for null/empty' {
        Get-NameFromArmId $null | Should -Be ''
        Get-NameFromArmId '' | Should -Be ''
    }
    It 'Extracts name from ARM resource ID' {
        Get-NameFromArmId '/subscriptions/sub1/resourceGroups/rg1/providers/Microsoft.DesktopVirtualization/hostpools/myPool' | Should -Be 'myPool'
    }
}

Describe 'Get-SubFromArmId' {
    It 'Returns empty string for null/empty' {
        Get-SubFromArmId $null | Should -Be ''
        Get-SubFromArmId '' | Should -Be ''
    }
    It 'Extracts subscription from ARM resource ID' {
        Get-SubFromArmId '/subscriptions/abc-123/resourceGroups/rg1/providers/X/y/z' | Should -Be 'abc-123'
    }
}

Describe 'ARM ID RG extraction pattern' {
    # This tests the pattern used in the main script: ($hpId -split '/')[4]
    It 'Splits standard ARM ID correctly' {
        $armId = '/subscriptions/sub-guid/resourceGroups/my-rg/providers/Microsoft.DesktopVirtualization/hostpools/myPool'
        $parts = $armId -split '/'
        $parts[0] | Should -Be ''          # empty before first /
        $parts[1] | Should -Be 'subscriptions'
        $parts[2] | Should -Be 'sub-guid'
        $parts[3] | Should -Be 'resourceGroups'
        $parts[4] | Should -Be 'my-rg'
    }
    It 'Returns empty for non-ARM strings' {
        $parts = 'not-an-arm-id' -split '/'
        $parts[4] | Should -BeNullOrEmpty
    }
}

Describe 'Protect-* functions (PII off)' {
    It 'Returns original value when ScrubPII is $false' {
        $global:ScrubPII = $false
        Protect-VMName 'vm-prod-01' | Should -Be 'vm-prod-01'
        Protect-HostPoolName 'pool-prod' | Should -Be 'pool-prod'
        Protect-Username 'user@domain.com' | Should -Be 'user@domain.com'
        Protect-ResourceGroup 'rg-avd-prod' | Should -Be 'rg-avd-prod'
        Protect-IP '10.0.1.5' | Should -Be '10.0.1.5'
        Protect-ArmId '/subscriptions/xxx' | Should -Be '/subscriptions/xxx'
        Protect-SubscriptionId 'abc-def-ghi-jkl' | Should -Be 'abc-def-ghi-jkl'
    }
}

Describe 'Protect-* functions (PII on)' {
    It 'Scrubs VM names' {
        $global:ScrubPII = $true
        $script:piiCache = @{}
        $result = Protect-VMName 'vm-prod-01'
        $result | Should -BeLike 'Host-*'
        $result | Should -Not -Be 'vm-prod-01'
    }
    It 'Scrubs host pool names' {
        $global:ScrubPII = $true
        $script:piiCache = @{}
        $result = Protect-HostPoolName 'pool-prod'
        $result | Should -BeLike 'Pool-*'
    }
    It 'Scrubs usernames' {
        $global:ScrubPII = $true
        $script:piiCache = @{}
        $result = Protect-Username 'user@domain.com'
        $result | Should -BeLike 'User-*'
    }
    It 'Scrubs resource groups' {
        $global:ScrubPII = $true
        $script:piiCache = @{}
        $result = Protect-ResourceGroup 'rg-avd-prod'
        $result | Should -BeLike 'RG-*'
    }
    It 'Scrubs IPs to /24 mask' {
        $global:ScrubPII = $true
        Protect-IP '10.0.1.5' | Should -Be '10.0.1.x'
    }
    It 'Scrubs subscription IDs' {
        $global:ScrubPII = $true
        Protect-SubscriptionId 'abc-def-ghi-jkl' | Should -BeLike '****-****-****-*'
    }
    It 'Returns empty/null values unchanged' {
        $global:ScrubPII = $true
        Protect-VMName '' | Should -Be ''
        Protect-VMName $null | Should -BeNullOrEmpty
    }
    It 'Same input produces same hash (deterministic)' {
        $global:ScrubPII = $true
        $script:piiCache = @{}
        $a = Protect-VMName 'vm-test'
        $b = Protect-VMName 'vm-test'
        $a | Should -Be $b
    }
    It 'Different inputs produce different hashes' {
        $global:ScrubPII = $true
        $script:piiCache = @{}
        $a = Protect-VMName 'vm-one'
        $b = Protect-VMName 'vm-two'
        $a | Should -Not -Be $b
    }
}

Describe 'Protect-KqlRow' {
    It 'Returns row unchanged when ScrubPII is $false' {
        $global:ScrubPII = $false
        $row = [PSCustomObject]@{ UserName = 'alice'; SessionHostName = 'vm-01'; SomeValue = 42 }
        $result = Protect-KqlRow $row
        $result.UserName | Should -Be 'alice'
        $result.SessionHostName | Should -Be 'vm-01'
    }
    It 'Scrubs known PII fields when ScrubPII is $true' {
        $global:ScrubPII = $true
        $script:piiCache = @{}
        $row = [PSCustomObject]@{
            UserName = 'alice@contoso.com'
            SessionHostName = 'vm-prod-01'
            ClientIP = '192.168.1.100'
            HostPoolName = 'pool-prod'
            SomeMetric = 42
        }
        $result = Protect-KqlRow $row
        $result.UserName | Should -BeLike 'User-*'
        $result.SessionHostName | Should -BeLike 'Host-*'
        $result.ClientIP | Should -Be '192.168.1.x'
        $result.HostPoolName | Should -BeLike 'Pool-*'
        $result.SomeMetric | Should -Be 42  # Non-PII field untouched
        $global:ScrubPII = $false
    }
    It 'Normalizes FQDN to short name before hashing SessionHostName' {
        $global:ScrubPII = $true
        $script:piiCache = @{}
        # Short name and FQDN of same host must produce identical hash
        $shortRow = [PSCustomObject]@{ SessionHostName = 'vm-prod-01' }
        $fqdnRow  = [PSCustomObject]@{ SessionHostName = 'vm-prod-01.contoso.com' }
        Protect-KqlRow $shortRow | Out-Null
        Protect-KqlRow $fqdnRow  | Out-Null
        $shortRow.SessionHostName | Should -Be $fqdnRow.SessionHostName
        $global:ScrubPII = $false
    }
    It 'Handles sparse rows with missing properties' {
        $global:ScrubPII = $true
        $script:piiCache = @{}
        $row = [PSCustomObject]@{ QueryName = 'test'; Count = 5 }
        # Should not throw
        $result = Protect-KqlRow $row
        $result.QueryName | Should -Be 'test'
        $result.Count | Should -Be 5
        $global:ScrubPII = $false
    }
    It 'Scrubs error messages completely' {
        $global:ScrubPII = $true
        $script:piiCache = @{}
        $row = [PSCustomObject]@{ ErrorMessage = 'Connection from vm-01 failed for user@contoso.com' }
        $result = Protect-KqlRow $row
        $result.ErrorMessage | Should -Be '[SCRUBBED]'
        $global:ScrubPII = $false
    }
}

Describe 'Write-Step' {
    It 'Does not throw for any valid status' {
        { Write-Step -Step 'Test' -Message 'msg' -Status 'Start' } | Should -Not -Throw
        { Write-Step -Step 'Test' -Message 'msg' -Status 'Progress' } | Should -Not -Throw
        { Write-Step -Step 'Test' -Message 'msg' -Status 'Done' } | Should -Not -Throw
        { Write-Step -Step 'Test' -Message 'msg' -Status 'Warn' } | Should -Not -Throw
        { Write-Step -Step 'Test' -Message 'msg' -Status 'Error' } | Should -Not -Throw
        { Write-Step -Step 'Test' -Message 'msg' -Status 'Skip' } | Should -Not -Throw
    }
}

Describe 'Invoke-WithRetry' {
    It 'Returns result on first success' {
        $result = Invoke-WithRetry { 'success' }
        $result | Should -Be 'success'
    }
    It 'Throws non-retryable errors immediately' {
        { Invoke-WithRetry { throw 'permanent error' } } | Should -Throw '*permanent error*'
    }
}

# =============================================================
# REST Layer 0 — Host Pool RG Extraction Pattern Tests
# =============================================================
# These test the logic patterns used in the main script for
# building $hpRestLookup and the 4-layer fallback cascade.

Describe 'REST API response parsing pattern' {
    # Simulates the JSON structure returned by Invoke-AzRestMethod
    # GET /subscriptions/{subId}/providers/Microsoft.DesktopVirtualization/hostPools
    It 'Builds lookup from standard ARM REST response' {
        $json = @{
            value = @(
                @{ id = '/subscriptions/sub-1/resourceGroups/rg-avd/providers/Microsoft.DesktopVirtualization/hostPools/pool-1'; name = 'pool-1' }
                @{ id = '/subscriptions/sub-1/resourceGroups/rg-avd/providers/Microsoft.DesktopVirtualization/hostPools/pool-2'; name = 'pool-2' }
            )
        }
        $hpRestLookup = @{}
        $items = if ($json.value) { @($json.value) } else { @() }
        foreach ($hpRest in $items) {
            $restId = $hpRest.id
            $restName = $hpRest.name
            if ($restId -and $restName) {
                $restParts = $restId -split '/'
                $restRg = if ($restParts.Count -ge 5) { $restParts[4] } else { $null }
                $hpRestLookup[$restName] = @{ Id = $restId; ResourceGroup = $restRg }
            }
        }
        $hpRestLookup.Count | Should -Be 2
        $hpRestLookup['pool-1'].ResourceGroup | Should -Be 'rg-avd'
        $hpRestLookup['pool-2'].Id | Should -BeLike '*/pool-2'
    }

    It 'Handles empty value array' {
        $json = @{ value = @() }
        $items = if ($json.value) { @($json.value) } else { @() }
        $items.Count | Should -Be 0
    }

    It 'Handles null value property' {
        $json = @{ value = $null }
        $items = if ($json.value) { @($json.value) } else { @() }
        $items.Count | Should -Be 0
    }

    It 'Skips entries with missing id or name' {
        $json = @{
            value = @(
                @{ id = '/subscriptions/sub-1/resourceGroups/rg/providers/X/hostPools/pool-ok'; name = 'pool-ok' }
                @{ id = $null; name = 'pool-no-id' }
                @{ id = '/subscriptions/sub-1/resourceGroups/rg/providers/X/hostPools/pool-no-name'; name = $null }
            )
        }
        $hpRestLookup = @{}
        foreach ($hpRest in @($json.value)) {
            $restId = $hpRest.id
            $restName = $hpRest.name
            if ($restId -and $restName) {
                $restParts = $restId -split '/'
                $restRg = if ($restParts.Count -ge 5) { $restParts[4] } else { $null }
                $hpRestLookup[$restName] = @{ Id = $restId; ResourceGroup = $restRg }
            }
        }
        $hpRestLookup.Count | Should -Be 1
        $hpRestLookup.ContainsKey('pool-ok') | Should -BeTrue
    }

    It 'Extracts RG from various ARM ID formats' {
        $ids = @(
            @{ Id = '/subscriptions/abc/resourceGroups/rg-UPPER/providers/X/y/z'; Expected = 'rg-UPPER' }
            @{ Id = '/subscriptions/abc/resourceGroups/rg-with-dashes-123/providers/X/y/z'; Expected = 'rg-with-dashes-123' }
            @{ Id = '/subscriptions/abc/resourceGroups/RG_underscore/providers/X/y/z'; Expected = 'RG_underscore' }
        )
        foreach ($case in $ids) {
            $parts = $case.Id -split '/'
            $parts[4] | Should -Be $case.Expected
        }
    }
}

Describe 'Host pool RG extraction — 4-layer cascade' {
    # Simulates the cascade logic in the main script:
    # Layer 0: REST lookup
    # Layer 1: Cmdlet Id -> parse RG
    # Layer 2: ResourceGroupName property
    # Layer 3: Get-AzResource cache

    It 'Layer 0 wins when REST data is available' {
        $hpRestLookup = @{ 'pool-1' = @{ Id = '/subscriptions/s/resourceGroups/rest-rg/providers/X/y/pool-1'; ResourceGroup = 'rest-rg' } }
        $hp = [PSCustomObject]@{ Name = 'pool-1'; Id = '/subscriptions/s/resourceGroups/cmdlet-rg/providers/X/y/pool-1'; ResourceGroupName = 'prop-rg' }
        $hpArmLookup = @{ 'pool-1' = [PSCustomObject]@{ ResourceGroupName = 'arm-rg' } }

        $hpName = 'pool-1'
        $hpId = ''; $hpRg = ''
        if ($hpRestLookup.ContainsKey($hpName)) { $hpId = $hpRestLookup[$hpName].Id; $hpRg = $hpRestLookup[$hpName].ResourceGroup }
        $hpRg | Should -Be 'rest-rg'
    }

    It 'Layer 1 fires when REST is empty' {
        $hpRestLookup = @{}
        $hp = [PSCustomObject]@{ Name = 'pool-1'; Id = '/subscriptions/s/resourceGroups/cmdlet-rg/providers/X/y/pool-1' }

        $hpName = 'pool-1'
        $hpId = ''; $hpRg = ''
        if ($hpRestLookup.ContainsKey($hpName)) { $hpId = $hpRestLookup[$hpName].Id; $hpRg = $hpRestLookup[$hpName].ResourceGroup }
        if (-not $hpRg) {
            $cmdletId = SafeArmProp $hp 'Id'
            if ($cmdletId) { $hpId = $cmdletId; $hpRg = ($cmdletId -split '/')[4] }
        }
        $hpRg | Should -Be 'cmdlet-rg'
    }

    It 'Layer 2 fires when Id property is missing' {
        $hpRestLookup = @{}
        $hp = [PSCustomObject]@{ Name = 'pool-1'; ResourceGroupName = 'prop-rg' }

        $hpName = 'pool-1'
        $hpId = ''; $hpRg = ''
        if ($hpRestLookup.ContainsKey($hpName)) { $hpId = $hpRestLookup[$hpName].Id; $hpRg = $hpRestLookup[$hpName].ResourceGroup }
        if (-not $hpRg) {
            $cmdletId = SafeArmProp $hp 'Id'
            if ($cmdletId) { $hpId = $cmdletId; $hpRg = ($cmdletId -split '/')[4] }
        }
        if (-not $hpRg) { $hpRg = SafeProp $hp 'ResourceGroupName' }
        $hpRg | Should -Be 'prop-rg'
    }

    It 'Layer 3 fires when all object properties are missing' {
        $hpRestLookup = @{}
        $hp = [PSCustomObject]@{ Name = 'pool-1' }
        $hpArmLookup = @{ 'pool-1' = [PSCustomObject]@{ ResourceGroupName = 'arm-rg'; ResourceId = '/subscriptions/s/resourceGroups/arm-rg/providers/X/y/pool-1' } }

        $hpName = 'pool-1'
        $hpId = ''; $hpRg = ''
        if ($hpRestLookup.ContainsKey($hpName)) { $hpId = $hpRestLookup[$hpName].Id; $hpRg = $hpRestLookup[$hpName].ResourceGroup }
        if (-not $hpRg) {
            $cmdletId = SafeArmProp $hp 'Id'
            if ($cmdletId) { $hpId = $cmdletId; $hpRg = ($cmdletId -split '/')[4] }
        }
        if (-not $hpRg) { $hpRg = SafeProp $hp 'ResourceGroupName' }
        if (-not $hpRg -and $hpArmLookup.ContainsKey($hpName)) {
            $armObj = $hpArmLookup[$hpName]
            $hpRg = $armObj.ResourceGroupName
            if (-not $hpId -and $armObj.ResourceId) { $hpId = $armObj.ResourceId }
        }
        $hpRg | Should -Be 'arm-rg'
        $hpId | Should -BeLike '*/pool-1'
    }

    It 'Returns empty when all layers fail' {
        $hpRestLookup = @{}
        $hp = [PSCustomObject]@{ Name = 'pool-1' }
        $hpArmLookup = @{}

        $hpName = 'pool-1'
        $hpId = ''; $hpRg = ''
        if ($hpRestLookup.ContainsKey($hpName)) { $hpId = $hpRestLookup[$hpName].Id; $hpRg = $hpRestLookup[$hpName].ResourceGroup }
        if (-not $hpRg) {
            $cmdletId = SafeArmProp $hp 'Id'
            if ($cmdletId) { $hpId = $cmdletId; $hpRg = ($cmdletId -split '/')[4] }
        }
        if (-not $hpRg) { $hpRg = SafeProp $hp 'ResourceGroupName' }
        if (-not $hpRg -and $hpArmLookup.ContainsKey($hpName)) {
            $hpRg = $hpArmLookup[$hpName].ResourceGroupName
        }
        if (-not $hpRg) { $hpRg = '' }
        $hpRg | Should -Be ''
        $hpId | Should -Be ''
    }
}

Describe 'Protect-Email' {
    It 'Returns original when ScrubPII is off' {
        $global:ScrubPII = $false
        Protect-Email 'user@contoso.com' | Should -Be 'user@contoso.com'
    }
    It 'Masks middle of email when ScrubPII is on' {
        $global:ScrubPII = $true
        $script:piiCache = @{}
        $result = Protect-Email 'user@contoso.com'
        $result | Should -BeLike 'us*@contoso.com'
        $global:ScrubPII = $false
    }
    It 'Handles empty/null' {
        $global:ScrubPII = $true
        Protect-Email '' | Should -Be ''
        Protect-Email $null | Should -BeNullOrEmpty
        $global:ScrubPII = $false
    }
}

Describe 'Protect-TenantId' {
    It 'Masks when ScrubPII is on' {
        $global:ScrubPII = $true
        $result = Protect-TenantId 'abc-def-ghi-jklm'
        $result | Should -BeLike '****-****-****-*'
        $global:ScrubPII = $false
    }
}

Describe 'Protect-SubnetId' {
    It 'Returns hash prefix when ScrubPII is on' {
        $global:ScrubPII = $true
        $script:piiCache = @{}
        $result = Protect-SubnetId '/subscriptions/s/resourceGroups/rg/providers/Microsoft.Network/virtualNetworks/vnet/subnets/default'
        $result | Should -BeLike 'Subnet-*'
        $global:ScrubPII = $false
    }
}
