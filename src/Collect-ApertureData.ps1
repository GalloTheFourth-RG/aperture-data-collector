# PSScriptAnalyzer disable=PSAvoidUsingWriteHost,PSAvoidUsingEmptyCatchBlock,PSUseApprovedVerbs,PSReviewUnusedParameter,PSUseBOMForUnicodeEncodedFile

<#
.SYNOPSIS
    Aperture Data Collector -- Open-source data collection for Azure Virtual Desktop

.DESCRIPTION
    Collects ARM resource inventory, Azure Monitor metrics, and Log Analytics (KQL)
    query results from your AVD deployment and exports them as a portable collection
    pack (ZIP of JSON files).

    The output is compatible with Aperture (AVD Health Intelligence) for offline analysis.

    DISCLAIMER: This tool is provided as-is under the MIT License. It is not affiliated
    with, endorsed by, or supported by Microsoft. The script performs only read-only
    operations and does not create, modify, or delete any Azure resources. You run it at
    your own risk. This tool is not a substitute for professional consulting or Microsoft
    support. No warranty or support guarantee is provided.

    Version: 1.3.9
.PARAMETER TenantId
    Azure AD / Entra ID tenant ID
.PARAMETER SubscriptionIds
    Array of subscription IDs containing AVD resources
.PARAMETER LogAnalyticsWorkspaceResourceIds
    Log Analytics workspace resource IDs for KQL queries
.PARAMETER SkipAzureMonitorMetrics
    Skip CPU/memory/disk metric collection
.PARAMETER SkipLogAnalyticsQueries
    Skip all KQL queries
.PARAMETER MetricsLookbackDays
    Days of metrics history to collect (1-30, default: 7)
.PARAMETER MetricsTimeGrainMinutes
    Metric aggregation interval in minutes (5/15/30/60, default: 15)
.PARAMETER IncludeCostData
    Collect Azure Cost Management data (requires Cost Management Reader role).
    Produces per-VM and infrastructure cost breakdowns for the last 30 days.
.PARAMETER IncludeNetworkTopology
    Collect VNet/subnet analysis, NSG rules, NAT Gateway config, and
    private endpoint status for AVD host pools.
.PARAMETER IncludeImageAnalysis
    Collect Azure Compute Gallery image versions and marketplace image
    currency data for golden image freshness scoring.
.PARAMETER IncludeStorageAnalysis
    Collect FSLogix-related storage account and file share data including
    capacity, quotas, and private endpoint status.
.PARAMETER IncludeOrphanedResources
    Scan AVD resource groups for unattached disks, unused NICs, and
    unassociated public IPs.
.PARAMETER IncludeDiagnosticSettings
    Collect diagnostic settings for host pools and workspaces to identify
    missing or misconfigured log forwarding.
.PARAMETER IncludeAlertRules
    Collect Azure Monitor alert rules scoped to AVD resource groups.
.PARAMETER IncludeActivityLog
    Collect Activity Log entries (last 7 days) for AVD resource groups
    showing configuration changes, scaling events, and errors.
.PARAMETER IncludePolicyAssignments
    Collect Azure Policy assignments and compliance state for AVD
    resource groups.
.PARAMETER IncludeResourceTags
    Export resource tags for all collected VMs, host pools, and storage
    accounts for cost allocation and governance analysis.
.PARAMETER IncludeAllExtended
    Convenience switch: enables ALL extended collection flags at once
    (Cost, Network, Image, Storage, Orphaned Resources, Diagnostic Settings,
    Alert Rules, Activity Log, Policy Assignments, Resource Tags, Quota,
    Capacity Reservations). Does NOT enable Reserved Instances (requires
    Az.Reservations + tenant-level role).
.PARAMETER IncludeCapacityReservations
    Collect capacity reservation group data
.PARAMETER IncludeReservedInstances
    Collect Azure Reserved Instance (RI) data from billing reservations.
    Requires Az.Reservations module and Reservations Reader role at the
    tenant or enrollment level.
.PARAMETER IncludeIntune
    Collect Intune managed device data via Microsoft Graph API to cross-reference
    session host enrollment status. Requires Microsoft.Graph.Authentication module
    and DeviceManagementManagedDevices.Read.All + Policy.Read.All permissions. Graph authentication
    is handled separately from Azure (Connect-MgGraph). If an existing Graph
    context already matches the target tenant and required scopes, it is reused
    to reduce repeated sign-in prompts.
.PARAMETER IncludeQuotaUsage
    Collect per-region vCPU quota data
.PARAMETER IncludeIncidentWindow
    Collect a second set of metrics for an incident period
.PARAMETER IncidentWindowStart
    Start of incident window (datetime)
.PARAMETER IncidentWindowEnd
    End of incident window (datetime)
.PARAMETER ScrubPII
    Anonymize all identifiable data (VM names, host pool names, usernames,
    subscription IDs, IPs, resource groups) before export. Same entity always
    maps to the same anonymous ID within a run.
.PARAMETER ResumeFrom
    Path to a partial output folder from an interrupted run. The script will
    detect which steps already completed (by checking for checkpoint JSON files)
    and skip them, reloading the data into memory so downstream steps work.
.PARAMETER DryRun
    Preview collection scope without running
.PARAMETER SkipDisclaimer
    Skip interactive disclaimer prompt
.PARAMETER DisconnectGraphOnExit
    If set with -IncludeIntune, disconnect the Microsoft Graph session at the
    end of collection. By default, Graph stays connected so repeated runs can
    reuse auth context and avoid extra sign-in prompts.
.PARAMETER OutputPath
    Directory to write the collection pack (default: current directory)
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '')]
param(
    # Initialize script-scoped variables
    
    [Parameter(Mandatory = $true)]
    [string]$TenantId,
    [Parameter(Mandatory = $true)]
    [string[]]$SubscriptionIds,
    [string[]]$LogAnalyticsWorkspaceResourceIds = @(),
    [switch]$SkipAzureMonitorMetrics,
    [switch]$SkipLogAnalyticsQueries,
    [ValidateRange(1, 30)]
    [int]$MetricsLookbackDays = 7,
    [ValidateSet(5, 15, 30, 60)]
    [int]$MetricsTimeGrainMinutes = 15,
    [switch]$IncludeCostData,
    [switch]$IncludeNetworkTopology,
    [switch]$IncludeImageAnalysis,
    [switch]$IncludeStorageAnalysis,
    [switch]$IncludeOrphanedResources,
    [switch]$IncludeDiagnosticSettings,
    [switch]$IncludeAlertRules,
    [switch]$IncludeActivityLog,
    [switch]$IncludePolicyAssignments,
    [switch]$IncludeResourceTags,
    [switch]$IncludeAllExtended,
    [switch]$IncludeCapacityReservations,
    [switch]$IncludeReservedInstances,
    [switch]$IncludeIntune,
    [switch]$IncludeQuotaUsage,
    [switch]$IncludeIncidentWindow,
    [datetime]$IncidentWindowStart = (Get-Date).AddDays(-14),
    [datetime]$IncidentWindowEnd = (Get-Date),
    [switch]$ScrubPII,
    [string]$ResumeFrom,
    [switch]$DryRun,
    [switch]$SkipDisclaimer,
    [switch]$DisconnectGraphOnExit,
    [int]$MetricsParallel = 5,
    [int]$KqlParallel     = 5,
    [string]$OutputPath = "."
)  # MetricsParallel and KqlParallel control ForEach-Object throttling (default 5,5)

# -- Expand -IncludeAllExtended --
if ($IncludeAllExtended) {
    $IncludeCostData           = $true
    $IncludeNetworkTopology    = $true
    $IncludeImageAnalysis      = $true
    $IncludeStorageAnalysis    = $true
    $IncludeOrphanedResources  = $true
    $IncludeDiagnosticSettings = $true
    $IncludeAlertRules         = $true
    $IncludeActivityLog        = $true
    $IncludePolicyAssignments  = $true
    $IncludeResourceTags       = $true
    $IncludeQuotaUsage         = $true
    $IncludeCapacityReservations = $true
}

# Initialize script-scoped variables
$script:currentSubContext = $null

# @@INJECT:HELPERS@@
# When running from source (not built), dot-source helpers directly
if (-not (Get-Command SafeProp -ErrorAction SilentlyContinue)) {
    . (Join-Path $PSScriptRoot 'helpers.ps1')
}

$WarningPreference = 'SilentlyContinue'
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$script:ScriptVersion = "1.3.9"
$script:SchemaVersion = "2.0"

# Embedded KQL queries (populated by build.ps1, empty when running from source)
$script:EmbeddedKqlQueries = @{}

# Initialize main collection containers
$hostPools = [System.Collections.Generic.List[object]]::new()
$sessionHosts = [System.Collections.Generic.List[object]]::new()
$vms = [System.Collections.Generic.List[object]]::new()
$vmss = [System.Collections.Generic.List[object]]::new()
$vmssInstances = [System.Collections.Generic.List[object]]::new()
$appGroups = [System.Collections.Generic.List[object]]::new()
$scalingPlans = [System.Collections.Generic.List[object]]::new()
$scalingPlanAssignments = [System.Collections.Generic.List[object]]::new()
$scalingPlanSchedules = [System.Collections.Generic.List[object]]::new()
$vmMetrics = [System.Collections.Generic.List[object]]::new()
$vmMetricsIncident = [System.Collections.Generic.List[object]]::new()
$laResults = [System.Collections.Generic.List[object]]::new()
$capacityReservationGroups = [System.Collections.Generic.List[object]]::new()
$reservedInstances = [System.Collections.Generic.List[object]]::new()
$quotaUsage = [System.Collections.Generic.List[object]]::new()
$intuneManagedDevices = [System.Collections.Generic.List[object]]::new()
$conditionalAccessPolicies = [System.Collections.Generic.List[object]]::new()

# New v2.0 collection containers
$actualCostData = [System.Collections.Generic.List[object]]::new()
$vmActualMonthlyCost = @{}
$infraCostData = [System.Collections.Generic.List[object]]::new()
$costAccessGranted = [System.Collections.Generic.List[string]]::new()
$costAccessDenied = [System.Collections.Generic.List[string]]::new()
$subnetAnalysis = [System.Collections.Generic.List[object]]::new()
$vnetAnalysis = [System.Collections.Generic.List[object]]::new()
$privateEndpointFindings = [System.Collections.Generic.List[object]]::new()
$nsgRuleFindings = [System.Collections.Generic.List[object]]::new()
$galleryAnalysis = [System.Collections.Generic.List[object]]::new()
$galleryImageDetails = [System.Collections.Generic.List[object]]::new()
$marketplaceImageDetails = [System.Collections.Generic.List[object]]::new()
$fslogixStorageAnalysis = [System.Collections.Generic.List[object]]::new()
$fslogixShares = [System.Collections.Generic.List[object]]::new()
$orphanedResources = [System.Collections.Generic.List[object]]::new()
$diagnosticSettings = [System.Collections.Generic.List[object]]::new()
$alertRules = [System.Collections.Generic.List[object]]::new()
$alertHistory = [System.Collections.Generic.List[object]]::new()
$activityLogEntries = [System.Collections.Generic.List[object]]::new()
$policyAssignments = [System.Collections.Generic.List[object]]::new()
$resourceTags = [System.Collections.Generic.List[object]]::new()

# Track all AVD resource groups across subscriptions (SubId|RGName -> $true)
$avdResourceGroups = @{}

# Nerdio Manager detection (runs on raw data before PII scrubbing)
$nerdioDetected = $false
$nerdioSignals = [System.Collections.Generic.List[string]]::new()
$nerdioManagedPools = @{}  # raw HostPoolName -> $true

# Raw subnet-to-subscription lookup for network topology (survives PII scrubbing)
# Key = raw subnet ARM ID, Value = @{ SubId = ...; VmCount = 0 }
$rawSubnetLookup = @{}

# Raw host pool IDs for PE/diagnostic checks (survives PII scrubbing)
# Key = scrubbed HP name, Value = raw ARM ID
$rawHostPoolIds = @{}

# Misc helpers / caches

# =========================================================
# PowerShell 7 Requirement
# =========================================================
if ($PSVersionTable.PSVersion.Major -lt 7) {
    Write-Host ""
    Write-Host "ERROR: PowerShell 7+ is required." -ForegroundColor Red
    Write-Host ""
    Write-Host "You are running PowerShell $($PSVersionTable.PSVersion)" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "Install PowerShell 7:" -ForegroundColor Cyan
    Write-Host "  winget install Microsoft.PowerShell" -ForegroundColor White
    Write-Host "  or: https://aka.ms/powershell-release?tag=stable" -ForegroundColor White
    Write-Host ""
    Write-Host "Then run this script from pwsh.exe (not powershell.exe)" -ForegroundColor Cyan
    exit 1
}

# =========================================================
# PII Scrubbing -- runtime state (functions injected from helpers.ps1)
# =========================================================
$script:piiSalt = [guid]::NewGuid().ToString().Substring(0, 8)
$script:piiCache = @{}

# =========================================================
# Prerequisite Validation
# =========================================================
Write-Host ""
Write-Host "+=======================================================================+" -ForegroundColor Cyan
Write-Host "|                                                                       |" -ForegroundColor Cyan
Write-Host "|          Aperture Data Collector -- v$($script:ScriptVersion)                            |" -ForegroundColor Cyan
Write-Host "|          Open-Source Data Collection for Azure Virtual Desktop        |" -ForegroundColor Cyan
Write-Host "|                                                                       |" -ForegroundColor Cyan
Write-Host "+=======================================================================+" -ForegroundColor Cyan
Write-Host ""

Write-Host "Validating prerequisites..." -ForegroundColor Cyan

$requiredModules = @(
    @{Name = 'Az.Accounts';              MinVersion = '2.0.0' },
    @{Name = 'Az.Compute';               MinVersion = '4.0.0' },
    @{Name = 'Az.DesktopVirtualization';  MinVersion = '2.0.0' },
    @{Name = 'Az.Monitor';               MinVersion = '2.0.0' },
    @{Name = 'Az.OperationalInsights';    MinVersion = '2.0.0' },
    @{Name = 'Az.Resources';             MinVersion = '4.0.0' }
)

$missingModules = @()
foreach ($module in $requiredModules) {
    $installed = Get-Module -ListAvailable -Name $module.Name |
        Where-Object { $_.Version -ge [version]$module.MinVersion } |
        Select-Object -First 1

    if (-not $installed) {
        $missingModules += $module.Name
        Write-Host "  [X] Missing: $($module.Name) (>= $($module.MinVersion))" -ForegroundColor Red
    }
    else {
        Write-Host "  [OK] Found: $($module.Name) v$($installed.Version)" -ForegroundColor Green
    }
}

if ($missingModules.Count -gt 0) {
    Write-Host ""
    Write-Host "Missing $($missingModules.Count) required module(s). Install them with:" -ForegroundColor Red
    foreach ($m in $missingModules) {
        Write-Host "  Install-Module -Name $m -Scope CurrentUser -Force" -ForegroundColor White
    }
    Write-Host ""
    exit 1
}

# Optional module: Az.Reservations (for -IncludeReservedInstances)
$script:hasAzReservations = $false
if ($IncludeReservedInstances) {
    $azResModule = Get-Module -ListAvailable -Name 'Az.Reservations' | Select-Object -First 1
    if ($azResModule) {
        $script:hasAzReservations = $true
        Write-Host "  [OK] Optional: Az.Reservations v$($azResModule.Version)" -ForegroundColor Green
    } else {
        Write-Host "  [WARN] Az.Reservations module not installed -- cannot collect Reserved Instances" -ForegroundColor Yellow
        Write-Host "    Install with: Install-Module -Name Az.Reservations -Scope CurrentUser -Force" -ForegroundColor Gray
        Write-Host "    Also requires Reservations Reader role at the tenant or enrollment level" -ForegroundColor Gray
    }
}

# Optional module: Az.Network (for NIC lookups, subnet/VNet/NSG analysis)
$script:hasAzNetwork = $false
$azNetModule = Get-Module -ListAvailable -Name 'Az.Network' | Select-Object -First 1
if ($azNetModule) {
    $script:hasAzNetwork = $true
    Write-Host "  [OK] Found: Az.Network v$($azNetModule.Version)" -ForegroundColor Green
} else {
    Write-Host "  [WARN] Az.Network not installed -- NIC/IP data and network topology will be limited" -ForegroundColor Yellow
    Write-Host "    Install with: Install-Module -Name Az.Network -Scope CurrentUser -Force" -ForegroundColor Gray
}

# Optional module: Az.Storage (for FSLogix storage analysis)
$script:hasAzStorage = $false
if ($IncludeStorageAnalysis) {
    $azStorageModule = Get-Module -ListAvailable -Name 'Az.Storage' | Select-Object -First 1
    if ($azStorageModule) {
        $script:hasAzStorage = $true
        Write-Host "  [OK] Optional: Az.Storage v$($azStorageModule.Version)" -ForegroundColor Green
    } else {
        Write-Host "  [WARN] Az.Storage not installed -- cannot collect FSLogix storage data" -ForegroundColor Yellow
        Write-Host "    Install with: Install-Module -Name Az.Storage -Scope CurrentUser -Force" -ForegroundColor Gray
    }
}

# Optional module: Microsoft.Graph.Authentication (for Intune device data)
$script:hasMgGraph = $false
if ($IncludeIntune) {
    $mgAuthModule = Get-Module -ListAvailable -Name 'Microsoft.Graph.Authentication' | Select-Object -First 1
    if ($mgAuthModule) {
        $script:hasMgGraph = $true
        Write-Host "  [OK] Optional: Microsoft.Graph.Authentication v$($mgAuthModule.Version)" -ForegroundColor Green
    } else {
        Write-Host "  [WARN] Microsoft.Graph.Authentication not installed -- cannot collect Intune data" -ForegroundColor Yellow
        Write-Host "    Install with: Install-Module -Name Microsoft.Graph.Authentication -Scope CurrentUser -Force" -ForegroundColor Gray
    }
}

Write-Host ""

# =========================================================
# Azure Authentication & Subscription Pre-Flight
# =========================================================
Write-Host "Validating Azure connection..." -ForegroundColor Cyan

$existingContext = Get-AzContext -ErrorAction SilentlyContinue

if (-not $existingContext -or -not $existingContext.Account) {
    Write-Host "  No active Azure session found. Logging in..." -ForegroundColor Yellow
    try {
        Disable-AzContextAutosave -Scope Process -ErrorAction SilentlyContinue | Out-Null
        Connect-AzAccount -TenantId $TenantId -SubscriptionId $SubscriptionIds[0] -ErrorAction Stop | Out-Null
        $existingContext = Get-AzContext
    }
    catch {
        Write-Host ""
        Write-Host "  [X] Azure login failed: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host ""
        Write-Host "  Run this command first, then re-run the collector:" -ForegroundColor Yellow
        Write-Host "    Connect-AzAccount -TenantId '$(Protect-TenantId $TenantId)'" -ForegroundColor White
        Write-Host ""
        exit 1
    }
} elseif ($existingContext.Tenant.Id -ne $TenantId) {
    Write-Host "  [WARN] Current session is for tenant $(Protect-TenantId $existingContext.Tenant.Id) -- switching to $(Protect-TenantId $TenantId)" -ForegroundColor Yellow
    try {
        Disable-AzContextAutosave -Scope Process -ErrorAction SilentlyContinue | Out-Null
        Clear-AzContext -Scope Process -Force -ErrorAction SilentlyContinue | Out-Null
        Connect-AzAccount -TenantId $TenantId -SubscriptionId $SubscriptionIds[0] -ErrorAction Stop | Out-Null
        $existingContext = Get-AzContext
    }
    catch {
        Write-Host "  [X] Failed to switch tenant: $($_.Exception.Message)" -ForegroundColor Red
        exit 1
    }
}

# Validate token is still active
$availableSubs = @()
try {
    $availableSubs = @(Get-AzSubscription -TenantId $TenantId -ErrorAction Stop)
}
catch {
    Write-Host "  [WARN] Session token expired -- re-authenticating..." -ForegroundColor Yellow
    try {
        Disable-AzContextAutosave -Scope Process -ErrorAction SilentlyContinue | Out-Null
        Clear-AzContext -Scope Process -Force -ErrorAction SilentlyContinue | Out-Null
        Connect-AzAccount -TenantId $TenantId -SubscriptionId $SubscriptionIds[0] -ErrorAction Stop | Out-Null
        $availableSubs = @(Get-AzSubscription -TenantId $TenantId -ErrorAction Stop)
    }
    catch {
        Write-Host "  [X] Authentication failed: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host "    Run: Connect-AzAccount -TenantId '$(Protect-TenantId $TenantId)'" -ForegroundColor White
        exit 1
    }
}

$isManagedIdentity = $existingContext -and $existingContext.Account.Type -eq 'ManagedService'
if ($isManagedIdentity) {
    Write-Host "  [OK] Authenticated via Managed Identity" -ForegroundColor Green
} else {
    Write-Host "  [OK] Authenticated as: $(Protect-Email $existingContext.Account.Id)" -ForegroundColor Green
}
Write-Host "    Tenant: $(Protect-TenantId $TenantId)" -ForegroundColor Gray

# -- Subscription access pre-flight --
Write-Host ""
Write-Host "Validating subscription access..." -ForegroundColor Cyan
$availableSubIds = @($availableSubs | ForEach-Object { $_.Id })
$subsFailed = @()
foreach ($subId in $SubscriptionIds) {
    if ($subId -notin $availableSubIds) {
        $subsFailed += $subId
        Write-Host "  [X] Subscription $(Protect-SubscriptionId $subId) -- not accessible with this account" -ForegroundColor Red
        $closestMatch = $availableSubs | Where-Object { $_.Name -match 'vdi|avd|desktop' -or $_.Id -like "$($subId.Substring(0,8))*" } | Select-Object -First 1
        if ($closestMatch) {
            Write-Host "    Did you mean: $(Protect-SubscriptionId $closestMatch.Id)?" -ForegroundColor Yellow
        }
    } else {
        Write-Host "  [OK] $(Protect-SubscriptionId $subId)" -ForegroundColor Green
    }
}

if ($subsFailed.Count -eq $SubscriptionIds.Count) {
    Write-Host ""
    Write-Host "  [X] None of the specified subscriptions are accessible." -ForegroundColor Red
    Write-Host "    Available subscriptions in this tenant:" -ForegroundColor Gray
    foreach ($s in ($availableSubs | Select-Object -First 10)) {
        Write-Host "      * $(Protect-Value -Value $s.Name -Prefix 'Sub' -Length 4) ($(Protect-SubscriptionId $s.Id))" -ForegroundColor Gray
    }
    if ($availableSubs.Count -gt 10) { Write-Host "      ... and $($availableSubs.Count - 10) more" -ForegroundColor Gray }
    Write-Host ""
    exit 1
} elseif ($subsFailed.Count -gt 0) {
    Write-Host ""
    Write-Host "  [WARN] $($subsFailed.Count) subscription(s) not accessible -- they will be skipped" -ForegroundColor Yellow
}

# -- Log Analytics workspace ID format validation --
if ($LogAnalyticsWorkspaceResourceIds.Count -gt 0 -and -not $SkipLogAnalyticsQueries) {
    Write-Host ""
    Write-Host "Validating workspace resource IDs..." -ForegroundColor Cyan
    foreach ($wsId in $LogAnalyticsWorkspaceResourceIds) {
        $wsParts = ($wsId.TrimEnd('/') -split '/')
        if ($wsParts.Count -lt 9 -or $wsId -notmatch 'Microsoft\.OperationalInsights/workspaces') {
            Write-Host "  [WARN] Invalid workspace resource ID format:" -ForegroundColor Yellow
            Write-Host "    $(Protect-ArmId $wsId)" -ForegroundColor Gray
            Write-Host "    Expected: /subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.OperationalInsights/workspaces/<name>" -ForegroundColor Gray
        } else {
            $wsName = $wsParts[8]
            Write-Host "  [OK] $(Protect-Value -Value $wsName -Prefix 'WS' -Length 4)" -ForegroundColor Green
        }
    }
}

Write-Host ""

# =========================================================
# Microsoft Graph Authentication (for -IncludeIntune)
# =========================================================
$script:mgGraphConnected = $false
$script:mgGraphReusedContext = $false
$script:mgGraphConnectedByScript = $false
if ($IncludeIntune -and $script:hasMgGraph) {
    Write-Host "Connecting to Microsoft Graph for Intune data..." -ForegroundColor Cyan
    try {
        $intuneScopes = @("DeviceManagementManagedDevices.Read.All", "Policy.Read.All")
        $mgContext = $null
        $contextReusable = $false
        $graphContextScopeApplied = "Process"

        # Reuse existing Graph context when tenant + scopes already match.
        try { $mgContext = Get-MgContext -ErrorAction SilentlyContinue } catch { $mgContext = $null }
        if ($null -ne $mgContext -and $null -ne $mgContext.Account -and $null -ne $mgContext.TenantId) {
            $tenantMatches = (([string]$mgContext.TenantId).ToLowerInvariant() -eq ([string]$TenantId).ToLowerInvariant())
            $contextScopes = @()
            if ($mgContext.PSObject.Properties.Match('Scopes').Count -gt 0 -and $mgContext.Scopes) {
                $contextScopes = @($mgContext.Scopes)
            }

            $hasAllScopes = $true
            foreach ($requiredScope in $intuneScopes) {
                if ($contextScopes -notcontains $requiredScope) {
                    $hasAllScopes = $false
                    break
                }
            }

            if ($tenantMatches -and $hasAllScopes) {
                $contextReusable = $true
            }
        }

        if ($contextReusable) {
            $script:mgGraphConnected = $true
            $script:mgGraphReusedContext = $true
            Write-Host "  [OK] Reusing existing Graph session as $(Protect-Email $mgContext.Account)" -ForegroundColor Green
        } else {
            $connectMgGraphCmd = Get-Command Connect-MgGraph -ErrorAction SilentlyContinue
            $connectParams = @{
                TenantId    = $TenantId
                Scopes      = $intuneScopes
                NoWelcome   = $true
                ErrorAction = 'Stop'
            }
            if ($null -ne $connectMgGraphCmd -and $connectMgGraphCmd.Parameters.ContainsKey('ContextScope')) {
                $connectParams['ContextScope'] = 'CurrentUser'
                $graphContextScopeApplied = 'CurrentUser'
            }

            Connect-MgGraph @connectParams
            $mgContext = Get-MgContext
            if ($null -ne $mgContext -and $null -ne $mgContext.Account) {
                $script:mgGraphConnected = $true
                $script:mgGraphConnectedByScript = $true
                Write-Host "  [OK] Graph connected as $(Protect-Email $mgContext.Account)" -ForegroundColor Green
                if ($graphContextScopeApplied -eq 'CurrentUser') {
                    Write-Host "  [OK] Graph context scope: CurrentUser (cross-run reuse enabled)" -ForegroundColor Gray
                }
            } else {
                Write-Host "  [WARN] Graph connection established but no context returned" -ForegroundColor Yellow
            }
        }
    } catch {
        Write-Host "  [WARN] Graph authentication failed: $($_.Exception.Message)" -ForegroundColor Yellow
        Write-Host "    Intune device data will not be collected" -ForegroundColor Gray
    }
} elseif ($IncludeIntune -and -not $script:hasMgGraph) {
    Write-Host ""
    Write-Host "[WARN] -IncludeIntune requires Microsoft.Graph.Authentication module" -ForegroundColor Yellow
}

# =========================================================
# DryRun Pre-Flight -- Validate permissions without collecting
# =========================================================
if ($DryRun) {
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host "  DRY RUN -- Permission & Access Check" -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host ""

    $dryResults = [System.Collections.Generic.List[object]]::new()

    # -- 1. Host Pool access probe (core requirement) --
    Write-Host "  Probing AVD host pool access..." -ForegroundColor Gray
    $hpProbeOk = $false
    $totalHPs = 0
    foreach ($subId in $SubscriptionIds) {
        try {
            Set-AzContext -SubscriptionId $subId -TenantId $TenantId -ErrorAction Stop | Out-Null
            $hps = @(Get-AzWvdHostPool -ErrorAction Stop)
            $totalHPs += $hps.Count
            $hpProbeOk = $true
        } catch {
            # access denied or other error for this sub
        }
    }
    if ($hpProbeOk) {
        Write-Host "    [OK] Host pools accessible ($totalHPs found)" -ForegroundColor Green
        $dryResults.Add([PSCustomObject]@{ Check = "AVD Host Pools"; Status = "OK"; Detail = "$totalHPs host pools found"; Role = "Reader" })
    } else {
        Write-Host "    [FAIL] Cannot read host pools -- need Reader on subscription" -ForegroundColor Red
        $dryResults.Add([PSCustomObject]@{ Check = "AVD Host Pools"; Status = "FAIL"; Detail = "Access denied"; Role = "Reader" })
    }

    # -- 2. VM access probe --
    Write-Host "  Probing VM access..." -ForegroundColor Gray
    $vmProbeOk = $false
    foreach ($subId in $SubscriptionIds) {
        try {
            Set-AzContext -SubscriptionId $subId -TenantId $TenantId -ErrorAction Stop | Out-Null
            $null = @(Get-AzVM -ErrorAction Stop | Select-Object -First 1)
            $vmProbeOk = $true
            break
        } catch { }
    }
    if ($vmProbeOk) {
        Write-Host "    [OK] VM inventory accessible" -ForegroundColor Green
        $dryResults.Add([PSCustomObject]@{ Check = "VM Inventory"; Status = "OK"; Detail = "Read access confirmed"; Role = "Reader" })
    } else {
        Write-Host "    [FAIL] Cannot read VMs -- need Reader on subscription" -ForegroundColor Red
        $dryResults.Add([PSCustomObject]@{ Check = "VM Inventory"; Status = "FAIL"; Detail = "Access denied"; Role = "Reader" })
    }

    # -- 3. Azure Monitor metrics probe --
    if (-not $SkipAzureMonitorMetrics) {
        Write-Host "  Probing Azure Monitor metrics..." -ForegroundColor Gray
        $metricsOk = $true  # Reader covers this; if VMs are readable, metrics usually are too
        Write-Host "    [OK] Metrics access available (covered by Reader role)" -ForegroundColor Green
        $dryResults.Add([PSCustomObject]@{ Check = "Azure Monitor Metrics"; Status = "OK"; Detail = "Covered by Reader role"; Role = "Reader" })
    } else {
        Write-Host "    [SKIP] Metrics collection disabled" -ForegroundColor Yellow
        $dryResults.Add([PSCustomObject]@{ Check = "Azure Monitor Metrics"; Status = "SKIP"; Detail = "Disabled via -SkipAzureMonitorMetrics"; Role = "Reader" })
    }

    # -- 4. Log Analytics workspace probe --
    if ($LogAnalyticsWorkspaceResourceIds.Count -gt 0 -and -not $SkipLogAnalyticsQueries) {
        Write-Host "  Probing Log Analytics workspace access..." -ForegroundColor Gray
        foreach ($wsId in $LogAnalyticsWorkspaceResourceIds) {
            $wsParts = $wsId.TrimEnd('/') -split '/'
            $wsName = $wsParts[-1]
            $wsRg   = $wsParts[4]
            $wsNameSafe = Protect-Value -Value $wsName -Prefix 'WS' -Length 4
            $wsSubId = $wsParts[2]
            try {
                if ($wsSubId -ne $script:currentSubContext) {
                    Set-AzContext -SubscriptionId $wsSubId -TenantId $TenantId -ErrorAction Stop | Out-Null
                    $script:currentSubContext = $wsSubId
                }
                # Resolve workspace object (validates existence + read access)
                $wsObj = Get-AzOperationalInsightsWorkspace -ResourceGroupName $wsRg -Name $wsName -ErrorAction Stop
                # Try a minimal KQL query to test query access
                $testResult = Invoke-AzOperationalInsightsQuery -WorkspaceId $wsObj.CustomerId -Query "print test=1" -ErrorAction Stop
                Write-Host "    [OK] $wsNameSafe -- query access confirmed" -ForegroundColor Green
                $dryResults.Add([PSCustomObject]@{ Check = "Log Analytics: $wsNameSafe"; Status = "OK"; Detail = "Query access confirmed"; Role = "Log Analytics Reader" })
            } catch {
                $errMsg = $_.Exception.Message
                if ($errMsg -match '403|Forbidden|AuthorizationFailed') {
                    Write-Host "    [FAIL] $wsNameSafe -- access denied (need Log Analytics Reader on workspace)" -ForegroundColor Red
                    $dryResults.Add([PSCustomObject]@{ Check = "Log Analytics: $wsNameSafe"; Status = "FAIL"; Detail = "Access denied"; Role = "Log Analytics Reader" })
                } elseif ($errMsg -match '404|NotFound|ResourceNotFound') {
                    Write-Host "    [FAIL] $wsNameSafe -- workspace not found (check resource ID)" -ForegroundColor Red
                    $dryResults.Add([PSCustomObject]@{ Check = "Log Analytics: $wsNameSafe"; Status = "FAIL"; Detail = "Not found"; Role = "Log Analytics Reader" })
                } else {
                    Write-Host "    [WARN] $wsNameSafe -- $errMsg" -ForegroundColor Yellow
                    $dryResults.Add([PSCustomObject]@{ Check = "Log Analytics: $wsNameSafe"; Status = "WARN"; Detail = $errMsg; Role = "Log Analytics Reader" })
                }
            }
        }
    } elseif ($SkipLogAnalyticsQueries) {
        Write-Host "    [SKIP] Log Analytics disabled" -ForegroundColor Yellow
        $dryResults.Add([PSCustomObject]@{ Check = "Log Analytics"; Status = "SKIP"; Detail = "Disabled via -SkipLogAnalyticsQueries"; Role = "Log Analytics Reader" })
    } else {
        Write-Host "    [WARN] No workspace IDs provided -- KQL queries will be skipped" -ForegroundColor Yellow
        $dryResults.Add([PSCustomObject]@{ Check = "Log Analytics"; Status = "WARN"; Detail = "No workspace IDs provided"; Role = "Log Analytics Reader" })
    }

    # -- 5. Cost Management probe --
    if ($IncludeCostData) {
        Write-Host "  Probing Cost Management access..." -ForegroundColor Gray
        $costProbeOk = $false
        foreach ($subId in $SubscriptionIds) {
            try {
                Set-AzContext -SubscriptionId $subId -TenantId $TenantId -ErrorAction Stop | Out-Null
                $testBody = @{ type = "Usage"; timeframe = "MonthToDate"; dataset = @{ granularity = "None"; aggregation = @{ totalCost = @{ name = "Cost"; function = "Sum" } } } } | ConvertTo-Json -Depth 10
                $resp = Invoke-AzRestMethod -Path "/subscriptions/$subId/providers/Microsoft.CostManagement/query?api-version=2023-11-01" -Method POST -Payload $testBody -ErrorAction Stop
                if ($resp.StatusCode -eq 200) { $costProbeOk = $true; break }
            } catch { }
        }
        if ($costProbeOk) {
            Write-Host "    [OK] Cost Management access confirmed" -ForegroundColor Green
            $dryResults.Add([PSCustomObject]@{ Check = "Cost Management"; Status = "OK"; Detail = "Access confirmed"; Role = "Cost Management Reader" })
        } else {
            Write-Host "    [FAIL] Cost Management access denied" -ForegroundColor Red
            Write-Host "      Assign Cost Management Reader on the subscription" -ForegroundColor Gray
            $dryResults.Add([PSCustomObject]@{ Check = "Cost Management"; Status = "FAIL"; Detail = "Access denied"; Role = "Cost Management Reader" })
        }
    }

    # -- 6. Optional module availability --
    if ($IncludeNetworkTopology -and -not $script:hasAzNetwork) {
        $dryResults.Add([PSCustomObject]@{ Check = "Network Topology"; Status = "FAIL"; Detail = "Az.Network module not installed"; Role = "Reader + Az.Network module" })
    } elseif ($IncludeNetworkTopology) {
        $dryResults.Add([PSCustomObject]@{ Check = "Network Topology"; Status = "OK"; Detail = "Az.Network available"; Role = "Reader" })
    }
    if ($IncludeStorageAnalysis -and -not $script:hasAzStorage) {
        $dryResults.Add([PSCustomObject]@{ Check = "Storage Analysis"; Status = "FAIL"; Detail = "Az.Storage module not installed"; Role = "Reader + Az.Storage module" })
    } elseif ($IncludeStorageAnalysis) {
        $dryResults.Add([PSCustomObject]@{ Check = "Storage Analysis"; Status = "OK"; Detail = "Az.Storage available"; Role = "Reader" })
    }
    if ($IncludeReservedInstances -and -not $script:hasAzReservations) {
        $dryResults.Add([PSCustomObject]@{ Check = "Reserved Instances"; Status = "FAIL"; Detail = "Az.Reservations module not installed"; Role = "Reservations Reader + Az.Reservations module" })
    } elseif ($IncludeReservedInstances) {
        $dryResults.Add([PSCustomObject]@{ Check = "Reserved Instances"; Status = "OK"; Detail = "Az.Reservations available"; Role = "Reservations Reader" })
    }
    if ($IncludeIntune -and -not $script:hasMgGraph) {
        $dryResults.Add([PSCustomObject]@{ Check = "Intune Devices"; Status = "FAIL"; Detail = "Microsoft.Graph.Authentication module not installed"; Role = "DeviceManagementManagedDevices.Read.All + Policy.Read.All + Microsoft.Graph.Authentication module" })
    } elseif ($IncludeIntune -and -not $script:mgGraphConnected) {
        $dryResults.Add([PSCustomObject]@{ Check = "Intune Devices"; Status = "FAIL"; Detail = "Graph authentication failed"; Role = "DeviceManagementManagedDevices.Read.All + Policy.Read.All" })
    } elseif ($IncludeIntune) {
        # Probe: try to list managed devices (first page only)
        Write-Host "  Probing Intune managed device access..." -ForegroundColor Gray
        try {
            $probeResult = Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/deviceManagement/managedDevices?`$top=1&`$select=id" -ErrorAction Stop
            Write-Host "    [OK] Intune managed device access confirmed" -ForegroundColor Green
            $dryResults.Add([PSCustomObject]@{ Check = "Intune Devices"; Status = "OK"; Detail = "Access confirmed"; Role = "DeviceManagementManagedDevices.Read.All" })
        } catch {
            $errMsg = $_.Exception.Message
            if ($errMsg -match '403|Forbidden') {
                Write-Host "    [FAIL] Intune access denied -- need DeviceManagementManagedDevices.Read.All" -ForegroundColor Red
                $dryResults.Add([PSCustomObject]@{ Check = "Intune Devices"; Status = "FAIL"; Detail = "Access denied"; Role = "DeviceManagementManagedDevices.Read.All" })
            } else {
                Write-Host "    [WARN] Intune probe: $errMsg" -ForegroundColor Yellow
                $dryResults.Add([PSCustomObject]@{ Check = "Intune Devices"; Status = "WARN"; Detail = $errMsg; Role = "DeviceManagementManagedDevices.Read.All" })
            }
        }
        # Probe: Conditional Access policies
        Write-Host "  Probing Conditional Access policy access..." -ForegroundColor Gray
        try {
            $caProbe = Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/identity/conditionalAccess/policies?`$top=1&`$select=id" -ErrorAction Stop
            Write-Host "    [OK] Conditional Access policy access confirmed" -ForegroundColor Green
            $dryResults.Add([PSCustomObject]@{ Check = "Conditional Access"; Status = "OK"; Detail = "Access confirmed"; Role = "Policy.Read.All" })
        } catch {
            $caErrMsg = $_.Exception.Message
            if ($caErrMsg -match '403|Forbidden') {
                Write-Host "    [FAIL] CA policy access denied -- need Policy.Read.All" -ForegroundColor Red
                $dryResults.Add([PSCustomObject]@{ Check = "Conditional Access"; Status = "FAIL"; Detail = "Access denied"; Role = "Policy.Read.All" })
            } else {
                Write-Host "    [WARN] CA probe: $caErrMsg" -ForegroundColor Yellow
                $dryResults.Add([PSCustomObject]@{ Check = "Conditional Access"; Status = "WARN"; Detail = $caErrMsg; Role = "Policy.Read.All" })
            }
        }
    }

    # -- Summary --
    Write-Host ""
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host "  Pre-Flight Summary" -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host ""

    $okCount   = @($dryResults | Where-Object { $_.Status -eq "OK" }).Count
    $failCount = @($dryResults | Where-Object { $_.Status -eq "FAIL" }).Count
    $warnCount = @($dryResults | Where-Object { $_.Status -eq "WARN" }).Count
    $skipCount = @($dryResults | Where-Object { $_.Status -eq "SKIP" }).Count

    foreach ($r in $dryResults) {
        $icon = switch ($r.Status) { "OK" { "[OK]" }; "FAIL" { "[FAIL]" }; "WARN" { "[WARN]" }; "SKIP" { "[SKIP]" } }
        $color = switch ($r.Status) { "OK" { "Green" }; "FAIL" { "Red" }; "WARN" { "Yellow" }; "SKIP" { "Yellow" } }
        Write-Host "  $icon $($r.Check)" -ForegroundColor $color -NoNewline
        Write-Host " -- $($r.Detail)" -ForegroundColor Gray
        if ($r.Status -eq "FAIL") {
            Write-Host "         Required: $($r.Role)" -ForegroundColor DarkGray
        }
    }

    Write-Host ""
    if ($failCount -eq 0) {
        Write-Host "  All checks passed ($okCount OK, $warnCount warnings, $skipCount skipped)" -ForegroundColor Green
        Write-Host "  Ready to collect. Remove -DryRun to start data collection." -ForegroundColor Cyan
    } else {
        Write-Host "  $failCount check(s) failed, $okCount passed, $warnCount warnings" -ForegroundColor Red
        Write-Host "  Fix the failed checks above, then re-run with -DryRun to verify." -ForegroundColor Yellow
        Write-Host "  See docs/PERMISSIONS.md for role assignment commands." -ForegroundColor Gray
    }

    # Estimate collection time
    if ($totalHPs -gt 0) {
        Write-Host ""
        $estMinutes = [math]::Max(3, [math]::Round($totalHPs * 1.5 + 2, 0))
        if (-not $SkipAzureMonitorMetrics) { $estMinutes += 3 }
        if ($LogAnalyticsWorkspaceResourceIds.Count -gt 0 -and -not $SkipLogAnalyticsQueries) { $estMinutes += 5 }
        if ($IncludeAllExtended) { $estMinutes += 5 }
        Write-Host "  Estimated collection time: ~$estMinutes minutes" -ForegroundColor Gray
    }

    Write-Host ""
    exit 0
}

# Raw VM ARM IDs for metrics collection (unaffected by PII scrubbing)
$rawVmIds               = [System.Collections.Generic.List[string]]::new()
# Raw VM names for Log Analytics perf queries (unaffected by PII scrubbing)
$rawVmNames             = [System.Collections.Generic.List[string]]::new()

# NIC cache: batch-fetch per RG
$nicCacheByRg = @{}

# VM cache: bulk-fetch per RG for O(n/rg) instead of O(n) API calls
$vmCacheByRg = @{}
$vmStatusCacheByRg = @{}
$vmCacheByName = @{}
$vmExtCache = @{}           # VMName -> List<string> of extension types (batch-fetched via ARM)

# Disk encryption cache
$script:diskEncCache = @{}
$script:diskCreatedCache = @{}

# Timing
$script:collectionStart = Get-Date

# =========================================================
# Checkpoint / Resume helpers
# =========================================================
function Save-Checkpoint {
    param([string]$StepName)
    $cpFile = Join-Path $outFolder "_checkpoint_${StepName}.json"
    @{ Step = $StepName; Timestamp = (Get-Date -Format 'o') } | ConvertTo-Json | Out-File -FilePath $cpFile -Encoding UTF8
}

function Test-Checkpoint {
    param([string]$StepName)
    $cpFile = Join-Path $outFolder "_checkpoint_${StepName}.json"
    return (Test-Path $cpFile)
}

function Import-StepData {
    param([string]$FileName, [System.Collections.Generic.List[object]]$Target)
    $fp = Join-Path $outFolder $FileName
    if (Test-Path $fp) {
        $data = Get-Content $fp -Raw | ConvertFrom-Json
        foreach ($item in @($data)) { $Target.Add($item) }
        Write-Host "    Loaded $(SafeCount $Target) items from $FileName" -ForegroundColor Gray
    }
}

function Export-PackJson {
    param([string]$FileName, [object]$Data)
    $filePath = Join-Path $outFolder $FileName
    $Data | ConvertTo-Json -Depth 10 -Compress | Out-File -FilePath $filePath -Encoding UTF8
    $count = if ($Data -is [System.Collections.ICollection]) { $Data.Count } else { @($Data).Count }
    Write-Host "    [OK] $FileName -- $count items" -ForegroundColor Green
}

# Resuming from a previous partial run?
$script:isResume = $false
if ($ResumeFrom) {
    if (-not (Test-Path $ResumeFrom)) {
        Write-Host "ERROR: Resume folder not found: $ResumeFrom" -ForegroundColor Red
        exit 1
    }
    $outFolder = (Resolve-Path $ResumeFrom).Path
    $script:isResume = $true
    Write-Host "" 
    Write-Host "  RESUMING from: $outFolder" -ForegroundColor Yellow
    Write-Host ""
}
else {
    # Output folder (create early so exports work)
    try {
        $timeStamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
        $outFolderName = "Aperture-CollectionPack-$timeStamp"
        $baseOut = if ($OutputPath) { (Resolve-Path -Path $OutputPath).Path } else { (Get-Location).Path }
        $outFolder = Join-Path $baseOut $outFolderName
        if (-not (Test-Path $outFolder)) { New-Item -Path $outFolder -ItemType Directory -Force | Out-Null }
    }
    catch {
        $outFolder = Join-Path (Get-Location).Path "Aperture-CollectionPack-$((Get-Date).ToString('yyyyMMdd-HHmmss'))"
        if (-not (Test-Path $outFolder)) { New-Item -Path $outFolder -ItemType Directory -Force | Out-Null }
    }
}

# Start diagnostic transcript
try {
    $diagPath = Join-Path $outFolder 'diagnostic.log'
    Start-Transcript -Path $diagPath -Append -Force | Out-Null
} catch { }

# =========================================================
# KQL Query Loading
# =========================================================
# @@INJECT:KQL_QUERIES@@
$kqlQueries = @{}
$queriesDir = Join-Path $PSScriptRoot "queries"
if ($script:EmbeddedKqlQueries.Count -gt 0) { # count-safe: hashtable
    $kqlQueries = $script:EmbeddedKqlQueries
    Write-Host "Loaded $($kqlQueries.Count) embedded KQL queries" -ForegroundColor Gray
}
elseif (Test-Path $queriesDir) {
    Get-ChildItem -Path $queriesDir -Filter "*.kql" | ForEach-Object {
        $varName = $_.BaseName
        $kqlQueries[$varName] = Get-Content $_.FullName -Raw
    }
    Write-Host "Loaded $($kqlQueries.Count) KQL queries from queries/" -ForegroundColor Gray
}
else {
    Write-Host "  [WARN] queries/ directory not found -- KQL queries will be skipped" -ForegroundColor Yellow
    $SkipLogAnalyticsQueries = $true
}

# =========================================================
# Log Analytics Query Function
# =========================================================
function Invoke-LaQuery {
    param(
        [string]$WorkspaceResourceId,
        [string]$Label,
        [string]$Query,
        [datetime]$StartTime,
        [datetime]$EndTime
    )

    if (-not $WorkspaceResourceId -or ($WorkspaceResourceId -split '/').Count -lt 9) {
        return [PSCustomObject]@{
            WorkspaceResourceId = $WorkspaceResourceId
            Label               = $Label
            QueryName           = "Meta"
            Status              = "InvalidWorkspaceId"
            Error               = "Workspace resource ID is missing or malformed."
            RowCount            = 0
        }
    }

    $parts = $WorkspaceResourceId.TrimEnd('/') -split '/'
    $resourceGroupName = $parts[4]
    $workspaceName     = $parts[8]

    if (-not $resourceGroupName -or -not $workspaceName) {
        return [PSCustomObject]@{
            WorkspaceResourceId = $WorkspaceResourceId
            Label               = $Label
            QueryName           = "Meta"
            Status              = "InvalidWorkspaceId"
            Error               = "Could not extract RG or workspace name from workspace resource ID"
            RowCount            = 0
        }
    }

    try {
        $workspace = Get-AzOperationalInsightsWorkspace `
            -ResourceGroupName $resourceGroupName `
            -Name $workspaceName `
            -ErrorAction Stop
    }
    catch {
        return [PSCustomObject]@{
            WorkspaceResourceId = $WorkspaceResourceId
            Label               = $Label
            QueryName           = "Meta"
            Status              = "WorkspaceNotFound"
            RowCount            = 0
        }
    }

    $duration = New-TimeSpan -Start $StartTime -End $EndTime

    try {
        $result = Invoke-AzOperationalInsightsQuery `
            -WorkspaceId $workspace.CustomerId `
            -Query $Query `
            -Timespan $duration `
            -ErrorAction Stop
    }
    catch {
        return [PSCustomObject]@{
            WorkspaceResourceId = $WorkspaceResourceId
            Label               = $Label
            QueryName           = "Meta"
            Status              = "QueryFailed"
            Error               = $_.Exception.Message
            RowCount            = 0
        }
    }

    if (-not $result.Results -or @($result.Results).Count -eq 0) {
        return [PSCustomObject]@{
            WorkspaceResourceId = $WorkspaceResourceId
            Label               = $Label
            QueryName           = "Meta"
            Status              = "NoRowsReturned"
            RowCount            = 0
        }
    }

    $output = [System.Collections.Generic.List[object]]::new()
    foreach ($row in $result.Results) {
        $o = [PSCustomObject]@{
            WorkspaceResourceId = $WorkspaceResourceId
            Label               = $Label
            QueryName           = "AVD"
        }
        foreach ($p in $row.PSObject.Properties) {
            Add-Member -InputObject $o -NotePropertyName $p.Name -NotePropertyValue $p.Value -Force
        }
        $output.Add($o)
    }

    return $output
}

# =========================================================
# Scaling Plan Collection Functions
# =========================================================
function Expand-ScalingPlanEvidence {
    param([object]$PlanResource, [string]$SubId)

    if (-not $PlanResource) { return }

    $planId = if ($PlanResource.PSObject.Properties.Name -contains 'ResourceId') { $PlanResource.ResourceId } else { Get-ArmIdSafe $PlanResource }
    $rg     = $PlanResource.ResourceGroupName
    $name   = $PlanResource.Name
    $loc    = $PlanResource.Location
    $props  = SafeProp $PlanResource 'Properties'

    $scalingPlans.Add([PSCustomObject]@{
        SubscriptionId  = Protect-SubscriptionId $SubId
        ResourceGroup   = Protect-ResourceGroup $rg
        ScalingPlanName = Protect-Value -Value $name -Prefix "SPlan" -Length 4
        Location        = $loc
        TimeZone        = SafeProp $props 'timeZone'
        HostPoolType    = SafeProp $props 'hostPoolType'
        Description     = $(if ($ScrubPII) { '[SCRUBBED]' } else { SafeProp $props 'description' })
        FriendlyName    = $(if ($ScrubPII) { '[SCRUBBED]' } else { SafeProp $props 'friendlyName' })
        ExclusionTag    = SafeProp $props 'exclusionTag'
        Id              = Protect-ArmId $planId
    })

    foreach ($hpr in SafeArray (SafeProp $props 'hostPoolReferences')) {
        $hpArmId = SafeProp $hpr 'hostPoolArmPath'
        $scalingPlanAssignments.Add([PSCustomObject]@{
            SubscriptionId      = Protect-SubscriptionId $SubId
            ResourceGroup       = Protect-ResourceGroup $rg
            ScalingPlanName     = Protect-Value -Value $name -Prefix "SPlan" -Length 4
            ScalingPlanId       = Protect-ArmId $planId
            HostPoolArmId       = Protect-ArmId $hpArmId
            HostPoolName        = Protect-HostPoolName (Get-NameFromArmId $hpArmId)
            IsEnabled           = SafeProp $hpr 'scalingPlanEnabled'
        })
    }

    foreach ($sch in SafeArray (SafeProp $props 'schedules')) {
        $scalingPlanSchedules.Add([PSCustomObject]@{
            SubscriptionId        = Protect-SubscriptionId $SubId
            ResourceGroup         = Protect-ResourceGroup $rg
            ScalingPlanName       = Protect-Value -Value $name -Prefix "SPlan" -Length 4
            ScalingPlanId         = Protect-ArmId $planId
            ScheduleName          = SafeProp $sch 'name'
            DaysOfWeek            = ((SafeArray (SafeProp $sch 'daysOfWeek')) -join ",")
            RampUpStartTime       = SafeProp $sch 'rampUpStartTime'
            PeakStartTime         = SafeProp $sch 'peakStartTime'
            RampDownStartTime     = SafeProp $sch 'rampDownStartTime'
            OffPeakStartTime      = SafeProp $sch 'offPeakStartTime'
            RampUpCapacity        = SafeProp $sch 'rampUpCapacityThresholdPct'
            RampUpMinHostsPct     = SafeProp $sch 'rampUpMinimumHostsPct'
            PeakLoadBalancing     = SafeProp $sch 'peakLoadBalancingAlgorithm'
            RampDownCapacity      = SafeProp $sch 'rampDownCapacityThresholdPct'
            RampDownMinHostsPct   = SafeProp $sch 'rampDownMinimumHostsPct'
            OffPeakLoadBalancing  = SafeProp $sch 'offPeakLoadBalancingAlgorithm'
            OffPeakMinHostsPct    = SafeProp $sch 'offPeakMinimumHostsPct'
            RampDownForceLogoff   = SafeProp $sch 'rampDownForceLogoffUsers'
            RampDownLogoffTimeout = SafeProp $sch 'rampDownWaitTimeMinutes'
            RampDownNotification  = $(if ($ScrubPII) { '[SCRUBBED]' } else { SafeProp $sch 'rampDownNotificationMessage' })
        })
    }
}

# =========================================================
# STEP 1: Collect ARM Resources
# =========================================================
Write-Host ""
if ($ScrubPII) {
    Write-Host "  [PII SCRUBBING ENABLED] identifiers will be anonymized" -ForegroundColor Magenta
    Write-Host ""
}

$subsProcessed = 0
$subsSkipped = @()

if ($script:isResume -and (Test-Checkpoint 'step1-arm')) {
    Write-Host "======================================================================" -ForegroundColor Cyan
    Write-Host "  Step 1: ARM Resources -- RESUMED (loading from checkpoint)" -ForegroundColor Yellow
    Write-Host "======================================================================" -ForegroundColor Cyan
    Write-Host ""
    Import-StepData -FileName 'host-pools.json' -Target $hostPools
    Import-StepData -FileName 'session-hosts.json' -Target $sessionHosts
    Import-StepData -FileName 'virtual-machines.json' -Target $vms
    Import-StepData -FileName 'vmss.json' -Target $vmss
    Import-StepData -FileName 'vmss-instances.json' -Target $vmssInstances
    Import-StepData -FileName 'app-groups.json' -Target $appGroups
    Import-StepData -FileName 'scaling-plans.json' -Target $scalingPlans
    Import-StepData -FileName 'scaling-plan-assignments.json' -Target $scalingPlanAssignments
    Import-StepData -FileName 'scaling-plan-schedules.json' -Target $scalingPlanSchedules
    Import-StepData -FileName 'capacity-reservation-groups.json' -Target $capacityReservationGroups
    # Reload raw VM IDs from checkpoint (these are the real ARM IDs, not scrubbed)
    $rawIdFile = Join-Path $outFolder '_raw-vm-ids.json'
    if (Test-Path $rawIdFile) {
        $rawIdData = Get-Content $rawIdFile -Raw | ConvertFrom-Json
        foreach ($id in @($rawIdData.RawVmIds)) { if ($id) { $rawVmIds.Add($id) } }
        foreach ($n in @($rawIdData.RawVmNames)) { if ($n) { try { $rawVmNames.Add($n) } catch { } } }
        Write-Host "    Loaded $(SafeCount $rawVmIds) raw VM IDs for metrics" -ForegroundColor Gray
    }
    else {
        # Fallback: try from VM data (will be scrubbed if PII was on)
        foreach ($v in $vms) {
            $vid = SafeProp $v 'VMId'
            if ($vid) { $rawVmIds.Add($vid) }
            $vn = SafeProp $v 'VMName'
            if ($vn) { try { $rawVmNames.Add($vn) } catch { } }
        }
    }
    Write-Host "  ARM data reloaded: $(SafeCount $hostPools) host pools, $(SafeCount $vms) VMs" -ForegroundColor Green
    Write-Host ""
}
else {
Write-Host "======================================================================" -ForegroundColor Cyan
Write-Host "  Step 1 of $(if ($SkipAzureMonitorMetrics) { '3' } else { '4' }): Collecting ARM Resources" -ForegroundColor Cyan
Write-Host "======================================================================" -ForegroundColor Cyan
Write-Host ""

foreach ($subId in $SubscriptionIds) {
    try {
        $subsProcessed++
        Write-Step -Step "Subscription $subsProcessed/$(SafeCount $SubscriptionIds)" -Message (Protect-SubscriptionId $subId)

        # Skip Set-AzContext if we already validated context for this subscription during auth
        if ($script:currentSubContext -ne $subId) {
            try {
                Invoke-WithRetry { Set-AzContext -SubscriptionId $subId -TenantId $TenantId -ErrorAction Stop | Out-Null }
                $script:currentSubContext = $subId
            }
            catch {
                $errMsg = $_.Exception.Message
                Write-Step -Step "Subscription" -Message "Cannot access $(Protect-SubscriptionId $subId)" -Status "Error"
                if ($errMsg -match 'interaction is required|multi-factor|MFA|conditional access') {
                    Write-Host "    Token expired or MFA required. Run: Connect-AzAccount -TenantId '$(Protect-TenantId $TenantId)'" -ForegroundColor Yellow
                } elseif ($errMsg -match 'not found|does not exist|invalid') {
                    Write-Host "    Subscription not found in tenant. Verify the subscription ID is correct." -ForegroundColor Yellow
                } else {
                    Write-Host "    $errMsg" -ForegroundColor Gray
                }
                $subsSkipped += $subId
                continue
            }
        }

        # -- Host Pools --
        Write-Step -Step "Host Pools" -Message "Enumerating..." -Status "Progress"

    # Layer 0: ARM REST API -- guaranteed JSON with 'id' field regardless of Az module version
    # This bypasses all Az.DesktopVirtualization object-mapping issues
    # REST objects are also used as the PRIMARY source for $hpObjs (host pool list)
    # because Get-AzWvdHostPool may return fewer objects on some module versions
    $hpRestLookup = @{}  # Name -> @{ Id = ...; ResourceGroup = ... }
    $hpRestObjs = @()    # Full REST-parsed objects (used as primary $hpObjs)
    try {
        $hpRestPath = "/subscriptions/$subId/providers/Microsoft.DesktopVirtualization/hostPools?api-version=2024-04-03"
        $hpRestResp = Invoke-AzRestMethod -Path $hpRestPath -Method GET -ErrorAction Stop
        if ($hpRestResp.StatusCode -eq 200) {
            $hpRestBody = $hpRestResp.Content | ConvertFrom-Json
            $hpRestItems = if ($hpRestBody.value) { @($hpRestBody.value) } else { @() }
            foreach ($hpRest in $hpRestItems) {
                $restId = $hpRest.id
                $restName = $hpRest.name
                if ($restId -and $restName) {
                    $restParts = $restId -split '/'
                    $restRg = if ($restParts.Count -ge 5) { $restParts[4] } else { $null }
                    $hpRestLookup[$restName] = @{ Id = $restId; ResourceGroup = $restRg }
                }
            }
            $hpRestObjs = $hpRestItems
            Write-Host "    ARM REST API: found $($hpRestLookup.Count) host pools with resource groups" -ForegroundColor Gray
        }
    } catch {
        Write-Host "    ARM REST API fallback unavailable: $($_.Exception.Message)" -ForegroundColor DarkGray
    }

    # Use REST objects as primary source (complete + reliable), cmdlet as fallback
    if ($hpRestObjs.Count -gt 0) {
        $hpObjs = $hpRestObjs
    } else {
        $hpObjs = Get-AzWvdHostPool -ErrorAction SilentlyContinue
    }
    if ((SafeCount $hpObjs) -eq 0) {
        Write-Step -Step "Host Pools" -Message "No host pools found in this subscription" -Status "Warn"
    }

    # -- Bulk VM Pre-Fetch (per RG) --
    # Collect unique RGs from host pools, batch-fetch VMs
    $hpResourceGroups = @()
    # Build a lookup for host pool ARM IDs via Get-AzResource (fallback if REST API is unavailable)
    $hpArmLookup = @{}
    if ($hpRestLookup.Count -eq 0) {
        try {
            $hpArmResources = @(Get-AzResource -ResourceType 'Microsoft.DesktopVirtualization/hostpools' -ErrorAction SilentlyContinue)
            foreach ($hpArm in $hpArmResources) {
                if ($hpArm.Name) { $hpArmLookup[$hpArm.Name] = $hpArm }
            }
        } catch {}
    }

    foreach ($hp in SafeArray $hpObjs) {
        $hpNameBulk = SafeArmProp $hp 'Name'
        if (-not $hpNameBulk) { $hpNameBulk = $hp.Name }
        # Layer 0: ARM REST lookup (most reliable)
        $rgName = $null
        if ($hpNameBulk -and $hpRestLookup.ContainsKey($hpNameBulk)) {
            $rgName = $hpRestLookup[$hpNameBulk].ResourceGroup
        }
        # Layer 1: Parse from cmdlet object Id
        if (-not $rgName) {
            $hpId = SafeArmProp $hp 'Id'
            if (-not $hpId) { $hpId = Get-ArmIdSafe $hp }
            if ($hpId) { $rgName = ($hpId -split '/')[4] }
        }
        # Layer 2: Direct ResourceGroupName property
        if (-not $rgName) { $rgName = SafeProp $hp 'ResourceGroupName' }
        # Layer 3: Get-AzResource cache
        if (-not $rgName -and $hpNameBulk -and $hpArmLookup.ContainsKey($hpNameBulk)) {
            $rgName = $hpArmLookup[$hpNameBulk].ResourceGroupName
        }
        if ($rgName -and $rgName -notin $hpResourceGroups) {
            $hpResourceGroups += $rgName
        }
        if ($rgName) { $avdResourceGroups["$subId|$rgName".ToLower()] = $true }
    }

    foreach ($bulkRg in $hpResourceGroups) {
        if (-not $vmCacheByRg.ContainsKey($bulkRg)) {
            try {
                Write-Step -Step "VM Cache" -Message "Bulk-fetching VMs in RG: $(Protect-ResourceGroup $bulkRg)" -Status "Progress"
                $rgVmModels = @(Get-AzVM -ResourceGroupName $bulkRg -ErrorAction SilentlyContinue)
                $rgVmStatuses = @(Get-AzVM -ResourceGroupName $bulkRg -Status -ErrorAction SilentlyContinue)

                $vmCacheByRg[$bulkRg] = @{}
                $vmStatusCacheByRg[$bulkRg] = @{}

                foreach ($v in $rgVmModels) {
                    $vmCacheByRg[$bulkRg][$v.Name] = $v
                    $vmCacheByName[$v.Name] = $v
                }
                foreach ($v in $rgVmStatuses) {
                    $vmStatusCacheByRg[$bulkRg][$v.Name] = $v
                }

                # Batch-fetch VM extensions -- Get-AzVM list mode doesn't populate .Extensions
                try {
                    $rgExtResources = @(Get-AzResource -ResourceType "Microsoft.Compute/virtualMachines/extensions" `
                        -ResourceGroupName $bulkRg -ExpandProperties -ErrorAction SilentlyContinue)
                    foreach ($er in $rgExtResources) {
                        if ($er.ResourceId -match '/virtualMachines/([^/]+)/extensions/') {
                            $extVmName = $matches[1]
                            $extType = $null
                            try { $extType = $er.Properties.type } catch {}
                            if (-not $extType) { $extType = ($er.Name -split '/', 2)[1] }
                            if ($extType) {
                                if (-not $vmExtCache.ContainsKey($extVmName)) { $vmExtCache[$extVmName] = [System.Collections.Generic.List[string]]::new() }
                                if ($extType -notin $vmExtCache[$extVmName]) { $vmExtCache[$extVmName].Add($extType) }
                            }
                        }
                    }
                } catch {}
            }
            catch {
                Write-Step -Step "VM Cache" -Message "Failed to pre-fetch RG $(Protect-ResourceGroup $bulkRg) -- $($_.Exception.Message)" -Status "Warn"
            }
        }
    }

    # -- Process Host Pools --
    foreach ($hp in SafeArray $hpObjs) {
        $hpName = SafeArmProp $hp 'Name'
        if (-not $hpName) { $hpName = $hp.Name }

        # -- Extract ARM Id and Resource Group --
        $hpId = ""
        $hpRg = ""

        # Layer 0: ARM REST lookup (most reliable -- raw JSON, no Az module mapping)
        if ($hpRestLookup.ContainsKey($hpName)) {
            $hpId = $hpRestLookup[$hpName].Id
            $hpRg = $hpRestLookup[$hpName].ResourceGroup
        }

        # Layer 1: Cmdlet Id property -- parse RG from ARM path
        if (-not $hpRg) {
            $cmdletId = SafeArmProp $hp 'Id'
            if (-not $cmdletId) { $cmdletId = Get-ArmIdSafe $hp }
            if ($cmdletId) {
                $hpId = $cmdletId
                $hpRg = ($cmdletId -split '/')[4]
            }
        }

        # Layer 2: Direct ResourceGroupName property
        if (-not $hpRg) { $hpRg = SafeProp $hp 'ResourceGroupName' }

        # Layer 3: Pre-cached Get-AzResource bulk lookup
        if (-not $hpRg -and $hpArmLookup.ContainsKey($hpName)) {
            $armObj = $hpArmLookup[$hpName]
            $hpRg = $armObj.ResourceGroupName
            if (-not $hpId -and $armObj.ResourceId) { $hpId = $armObj.ResourceId }
        }

        if (-not $hpRg) { $hpRg = "" }

        # Extract security-relevant RDP flags BEFORE PII scrubbing so they survive anonymization
        $rawRdpProperty = SafeArmProp $hp 'CustomRdpProperty'
        $rdpStr = if ($rawRdpProperty) { "$rawRdpProperty" } else { "" }

        $hostPools.Add([PSCustomObject]@{
            SubscriptionId       = Protect-SubscriptionId $subId
            ResourceGroup        = Protect-ResourceGroup $hpRg
            HostPoolName         = Protect-HostPoolName $hpName
            HostPoolType         = SafeArmProp $hp 'HostPoolType'
            LoadBalancer         = SafeArmProp $hp 'LoadBalancerType'
            MaxSessions          = SafeArmProp $hp 'MaxSessionLimit'
            StartVMOnConnect     = SafeArmProp $hp 'StartVMOnConnect'
            PreferredAppGroupType = SafeArmProp $hp 'PreferredAppGroupType'
            Location             = $hp.Location
            ValidationEnv        = SafeArmProp $hp 'ValidationEnvironment'
            CustomRdpProperty    = $(if ($ScrubPII) { '[SCRUBBED]' } else { $rawRdpProperty })
            ScreenCaptureProtection = [bool]($rdpStr -match 'screencaptureprotected:i:[12]')
            Watermarking         = [bool]($rdpStr -match 'watermarkingquality:i:[123]')
            SsoEnabled           = [bool]($rdpStr -match 'enablerdsaadauth:i:1')
            Id                   = Protect-ArmId $hpId
        })

        # Collect Scheduled Agent Updates config
        # Az.DesktopVirtualization v3.x: nested under $hp.AgentUpdate.Type
        # Az.DesktopVirtualization v4.x+: may flatten to $hp.AgentUpdateType directly
        $agentUpdate = SafeArmProp $hp 'AgentUpdate'
        if ($agentUpdate) {
            $hostPools[-1] | Add-Member -NotePropertyName AgentUpdateType -NotePropertyValue (SafeProp $agentUpdate 'Type') -Force
            $hostPools[-1] | Add-Member -NotePropertyName AgentUpdateTimeZone -NotePropertyValue (SafeProp $agentUpdate 'MaintenanceWindowTimeZone') -Force
            $mws = SafeProp $agentUpdate 'MaintenanceWindows'
            if ($mws) {
                $mwList = @(foreach ($mw in $mws) { [PSCustomObject]@{ DayOfWeek = SafeProp $mw 'DayOfWeek'; Hour = SafeProp $mw 'Hour' } })
                $hostPools[-1] | Add-Member -NotePropertyName AgentUpdateMaintWindows -NotePropertyValue $mwList -Force
            }
            $hostPools[-1] | Add-Member -NotePropertyName AgentUpdateLocalTime -NotePropertyValue (SafeProp $agentUpdate 'UseSessionHostLocalTime') -Force
        }
        # Flattened fallback -- newer module versions
        if (-not ($hostPools[-1].PSObject.Properties['AgentUpdateType'] -and $hostPools[-1].AgentUpdateType)) {
            $flatType = SafeArmProp $hp 'AgentUpdateType'
            if ($flatType) {
                $hostPools[-1] | Add-Member -NotePropertyName AgentUpdateType -NotePropertyValue $flatType -Force
                $flatTz = SafeArmProp $hp 'AgentUpdateMaintenanceWindowTimeZone'
                if ($flatTz) { $hostPools[-1] | Add-Member -NotePropertyName AgentUpdateTimeZone -NotePropertyValue $flatTz -Force }
                $flatWindows = SafeArmProp $hp 'AgentUpdateMaintenanceWindow'
                if ($flatWindows) { $hostPools[-1] | Add-Member -NotePropertyName AgentUpdateMaintWindows -NotePropertyValue $flatWindows -Force }
                $flatLocal = SafeArmProp $hp 'AgentUpdateUseSessionHostLocalTime'
                if ($null -ne $flatLocal) { $hostPools[-1] | Add-Member -NotePropertyName AgentUpdateLocalTime -NotePropertyValue $flatLocal -Force }
            }
        }

        # Keep raw HP ID for PE/diagnostic lookups (before scrubbing makes it unusable)
        $scrubHpName = Protect-HostPoolName $hpName
        $rawHostPoolIds[$scrubHpName] = $hpId

        # Session Hosts
        Write-Step -Step "Session Hosts" -Message (Protect-HostPoolName $hpName) -Status "Progress"
        $shObjs = @()
        if (-not $hpRg) {
            Write-Step -Step "Session Hosts" -Message "Skipped for $(Protect-HostPoolName $hpName) -- could not determine resource group" -Status "Warn"
        }
        else {
            try {
                $shObjs = @(Get-AzWvdSessionHost -ResourceGroupName $hpRg -HostPoolName $hpName -ErrorAction SilentlyContinue)
            }
            catch {
                Write-Step -Step "Session Hosts" -Message "Failed for $(Protect-HostPoolName $hpName) -- $($_.Exception.Message)" -Status "Warn"
            }
        }

        foreach ($sh in $shObjs) {
            $shName = SafeArmProp $sh 'Name'
            if (-not $shName) { $shName = $sh.Name }
            # Session host name format: hostpool/vmname.domain.com
            $shSimpleName = if ($shName -match '/') { ($shName -split '/')[-1] } else { $shName }
            $vmName = ($shSimpleName -split '\.')[0]

            $sessionHosts.Add([PSCustomObject]@{
                SubscriptionId    = Protect-SubscriptionId $subId
                ResourceGroup     = Protect-ResourceGroup $hpRg
                HostPoolName      = Protect-HostPoolName $hpName
                SessionHostName   = Protect-VMName $shSimpleName
                SessionHostArmName = Protect-ArmId $shName
                Status            = SafeArmProp $sh 'Status'
                AllowNewSession   = SafeArmProp $sh 'AllowNewSession'
                ActiveSessions    = SafeArmProp $sh 'Session'
                AssignedUser      = Protect-Username (SafeArmProp $sh 'AssignedUser')
                UpdateState       = SafeArmProp $sh 'UpdateState'
                LastHeartBeat     = SafeArmProp $sh 'LastHeartBeat'
            })

            # -- Resolve backing VM --
            $vm = $null
            $vmStatus = $null

            # Tier 1: Host pool's RG cache
            if ($vmCacheByRg.ContainsKey($hpRg) -and $vmCacheByRg[$hpRg].ContainsKey($vmName)) {
                $vm = $vmCacheByRg[$hpRg][$vmName]
                $vmStatus = if ($vmStatusCacheByRg.ContainsKey($hpRg)) { $vmStatusCacheByRg[$hpRg][$vmName] } else { $null }
            }
            # Tier 2: Cross-RG index
            elseif ($vmCacheByName.ContainsKey($vmName)) {
                $vm = $vmCacheByName[$vmName]
            }
            # Tier 3: On-demand discovery
            else {
                try {
                    $vmResource = Invoke-WithRetry { Get-AzResource -ResourceType "Microsoft.Compute/virtualMachines" -Name $vmName -ErrorAction SilentlyContinue | Select-Object -First 1 }
                    if ($vmResource) {
                        $discoveredRg = $vmResource.ResourceGroupName
                        if (-not $vmCacheByRg.ContainsKey($discoveredRg)) {
                            $rgVmModels = @(Get-AzVM -ResourceGroupName $discoveredRg -ErrorAction SilentlyContinue)
                            $rgVmStatuses = @(Get-AzVM -ResourceGroupName $discoveredRg -Status -ErrorAction SilentlyContinue)
                            $vmCacheByRg[$discoveredRg] = @{}
                            $vmStatusCacheByRg[$discoveredRg] = @{}
                            foreach ($v in $rgVmModels) {
                                $vmCacheByRg[$discoveredRg][$v.Name] = $v
                                $vmCacheByName[$v.Name] = $v
                            }
                            foreach ($v in $rgVmStatuses) {
                                $vmStatusCacheByRg[$discoveredRg][$v.Name] = $v
                            }
                            # Batch-fetch extensions for this newly discovered RG
                            try {
                                $rgExtResources = @(Get-AzResource -ResourceType "Microsoft.Compute/virtualMachines/extensions" `
                                    -ResourceGroupName $discoveredRg -ExpandProperties -ErrorAction SilentlyContinue)
                                foreach ($er in $rgExtResources) {
                                    if ($er.ResourceId -match '/virtualMachines/([^/]+)/extensions/') {
                                        $eVm = $matches[1]
                                        $eType = $null
                                        try { $eType = $er.Properties.type } catch {}
                                        if (-not $eType) { $eType = ($er.Name -split '/', 2)[1] }
                                        if ($eType) {
                                            if (-not $vmExtCache.ContainsKey($eVm)) { $vmExtCache[$eVm] = [System.Collections.Generic.List[string]]::new() }
                                            if ($eType -notin $vmExtCache[$eVm]) { $vmExtCache[$eVm].Add($eType) }
                                        }
                                    }
                                }
                            } catch {}
                        }
                        $vm = $vmCacheByRg[$discoveredRg][$vmName]
                        $vmStatus = $vmStatusCacheByRg[$discoveredRg][$vmName]
                    }
                }
                catch { }
            }

            if (-not $vm) { continue }

            # Power state resolution
            $power = "Unknown"
            if ($vmStatus) {
                $statuses = $null
                if ($vmStatus.PSObject.Properties.Name -contains 'Statuses') {
                    $statuses = $vmStatus.Statuses
                }
                elseif ($vmStatus.PSObject.Properties.Name -contains 'InstanceView') {
                    $iv = $vmStatus.InstanceView
                    if ($null -ne $iv -and $iv.PSObject.Properties.Name -contains 'Statuses') {
                        $statuses = $iv.Statuses
                    }
                }
                if ($statuses) {
                    $powerCode = ($statuses | Where-Object { $_.Code -like 'PowerState/*' } | Select-Object -First 1)
                    if ($powerCode) { $power = ($powerCode.Code -split '/')[-1] }
                }
                if ($power -eq "Unknown" -and $vmStatus.PSObject.Properties.Name -contains 'PowerState') {
                    $ps = $vmStatus.PowerState
                    if ($ps) { $power = $ps -replace 'VM ', '' }
                }
            }

            # Image reference
            $storageProfile = SafeProp $vm 'StorageProfile'
            $imgRef = if ($storageProfile) { SafeProp $storageProfile 'ImageReference' } else { $null }
            $imagePublisher = if ($imgRef) { SafeProp $imgRef 'Publisher' } else { $null }
            $imageOffer     = if ($imgRef) { SafeProp $imgRef 'Offer' } else { $null }
            $imageSku       = if ($imgRef) { SafeProp $imgRef 'Sku' } else { $null }
            $imageVersion   = if ($imgRef) { SafeProp $imgRef 'Version' } else { $null }
            $imageId        = if ($imgRef) { SafeProp $imgRef 'Id' } else { $null }
            $imageSource    = if ($imageId -and $imageId -match '/galleries/') { "ComputeGallery" }
                              elseif ($imageId -and $imageId -match '/images/') { "ManagedImage" }
                              elseif ($imagePublisher) { "Marketplace" }
                              else { "Custom" }

            # Security profile
            $secProfile   = $vm.SecurityProfile
            $securityType = if ($secProfile) { SafeProp $secProfile 'SecurityType' } else { $null }
            $uefiSettings = if ($secProfile) { SafeProp $secProfile 'UefiSettings' } else { $null }
            $secureBoot   = if ($uefiSettings) { SafeProp $uefiSettings 'SecureBootEnabled' } else { $null }
            $vtpm         = if ($uefiSettings) { SafeProp $uefiSettings 'VTpmEnabled' } else { $null }
            $hostEncryption = SafeProp $vm 'EncryptionAtHost'
            if ($null -eq $hostEncryption -and $secProfile) {
                $hostEncryption = SafeProp $secProfile 'EncryptionAtHost'
            }

            # OS disk
            $osDisk          = if ($storageProfile) { SafeProp $storageProfile 'OsDisk' } else { $null }
            $osManagedDisk   = if ($osDisk) { SafeProp $osDisk 'ManagedDisk' } else { $null }
            $osDiskType      = if ($osManagedDisk) { SafeProp $osManagedDisk 'StorageAccountType' } else { "Unknown" }
            $osDiskEphemeral = if ($osDisk -and (SafeProp $osDisk 'DiffDiskSettings')) { $true } else { $false }

            # Disk encryption type
            $osDiskName = if ($osDisk) { SafeProp $osDisk 'Name' } else { $null }
            $osDiskEncryptionType = $null
            $osDiskCreated = $null
            if ($osDiskName) {
                $vmRg = $vm.ResourceGroupName
                if (-not $vmRg) { $vmRg = $hpRg }
                $cacheKey = "$vmRg/$osDiskName"
                if ($script:diskEncCache.ContainsKey($cacheKey)) {
                    $osDiskEncryptionType = $script:diskEncCache[$cacheKey]
                    $osDiskCreated = $script:diskCreatedCache[$cacheKey]
                }
                else {
                    try {
                        $diskObj = Get-AzDisk -ResourceGroupName $vmRg -DiskName $osDiskName -ErrorAction SilentlyContinue
                        if ($diskObj -and $diskObj.Encryption) {
                            $osDiskEncryptionType = SafeProp $diskObj.Encryption 'Type'
                        }
                        $osDiskCreated = SafeProp $diskObj 'TimeCreated'
                        $script:diskEncCache[$cacheKey] = $osDiskEncryptionType
                        $script:diskCreatedCache[$cacheKey] = $osDiskCreated
                    }
                    catch {
                        $script:diskEncCache[$cacheKey] = $null
                        $script:diskCreatedCache[$cacheKey] = $null
                    }
                }
            }

            # NIC data
            $nicSubnetId   = $null
            $nicNsgId      = $null
            $nicPrivateIp  = $null
            $accelNetEnabled = $false
            $netProfile = SafeProp $vm 'NetworkProfile'
            $nicRefs = if ($netProfile) { SafeProp $netProfile 'NetworkInterfaces' } else { $null }
            if ($nicRefs -and @($nicRefs).Count -gt 0) {
                $nicId = SafeProp $nicRefs[0] 'Id'
                if ($nicId) {
                    $nicIdParts = $nicId -split '/'
                    $nicRg = if ($nicIdParts.Count -ge 5) { $nicIdParts[4] } else { $hpRg }
                    $nicName = $nicIdParts[-1]

                    if (-not $nicCacheByRg.ContainsKey($nicRg)) {
                        try {
                            $nics = @(Get-AzNetworkInterface -ResourceGroupName $nicRg -ErrorAction SilentlyContinue)
                            $nicCacheByRg[$nicRg] = @{}
                            foreach ($n in $nics) {
                                $nicCacheByRg[$nicRg][$n.Name] = $n
                            }
                        }
                        catch { $nicCacheByRg[$nicRg] = @{} }
                    }

                    $nic = $null
                    if ($nicCacheByRg[$nicRg].ContainsKey($nicName)) {
                        $nic = $nicCacheByRg[$nicRg][$nicName]
                    }

                    if ($nic) {
                        $ipConfig = $nic.IpConfigurations | Select-Object -First 1
                        if ($ipConfig) {
                            $ipSubnet = SafeProp $ipConfig 'Subnet'
                            $nicSubnetId  = if ($ipSubnet) { SafeProp $ipSubnet 'Id' } else { $null }
                            $nicPrivateIp = SafeProp $ipConfig 'PrivateIpAddress'
                        }
                        $nicNsgObj = SafeProp $nic 'NetworkSecurityGroup'
                        $nicNsgId = if ($nicNsgObj) { SafeProp $nicNsgObj 'Id' } else { $null }
                        $accelNetEnabled = if ($nic.EnableAcceleratedNetworking) { $true } else { $false }
                    }
                }
            }

            # Identity type
            $identityType = if ($vm.Identity) { SafeProp $vm.Identity 'Type' } else { $null }

            # VM Extensions -- consolidated from VM object + batch ARM cache
            $extensions = SafeArray $vm.Extensions
            if (-not $extensions -or @($extensions).Count -eq 0) {
                # Fallback: some Az.Compute versions expose extensions under .Resources
                if ($vm.PSObject.Properties.Name -contains 'Resources' -and $vm.Resources) {
                    $extensions = SafeArray $vm.Resources
                }
            }
            $extTypes = @($extensions | ForEach-Object {
                $t = SafeProp $_ 'VirtualMachineExtensionType'
                if (-not $t) { $t = SafeProp $_ 'Type' }
                if (-not $t) { $t = SafeProp $_ 'ExtensionType' }
                $t
            } | Where-Object { $_ })
            # Merge batch-fetched extension cache (most reliable for batch scenarios)
            if ($vmExtCache.ContainsKey($vmName)) {
                $extTypes = @($extTypes) + @($vmExtCache[$vmName])
                $extTypes = @($extTypes | Select-Object -Unique)
            }

            $hasAadExtension      = @($extTypes | Where-Object { $_ -match 'AADLoginForWindows|AADIntuneLogin|AADJ' }).Count -gt 0
            $hasAmaAgent          = @($extTypes | Where-Object { $_ -match 'AzureMonitorWindowsAgent|AzureMonitorLinuxAgent|AMA' }).Count -gt 0
            $hasMmaAgent          = @($extTypes | Where-Object { $_ -match 'MicrosoftMonitoringAgent|OmsAgentForLinux|MMA' }).Count -gt 0
            $hasEndpointProtection = @($extTypes | Where-Object { $_ -match 'MDE|EndpointSecurity|IaaSAntimalware|Antimalware|WindowsDefender' }).Count -gt 0
            $hasGuestConfig       = @($extTypes | Where-Object { $_ -match 'ConfigurationforWindows|ConfigurationforLinux|GuestConfig' }).Count -gt 0
            $hasDiskEncryption    = @($extTypes | Where-Object { $_ -match 'AzureDiskEncryption' }).Count -gt 0

            # License type
            $vmLicenseType = SafeProp $vm 'LicenseType'

            $hpRgForVm = if ($vm.ResourceGroupName) { $vm.ResourceGroupName } else { $hpRg }

            # Zones
            $zones = if ($vm.Zones) { ($vm.Zones -join ",") } else { "" }

            # Keep raw ARM ID and VM name for metrics/log analytics collection (before PII scrubbing)
            $rawId = Get-ArmIdSafe $vm
            if ($rawId) { $rawVmIds.Add($rawId) }
            try { if ($vm.Name) { $rawVmNames.Add($vm.Name) } } catch { }

            # Track raw subnet IDs for network topology (before PII scrubbing)
            if ($nicSubnetId) {
                if (-not $rawSubnetLookup.ContainsKey($nicSubnetId)) {
                    $rawSubnetLookup[$nicSubnetId] = @{ SubId = $subId; VmCount = 0; HostPools = @{} }
                }
                $rawSubnetLookup[$nicSubnetId].VmCount++
                if ($hpName) { $rawSubnetLookup[$nicSubnetId].HostPools[$hpName] = $true }
            }

            # Nerdio Manager detection: check VM tags for NMW_*, Nerdio_*, NerdioManager* (before scrubbing)
            $rawTags = SafeProp $vm 'Tags'
            if ($rawTags -and $rawTags -is [System.Collections.IDictionary]) {
                $nerdioTagKeys = @($rawTags.Keys | Where-Object { $_ -match '^(NMW_|Nerdio_|NerdioManager|nmw-)' })
                if ($nerdioTagKeys.Count -gt 0) {
                    if (-not $nerdioDetected) { $nerdioSignals.Add("VM tags: VMs have Nerdio management tags (NMW_*/Nerdio_*)") }
                    $nerdioDetected = $true
                    if ($hpName) { $nerdioManagedPools[$hpName] = $true }
                }
            }

            $vms.Add([PSCustomObject]@{
                SubscriptionId       = Protect-SubscriptionId $subId
                ResourceGroup        = Protect-ResourceGroup $hpRgForVm
                HostPoolName         = Protect-HostPoolName $hpName
                SessionHostName      = Protect-VMName $vmName
                VMName               = Protect-VMName $vm.Name
                VMId                 = Protect-ArmId $rawId
                VMSize               = $(if ($vm.HardwareProfile) { $vm.HardwareProfile.VmSize } else { 'Unknown' })
                Region               = $vm.Location
                Zones                = $zones
                OSDiskType           = $osDiskType
                OSDiskEphemeral      = $osDiskEphemeral
                DataDiskCount        = $(if ($storageProfile) { SafeCount (SafeProp $storageProfile 'DataDisks') } else { 0 })
                PowerState           = $power
                ImagePublisher       = $imagePublisher
                ImageOffer           = $imageOffer
                ImageSku             = $imageSku
                ImageVersion         = $imageVersion
                ImageId              = Protect-ArmId $imageId
                ImageSource          = $imageSource
                AccelNetEnabled      = $accelNetEnabled
                SubnetId             = Protect-SubnetId $nicSubnetId
                NsgId                = Protect-ArmId $nicNsgId
                PrivateIp            = Protect-IP $nicPrivateIp
                SecurityType         = $securityType
                SecureBoot           = $secureBoot
                VTpm                 = $vtpm
                HostEncryption       = $hostEncryption
                IdentityType         = $identityType
                HasAadExtension      = $hasAadExtension
                HasAmaAgent          = $hasAmaAgent
                HasMmaAgent          = $hasMmaAgent
                HasEndpointProtection = $hasEndpointProtection
                HasGuestConfig       = $hasGuestConfig
                HasDiskEncryption    = $hasDiskEncryption
                LicenseType          = $vmLicenseType
                OSDiskEncryptionType = $osDiskEncryptionType
                Tags                 = $(if ($ScrubPII) { $null } else { SafeProp $vm 'Tags' })
                TimeCreated          = SafeProp $vm 'TimeCreated'
                OSDiskCreated        = $osDiskCreated
            })
        }
    }

    # -- Application Groups --
    Write-Step -Step "App Groups" -Message "Enumerating..." -Status "Progress"
    try {
        $agObjs = Get-AzWvdApplicationGroup -ErrorAction SilentlyContinue
        foreach ($ag in SafeArray $agObjs) {
            $agName = SafeArmProp $ag 'Name'
            if (-not $agName) { $agName = $ag.Name }
            $agHpPath = SafeArmProp $ag 'HostPoolArmPath'
            $appGroups.Add([PSCustomObject]@{
                SubscriptionId = Protect-SubscriptionId $subId
                ResourceGroup  = Protect-ResourceGroup $(  $agId = SafeArmProp $ag 'Id'; if ($agId) { ($agId -split '/')[4] } else { '' }  )
                AppGroupName   = Protect-Value -Value $agName -Prefix "AppGrp" -Length 4
                AppGroupType   = SafeArmProp $ag 'ApplicationGroupType'
                HostPoolArmPath = Protect-ArmId $agHpPath
                HostPoolName   = Protect-HostPoolName (Get-NameFromArmId $agHpPath)
                FriendlyName   = $(if ($ScrubPII) { '[SCRUBBED]' } else { SafeArmProp $ag 'FriendlyName' })
                Description    = $(if ($ScrubPII) { '[SCRUBBED]' } else { SafeArmProp $ag 'Description' })
            })
        }
    }
    catch {
        Write-Step -Step "App Groups" -Message "Failed -- $($_.Exception.Message)" -Status "Warn"
    }

    # -- Scaling Plans --
    Write-Step -Step "Scaling Plans" -Message "Enumerating..." -Status "Progress"
    try {
        $spObjs = Invoke-WithRetry { Get-AzResource -ResourceType "Microsoft.DesktopVirtualization/scalingPlans" -ExpandProperties -ErrorAction SilentlyContinue }
        foreach ($sp in SafeArray $spObjs) {
            Expand-ScalingPlanEvidence -PlanResource $sp -SubId $subId
        }
    }
    catch {
        Write-Step -Step "Scaling Plans" -Message "Failed -- $($_.Exception.Message)" -Status "Warn"
    }

    # -- VM Scale Sets --
    Write-Step -Step "VMSS" -Message "Enumerating..." -Status "Progress"
    try {
        $vmssResources = Get-AzVmss -ErrorAction SilentlyContinue
        foreach ($vmssObj in SafeArray $vmssResources) {
            $vmssName = SafeProp $vmssObj 'Name'
            if (-not $vmssName) { continue }
            $vmssRg   = SafeProp $vmssObj 'ResourceGroupName'
            if (-not $vmssRg) { $vmssRg = "" }
            $vmssId   = Get-ArmIdSafe $vmssObj

            $vmss.Add([PSCustomObject]@{
                SubscriptionId = Protect-SubscriptionId $subId
                ResourceGroup  = Protect-ResourceGroup $vmssRg
                VMSSName       = Protect-Value -Value $vmssName -Prefix "VMSS" -Length 4
                VMSSId         = Protect-ArmId $vmssId
                VMSize         = $(if ($vmssObj.Sku) { $vmssObj.Sku.Name } else { 'Unknown' })
                Capacity       = $(if ($vmssObj.Sku) { $vmssObj.Sku.Capacity } else { 0 })
                Location       = $vmssObj.Location
                Zones          = if ($vmssObj.Zones) { ($vmssObj.Zones -join ",") } else { "" }
            })

            # VMSS Instances
            try {
                $vmssInstObjs = @(Get-AzVmssVM -ResourceGroupName $vmssRg -VMScaleSetName $vmssName -ErrorAction SilentlyContinue)
                foreach ($inst in $vmssInstObjs) {
                    $instId = $inst.InstanceId
                    $instPower = "Unknown"
                    try {
                        $instView = Invoke-WithRetry { Get-AzVmssVM -ResourceGroupName $vmssRg -VMScaleSetName $vmssName -InstanceId $instId -InstanceView -ErrorAction SilentlyContinue }
                        if ($instView -and $instView.Statuses) {
                            $pc = $instView.Statuses | Where-Object { $_.Code -like 'PowerState/*' } | Select-Object -First 1
                            if ($pc) { $instPower = ($pc.Code -split '/')[-1] }
                        }
                    }
                    catch { }

                    $vmssInstances.Add([PSCustomObject]@{
                        SubscriptionId = Protect-SubscriptionId $subId
                        ResourceGroup  = Protect-ResourceGroup $vmssRg
                        VMSSName       = Protect-Value -Value $vmssName -Prefix "VMSS" -Length 4
                        InstanceId     = $instId
                        Name           = Protect-VMName $inst.Name
                        VMSize         = if ($inst.Sku) { $inst.Sku.Name } elseif ($vmssObj.Sku) { $vmssObj.Sku.Name } else { 'Unknown' }
                        PowerState     = $instPower
                        Location       = $inst.Location
                        Zones          = if ($inst.Zones) { ($inst.Zones -join ",") } else { "" }
                    })
                }
            }
            catch {
                Write-Step -Step "VMSS Instances" -Message "Failed for $(Protect-Value -Value $vmssName -Prefix 'VMSS' -Length 4) -- $($_.Exception.Message)" -Status "Warn"
            }
        }
    }
    catch {
        Write-Step -Step "VMSS" -Message "Failed -- $($_.Exception.Message)" -Status "Warn"
    }

    # -- Capacity Reservation Groups (optional) --
    if ($IncludeCapacityReservations) {
        Write-Step -Step "Capacity Reservations" -Message "Enumerating..." -Status "Progress"
        try {
            $crApiUrl = "https://management.azure.com/subscriptions/$subId/providers/Microsoft.Compute/capacityReservationGroups?api-version=2024-03-01&`$expand=virtualMachines/`$ref"
            $crResp = Invoke-AzRestMethod -Uri $crApiUrl -Method GET -ErrorAction Stop
            if ($crResp.StatusCode -eq 200) {
                $crData = $crResp.Content | ConvertFrom-Json
                $crItems = @(SafeArray $crData.value)
                # Handle pagination
                $crNextLink = SafeProp $crData 'nextLink'
                while ($crNextLink) {
                    $crNlResp = Invoke-AzRestMethod -Uri $crNextLink -Method GET -ErrorAction Stop
                    if ($crNlResp.StatusCode -eq 200) {
                        $crNlData = $crNlResp.Content | ConvertFrom-Json
                        $crItems += @(SafeArray $crNlData.value)
                        $crNextLink = SafeProp $crNlData 'nextLink'
                    } else { $crNextLink = $null }
                }
                foreach ($crg in $crItems) {
                    $crgId   = SafeProp $crg 'id'
                    if (-not $crgId) { $crgId = SafeProp $crg 'Id' }
                    $crgName = SafeProp $crg 'name'
                    if (-not $crgName) { $crgName = SafeProp $crg 'Name' }
                    if (-not $crgId) { continue }

                    # Fetch individual reservations
                    try {
                        $crDetailUrl = "https://management.azure.com${crgId}/capacityReservations?api-version=2024-03-01"
                        $crDetailResp = Invoke-AzRestMethod -Uri $crDetailUrl -Method GET -ErrorAction Stop
                        if ($crDetailResp.StatusCode -eq 200) {
                            $crDetails = ($crDetailResp.Content | ConvertFrom-Json).value
                            foreach ($cr in SafeArray $crDetails) {
                                $crProps = $cr.properties
                                $vmRefs = @()
                                if ($crProps.PSObject.Properties.Name -contains 'virtualMachinesAssociated') {
                                    $vmRefs = @($crProps.virtualMachinesAssociated | ForEach-Object { $_.id })
                                }
                                $capacityReservationGroups.Add([PSCustomObject]@{
                                    SubscriptionId     = Protect-SubscriptionId $subId
                                    GroupName          = Protect-Value -Value $crgName -Prefix "CRG" -Length 4
                                    GroupId            = Protect-ArmId $crgId
                                    ReservationName    = Protect-Value -Value $cr.name -Prefix "CRes" -Length 4
                                    Location           = $cr.location
                                    Zones              = if ($cr.zones) { ($cr.zones -join ",") } else { "" }
                                    SKU                = if ($cr.sku) { $cr.sku.name } else { "" }
                                    AllocatedCapacity  = SafeProp $crProps 'capacity'
                                    ProvisioningState  = SafeProp $crProps 'provisioningState'
                                    ProvisioningTime   = SafeProp $crProps 'provisioningTime'
                                    UtilizedVMs        = $vmRefs.Count
                                    VMReferences       = $(if ($ScrubPII) { '[SCRUBBED]' } else { ($vmRefs -join ";") })
                                })
                            }
                        }
                    }
                    catch {
                        Write-Step -Step "CRG Detail" -Message "Failed for $(Protect-Value -Value $crgName -Prefix 'CRG' -Length 4)" -Status "Warn"
                    }
                }
            }
        }
        catch {
            Write-Step -Step "Capacity Reservations" -Message "Failed -- $($_.Exception.Message)" -Status "Warn"
        }
    }

    Write-Step -Step "Subscription $subsProcessed" -Message "Done -- $(SafeCount $vms) VMs so far" -Status "Done"

    }
    catch {
        Write-Step -Step "Subscription" -Message "Unexpected error processing $(Protect-SubscriptionId $subId): $($_.Exception.Message)" -Status "Error"
        Write-Host "    at line $($_.InvocationInfo.ScriptLineNumber)" -ForegroundColor Gray
        continue
    }
}

Write-Host ""
Write-Host "  ARM collection complete: $(SafeCount $hostPools) host pools, $(SafeCount $vms) VMs, $(SafeCount $sessionHosts) session hosts" -ForegroundColor Green
Write-Host ""

# =========================================================
# STEP 1b: Extended Data Collection (Cost, Network, Storage, etc.)
# =========================================================
# Build global AVD resource group map from collected data
foreach ($v in $vms) {
    $rawSubId = if ($ScrubPII) { $null } else { $v.SubscriptionId }
    $rawRg    = if ($ScrubPII) { $null } else { $v.ResourceGroup }
    if ($rawSubId -and $rawRg) { $avdResourceGroups["$rawSubId|$rawRg".ToLower()] = $true }
}
# Also ensure host pool RGs are tracked (already done during enumeration, but defensive)
foreach ($hp in $hostPools) {
    $hpSubId = if ($ScrubPII) { $null } else { $hp.SubscriptionId }
    $hpRg    = if ($ScrubPII) { $null } else { $hp.ResourceGroup }
    if ($hpSubId -and $hpRg) { $avdResourceGroups["$hpSubId|$hpRg".ToLower()] = $true }
}

$hasExtendedCollection = $IncludeCostData -or $IncludeNetworkTopology -or $IncludeStorageAnalysis -or $IncludeOrphanedResources -or $IncludeDiagnosticSettings -or $IncludeAlertRules -or $IncludeActivityLog -or $IncludePolicyAssignments -or $IncludeResourceTags -or $IncludeImageAnalysis

if ($hasExtendedCollection) {
    Write-Host "======================================================================" -ForegroundColor Cyan
    Write-Host "  Step 1b: Extended Data Collection" -ForegroundColor Cyan
    Write-Host "======================================================================" -ForegroundColor Cyan
    Write-Host ""

    # -- Resource Tags --
    if ($IncludeResourceTags) {
        Write-Host "  Collecting resource tags..." -ForegroundColor Gray
        foreach ($v in $vms) {
            $tags = SafeProp $v 'Tags'
            if ($tags -and -not $ScrubPII) {
                foreach ($key in $tags.PSObject.Properties.Name) {
                    $resourceTags.Add([PSCustomObject]@{
                        ResourceType  = "VirtualMachine"
                        ResourceName  = $v.VMName
                        ResourceGroup = $v.ResourceGroup
                        TagKey        = $key
                        TagValue      = $tags.$key
                    })
                }
            }
        }
        foreach ($hp in $hostPools) {
            $tags = SafeProp $hp 'Tags'
            if ($tags -and -not $ScrubPII) {
                foreach ($key in $tags.PSObject.Properties.Name) {
                    $resourceTags.Add([PSCustomObject]@{
                        ResourceType  = "HostPool"
                        ResourceName  = $hp.HostPoolName
                        ResourceGroup = $hp.ResourceGroup
                        TagKey        = $key
                        TagValue      = $tags.$key
                    })
                }
            }
        }
        Write-Host "  [OK] Tags: $(SafeCount $resourceTags) tag entries" -ForegroundColor Green
    }

    # Iterate per subscription for API-bound collections
    foreach ($subId in $SubscriptionIds) {
        if ($subId -in $subsSkipped) { continue }

        # Switch context
        if ($script:currentSubContext -ne $subId) {
            try {
                Invoke-WithRetry { Set-AzContext -SubscriptionId $subId -TenantId $TenantId -ErrorAction Stop | Out-Null }
                $script:currentSubContext = $subId
            }
            catch {
                Write-Step -Step "Extended" -Message "Cannot switch to $(Protect-SubscriptionId $subId) -- skipping" -Status "Warn"
                continue
            }
        }

        $subAvdRgs = @($avdResourceGroups.Keys | Where-Object { $_.StartsWith("$subId|".ToLower()) } | ForEach-Object { ($_ -split '\|', 2)[1] })
        if ($subAvdRgs.Count -eq 0) { continue }

        Write-Step -Step "Extended" -Message "Subscription $(Protect-SubscriptionId $subId) -- $($subAvdRgs.Count) AVD RGs" -Status "Progress"

        # -- Cost Management --
        if ($IncludeCostData) {
            try {
                Write-Host "    Querying Cost Management..." -ForegroundColor Gray
                $endDate = (Get-Date).ToString("yyyy-MM-dd")
                $startDate = (Get-Date).AddDays(-30).ToString("yyyy-MM-dd")

                # Test access first
                $testBody = @{
                    type = "Usage"
                    timeframe = "Custom"
                    timePeriod = @{ from = $startDate; to = $endDate }
                    dataset = @{
                        granularity = "None"
                        aggregation = @{ totalCost = @{ name = "Cost"; function = "Sum" } }
                    }
                } | ConvertTo-Json -Depth 10
                $testResp = Invoke-WithRetry { Invoke-AzRestMethod -Path "/subscriptions/$subId/providers/Microsoft.CostManagement/query?api-version=2023-11-01" -Method POST -Payload $testBody -ErrorAction Stop }
                
                if ($testResp.StatusCode -ne 200) {
                    $costAccessDenied.Add($subId)
                    Write-Host "    [WARN] Cost Management access denied (need Cost Management Reader)" -ForegroundColor Yellow
                } else {
                    $costAccessGranted.Add($subId)

                    # Per-VM cost query
                    $costBody = @{
                        type = "Usage"
                        timeframe = "Custom"
                        timePeriod = @{ from = $startDate; to = $endDate }
                        dataset = @{
                            granularity = "Daily"
                            aggregation = @{ totalCost = @{ name = "Cost"; function = "Sum" } }
                            grouping = @(
                                @{ type = "Dimension"; name = "ResourceId" },
                                @{ type = "Dimension"; name = "ResourceType" },
                                @{ type = "Dimension"; name = "MeterCategory" },
                                @{ type = "Dimension"; name = "PricingModel" }
                            )
                        }
                    } | ConvertTo-Json -Depth 10
                    $costPath = "/subscriptions/$subId/providers/Microsoft.CostManagement/query?api-version=2023-11-01"
                    $costResp = Invoke-WithRetry { Invoke-AzRestMethod -Path $costPath -Method POST -Payload $costBody -ErrorAction Stop }

                    if ($costResp.StatusCode -eq 200) {
                        $costResult = $costResp.Content | ConvertFrom-Json
                        $costProps = SafeProp $costResult 'properties'

                        # Build column index lookup from response (handles varying column order across billing types)
                        $colMap = @{}
                        foreach ($col in SafeArray (SafeProp $costProps 'columns')) {
                            $cn = SafeProp $col 'name'
                            if ($cn) { $colMap[$cn] = $colMap.Count }
                        }
                        # Determine indices with fallbacks for known column name variants
                        $iCost    = if ($colMap.ContainsKey('Cost')) { $colMap['Cost'] } elseif ($colMap.ContainsKey('PreTaxCost')) { $colMap['PreTaxCost'] } else { 0 }
                        $iDate    = if ($colMap.ContainsKey('UsageDate')) { $colMap['UsageDate'] } elseif ($colMap.ContainsKey('BillingMonth')) { $colMap['BillingMonth'] } else { 1 }
                        $iResId   = if ($colMap.ContainsKey('ResourceId')) { $colMap['ResourceId'] } else { 2 }
                        $iResType = if ($colMap.ContainsKey('ResourceType')) { $colMap['ResourceType'] } else { 3 }
                        $iMeter   = if ($colMap.ContainsKey('MeterCategory')) { $colMap['MeterCategory'] } else { 4 }
                        $iPricing = if ($colMap.ContainsKey('PricingModel')) { $colMap['PricingModel'] } else { 5 }

                        foreach ($row in SafeArray (SafeProp $costProps 'rows')) {
                            $costVal = $row[$iCost]; if ($costVal -is [array]) { $costVal = $costVal[0] }
                            $cost    = if ($null -ne $costVal) { [double]$costVal } else { 0.0 }
                            $date    = $row[$iDate]
                            $resId   = [string]$row[$iResId]
                            $resType = [string]$row[$iResType]
                            $meter   = if ($iMeter -lt (SafeCount $row)) { [string]$row[$iMeter] } else { '' }
                            $pricing = if ($iPricing -lt (SafeCount $row)) { [string]$row[$iPricing] } else { '' }

                            $resName = ($resId -split '/')[-1]
                            $actualCostData.Add([PSCustomObject]@{
                                SubscriptionId = Protect-SubscriptionId $subId
                                ResourceId     = Protect-ArmId $resId
                                ResourceName   = Protect-VMName $resName
                                ResourceType   = $resType
                                MeterCategory  = $meter
                                PricingModel   = $pricing
                                Date           = $date
                                Cost           = $cost
                                Currency       = "USD"
                            })

                            # Build per-VM monthly cost lookup
                            if ($resType -like "*virtualMachines*") {
                                if (-not $vmActualMonthlyCost.ContainsKey($resName)) { $vmActualMonthlyCost[$resName] = 0 }
                                $vmActualMonthlyCost[$resName] += $cost
                            }
                        }

                        # Handle pagination
                        $nextLink = SafeProp $costProps 'nextLink'
                        while ($nextLink) {
                            $nlResp = Invoke-AzRestMethod -Uri $nextLink -Method GET -ErrorAction Stop
                            if ($nlResp.StatusCode -eq 200) {
                                $nlResult = $nlResp.Content | ConvertFrom-Json
                                $nlProps = SafeProp $nlResult 'properties'
                                foreach ($row in SafeArray (SafeProp $nlProps 'rows')) {
                                    $costVal = $row[$iCost]; if ($costVal -is [array]) { $costVal = $costVal[0] }
                                    $cost    = if ($null -ne $costVal) { [double]$costVal } else { 0.0 }
                                    $date    = $row[$iDate]
                                    $resId   = [string]$row[$iResId]
                                    $resType = [string]$row[$iResType]
                                    $meter   = if ($iMeter -lt (SafeCount $row)) { [string]$row[$iMeter] } else { '' }
                                    $pricing = if ($iPricing -lt (SafeCount $row)) { [string]$row[$iPricing] } else { '' }
                                    $resName = ($resId -split '/')[-1]
                                    $actualCostData.Add([PSCustomObject]@{
                                        SubscriptionId = Protect-SubscriptionId $subId
                                        ResourceId     = Protect-ArmId $resId
                                        ResourceName   = Protect-VMName $resName
                                        ResourceType   = $resType
                                        MeterCategory  = $meter
                                        PricingModel   = $pricing
                                        Date           = $date
                                        Cost           = $cost
                                        Currency       = "USD"
                                    })
                                    if ($resType -like "*virtualMachines*") {
                                        if (-not $vmActualMonthlyCost.ContainsKey($resName)) { $vmActualMonthlyCost[$resName] = 0 }
                                        $vmActualMonthlyCost[$resName] += $cost
                                    }
                                }
                                $nextLink = SafeProp $nlProps 'nextLink'
                            } else { $nextLink = $null }
                        }
                    }

                    # Infrastructure costs -- non-VM resources in AVD RGs
                    foreach ($rgName in $subAvdRgs) {
                        try {
                            $infraBody = @{
                                type = "Usage"
                                timeframe = "Custom"
                                timePeriod = @{ from = $startDate; to = $endDate }
                                dataset = @{
                                    granularity = "None"
                                    aggregation = @{ totalCost = @{ name = "Cost"; function = "Sum" } }
                                    filter = @{
                                        dimensions = @{ name = "ResourceGroup"; operator = "In"; values = @($rgName) }
                                    }
                                    grouping = @(
                                        @{ type = "Dimension"; name = "ResourceType" },
                                        @{ type = "Dimension"; name = "MeterCategory" }
                                    )
                                }
                            } | ConvertTo-Json -Depth 10
                            $infraResp = Invoke-WithRetry { Invoke-AzRestMethod -Path $costPath -Method POST -Payload $infraBody -ErrorAction Stop }
                            if ($infraResp.StatusCode -eq 200) {
                                $infraResult = $infraResp.Content | ConvertFrom-Json
                                $infraProps = SafeProp $infraResult 'properties'

                                # Build column index lookup for infra query (different shape: no date column)
                                $iColMap = @{}
                                foreach ($col in SafeArray (SafeProp $infraProps 'columns')) {
                                    $cn = SafeProp $col 'name'
                                    if ($cn) { $iColMap[$cn] = $iColMap.Count }
                                }
                                $iiCost    = if ($iColMap.ContainsKey('Cost')) { $iColMap['Cost'] } elseif ($iColMap.ContainsKey('PreTaxCost')) { $iColMap['PreTaxCost'] } else { 0 }
                                $iiResType = if ($iColMap.ContainsKey('ResourceType')) { $iColMap['ResourceType'] } else { 1 }
                                $iiMeter   = if ($iColMap.ContainsKey('MeterCategory')) { $iColMap['MeterCategory'] } else { 2 }

                                foreach ($row in SafeArray (SafeProp $infraProps 'rows')) {
                                    $icVal = $row[$iiCost]; if ($icVal -is [array]) { $icVal = $icVal[0] }
                                    $infraCostData.Add([PSCustomObject]@{
                                        SubscriptionId  = Protect-SubscriptionId $subId
                                        ResourceGroup   = Protect-ResourceGroup $rgName
                                        ResourceType    = if ($iiResType -lt (SafeCount $row)) { [string]$row[$iiResType] } else { '' }
                                        MeterCategory   = if ($iiMeter -lt (SafeCount $row)) { [string]$row[$iiMeter] } else { '' }
                                        MonthlyEstimate = [math]::Round($(if ($null -ne $icVal) { [double]$icVal } else { 0.0 }), 2)
                                        Currency        = "USD"
                                    })
                                }
                                # Paginate infra cost
                                $infraNextLink = SafeProp $infraProps 'nextLink'
                                while ($infraNextLink) {
                                    $infraNlResp = Invoke-AzRestMethod -Uri $infraNextLink -Method GET -ErrorAction Stop
                                    if ($infraNlResp.StatusCode -eq 200) {
                                        $infraNlResult = $infraNlResp.Content | ConvertFrom-Json
                                        $infraNlProps = SafeProp $infraNlResult 'properties'
                                        foreach ($row in SafeArray (SafeProp $infraNlProps 'rows')) {
                                            $icVal = $row[$iiCost]; if ($icVal -is [array]) { $icVal = $icVal[0] }
                                            $infraCostData.Add([PSCustomObject]@{
                                                SubscriptionId  = Protect-SubscriptionId $subId
                                                ResourceGroup   = Protect-ResourceGroup $rgName
                                                ResourceType    = if ($iiResType -lt (SafeCount $row)) { [string]$row[$iiResType] } else { '' }
                                                MeterCategory   = if ($iiMeter -lt (SafeCount $row)) { [string]$row[$iiMeter] } else { '' }
                                                MonthlyEstimate = [math]::Round($(if ($null -ne $icVal) { [double]$icVal } else { 0.0 }), 2)
                                                Currency        = "USD"
                                            })
                                        }
                                        $infraNextLink = SafeProp $infraNlProps 'nextLink'
                                    } else { $infraNextLink = $null }
                                }
                            }
                        }
                        catch { Write-Verbose "    [WARN] Infra cost query failed for RG: $($_.Exception.Message)" }
                    }

                    Write-Host "    [OK] Cost data: $(SafeCount $actualCostData) entries, $(($vmActualMonthlyCost.Keys).Count) VMs with costs" -ForegroundColor Green
                }
            }
            catch {
                Write-Host "    [WARN] Cost Management query failed: $($_.Exception.Message)" -ForegroundColor Yellow
            }
        }

        # -- Network Topology --
        if ($IncludeNetworkTopology -and $script:hasAzNetwork) {
            Write-Host "    Collecting network topology..." -ForegroundColor Gray
            $vnetCache = @{}
            $rawNsgIds = @{}  # Track raw NSG IDs for evaluation (survives PII scrubbing)

            # Use raw subnet lookup built during VM collection (works with -ScrubPII)
            $uniqueSubnets = @{}
            foreach ($sId in $rawSubnetLookup.Keys) {
                $entry = $rawSubnetLookup[$sId]
                if ($entry.SubId -eq $subId) {
                    $uniqueSubnets[$sId] = @{ VmCount = $entry.VmCount; HostPools = $entry.HostPools }
                }
            }

            foreach ($subnetId in $uniqueSubnets.Keys) {
                try {
                    # Parse subnet ARM ID
                    $parts = $subnetId -split '/'
                    if ($parts.Count -lt 11) { continue }
                    $vnetRg     = $parts[4]
                    $vnetName   = $parts[8]
                    $subnetName = $parts[10]
                    $vnetKey    = "$vnetRg/$vnetName".ToLower()

                    if (-not $vnetCache.ContainsKey($vnetKey)) {
                        $vnet = Invoke-WithRetry { Get-AzVirtualNetwork -ResourceGroupName $vnetRg -Name $vnetName -ErrorAction SilentlyContinue }
                        $vnetCache[$vnetKey] = $vnet
                    }
                    $vnet = $vnetCache[$vnetKey]
                    if (-not $vnet) { continue }
                    $subnet = $vnet.Subnets | Where-Object { $_.Name -eq $subnetName } | Select-Object -First 1
                    if (-not $subnet) { continue }

                    $addrPrefix = ($subnet.AddressPrefix | Select-Object -First 1) ?? ""
                    $cidr = 0
                    if ($addrPrefix -match '/(\d+)$') { $cidr = [int]$matches[1] }
                    $totalIps = if ($cidr -gt 0) { [math]::Pow(2, 32 - $cidr) } else { 0 }
                    $usableIps = [math]::Max(0, $totalIps - 5)  # Azure reserves 5
                    $usedIps = (SafeCount (SafeProp $subnet 'IpConfigurations')) + 0
                    $availIps = [math]::Max(0, $usableIps - $usedIps)
                    $usagePct = if ($usableIps -gt 0) { [math]::Round(($usedIps / $usableIps) * 100, 1) } else { 0 }

                    $hasNsg    = [bool]$subnet.NetworkSecurityGroup
                    $nsgId     = if ($hasNsg) { $subnet.NetworkSecurityGroup.Id } else { "" }
                    $hasRt     = [bool]$subnet.RouteTable
                    $rtId      = if ($hasRt) { $subnet.RouteTable.Id } else { "" }
                    $hasNatGw  = [bool]$subnet.NatGateway
                    $natGwId   = if ($hasNatGw) { $subnet.NatGateway.Id } else { "" }

                    # Track raw NSG IDs for evaluation
                    if ($nsgId -and -not $rawNsgIds.ContainsKey($nsgId)) { $rawNsgIds[$nsgId] = $true }

                    # Subnet enrichment: private subnet detection, load balancer, public IP
                    $isPrivateSubnet = $false
                    $hasLoadBalancer = $false
                    $hasPublicIP     = $false

                    # Check IP configurations for load balancer and public IP associations
                    $ipConfigs = SafeArray (SafeProp $subnet 'IpConfigurations')
                    foreach ($ipCfg in $ipConfigs) {
                        $ipCfgId = SafeProp $ipCfg 'Id'
                        if ($ipCfgId -match '/loadBalancers/') { $hasLoadBalancer = $true }
                        if ($ipCfgId -match '/publicIPAddresses/') { $hasPublicIP = $true }
                    }

                    # A subnet is "private" if it has no NAT gateway, no public IP, and has an NSG or route table
                    # (i.e., no direct outbound internet path -- likely uses forced tunneling or private connectivity)
                    $isPrivateSubnet = (-not $hasNatGw -and -not $hasPublicIP -and ($hasRt -or $hasNsg))

                    # Host pools using this subnet (PII-scrubbed if needed)
                    $subnetHostPools = @($uniqueSubnets[$subnetId].HostPools.Keys | ForEach-Object { Protect-HostPoolName $_ })
                    $hostPoolsStr = ($subnetHostPools | Sort-Object) -join "; "

                    $subnetAnalysis.Add([PSCustomObject]@{
                        SubscriptionId   = Protect-SubscriptionId $subId
                        SubnetId         = Protect-SubnetId $subnetId
                        SubnetName       = Protect-SubnetName $subnetName
                        VNetName         = Protect-Value -Value $vnetName -Prefix "VNet" -Length 4
                        AddressPrefix    = $addrPrefix
                        CIDR             = $cidr
                        TotalIPs         = [int]$totalIps
                        UsableIPs        = [int]$usableIps
                        UsedIPs          = $usedIps
                        AvailableIPs     = [int]$availIps
                        UsagePct         = $usagePct
                        HasNSG           = $hasNsg
                        NsgId            = Protect-ArmId $nsgId
                        HasRouteTable    = $hasRt
                        RouteTableId     = Protect-ArmId $rtId
                        HasNatGateway    = $hasNatGw
                        NatGatewayId     = Protect-ArmId $natGwId
                        SessionHostVMs   = $uniqueSubnets[$subnetId].VmCount
                        HostPools        = $hostPoolsStr
                        IsPrivateSubnet  = $isPrivateSubnet
                        HasLoadBalancer  = $hasLoadBalancer
                        HasPublicIP      = $hasPublicIP
                    })
                }
                catch { Write-Verbose "    [WARN] Subnet analysis error: $($_.Exception.Message)" }
            }

            # VNet DNS and peering analysis
            foreach ($vnetKey in $vnetCache.Keys) {
                $vnet = $vnetCache[$vnetKey]
                if (-not $vnet) { continue }
                try {
                    $dhcpOpts = SafeProp $vnet 'DhcpOptions'
                    $dnsServers = @(if ($dhcpOpts) { SafeArray (SafeProp $dhcpOpts 'DnsServers') } else { @() })
                    $peerings = @(SafeArray (SafeProp $vnet 'VirtualNetworkPeerings'))
                    $disconnected = @($peerings | Where-Object { $_.PeeringState -ne 'Connected' })
                    $addrSpace = SafeProp $vnet 'AddressSpace'
                    $addrPrefixes = if ($addrSpace) { SafeProp $addrSpace 'AddressPrefixes' } else { @() }
                    $dnsType = if ((SafeCount $dnsServers) -gt 0) { 'Custom' } else { 'Azure Default' }
                    $vnetAnalysis.Add([PSCustomObject]@{
                        SubscriptionId     = Protect-SubscriptionId $subId
                        VNetName           = Protect-Value -Value $vnet.Name -Prefix "VNet" -Length 4
                        Location           = $vnet.Location
                        AddressSpace       = (($addrPrefixes) -join "; ")
                        DnsServers         = if ($ScrubPII) { "[SCRUBBED]" } else { ($dnsServers -join "; ") }
                        DnsType            = $dnsType
                        PeeringCount       = SafeCount $peerings
                        DisconnectedPeers  = SafeCount $disconnected
                        SubnetCount        = SafeCount (SafeProp $vnet 'Subnets')
                    })
                }
                catch { Write-Verbose "    [WARN] VNet analysis error for ${vnetKey}: $($_.Exception.Message)" }
            }

            # Private endpoint check per host pool
            foreach ($hp in $hostPools) {
                $rawHpId = $rawHostPoolIds[$hp.HostPoolName]
                if (-not $rawHpId) { continue }
                try {
                    $peConns = @(Invoke-WithRetry { Get-AzPrivateEndpointConnection -PrivateLinkResourceId $rawHpId -ErrorAction SilentlyContinue })
                    $privateEndpointFindings.Add([PSCustomObject]@{
                        HostPoolName     = $hp.HostPoolName
                        HasPrivateEndpoint = ($peConns.Count -gt 0)
                        EndpointCount    = $peConns.Count
                        Status           = if ($peConns.Count -gt 0) { $peConnState = SafeProp $peConns[0] 'PrivateLinkServiceConnectionState'; if ($peConnState) { SafeProp $peConnState 'Status' } else { 'Unknown' } } else { 'None' }
                    })
                }
                catch { Write-Verbose "    [WARN] Private endpoint check failed: $($_.Exception.Message)" }
            }

            # NSG rule evaluation
            $nsgCache = @{}
            foreach ($rawNsgId in $rawNsgIds.Keys) {
                if (-not $rawNsgId -or $rawNsgId -eq '') { continue }
                if ($nsgCache.ContainsKey($rawNsgId)) { continue }
                try {
                    $nsgParts = $rawNsgId -split '/'
                    if ($nsgParts.Count -lt 9) { continue }
                    $nsgRg   = $nsgParts[4]
                    $nsgName = $nsgParts[8]
                    $nsg = Invoke-WithRetry { Get-AzNetworkSecurityGroup -ResourceGroupName $nsgRg -Name $nsgName -ErrorAction SilentlyContinue }
                    $nsgCache[$rawNsgId] = $nsg
                    if ($nsg) {
                        foreach ($rule in (SafeArray $nsg.SecurityRules)) {
                            if ($rule.Direction -eq 'Inbound' -and $rule.Access -eq 'Allow') {
                                $destPorts = $rule.DestinationPortRange -join ','
                                $srcAddr   = $rule.SourceAddressPrefix -join ','
                                $isRisky   = ($destPorts -eq '*' -or $destPorts -match '3389|22') -and ($srcAddr -eq '*' -or $srcAddr -eq 'Internet')
                                if ($isRisky) {
                                    $nsgRuleFindings.Add([PSCustomObject]@{
                                        NsgName            = Protect-Value -Value $nsgName -Prefix "NSG" -Length 4
                                        RuleName           = $rule.Name
                                        Direction          = $rule.Direction
                                        Access             = $rule.Access
                                        Priority           = $rule.Priority
                                        DestinationPorts   = $destPorts
                                        SourceAddress      = if ($ScrubPII) { '[SCRUBBED]' } else { $srcAddr }
                                        Risk               = if ($destPorts -eq '*') { 'Critical' } else { 'High' }
                                    })
                                }
                            }
                        }
                    }
                }
                catch { Write-Verbose "    [WARN] NSG evaluation error: $($_.Exception.Message)" }
            }

            Write-Host "    [OK] Network: $(SafeCount $subnetAnalysis) subnets, $(SafeCount $vnetAnalysis) VNets, $(SafeCount $privateEndpointFindings) PE checks, $(SafeCount $nsgRuleFindings) risky NSG rules" -ForegroundColor Green
        }

        # -- Orphaned Resources --
        if ($IncludeOrphanedResources) {
            Write-Host "    Scanning for orphaned resources..." -ForegroundColor Gray
            foreach ($rgName in $subAvdRgs) {
                try {
                    # Unattached disks
                    $disks = @(Get-AzDisk -ResourceGroupName $rgName -ErrorAction SilentlyContinue)
                    foreach ($disk in $disks) {
                        if ($disk.DiskState -eq "Unattached") {
                            $diskSizeGB = $disk.DiskSizeGB
                            $estCost = [math]::Round($diskSizeGB * 0.04, 2) # rough estimate
                            $orphanedResources.Add([PSCustomObject]@{
                                SubscriptionId  = Protect-SubscriptionId $subId
                                ResourceType    = "ManagedDisk"
                                ResourceName    = Protect-Value -Value $disk.Name -Prefix "Disk" -Length 4
                                ResourceGroup   = Protect-ResourceGroup $rgName
                                Details         = "Unattached $(if ($disk.Sku) { $disk.Sku.Name } else { 'Unknown' }) disk, $($diskSizeGB) GB"
                                EstMonthlyCost  = $estCost
                                CreatedDate     = $disk.TimeCreated
                            })
                        }
                    }
                    # Unattached NICs
                    if ($script:hasAzNetwork) {
                        $nics = @(Get-AzNetworkInterface -ResourceGroupName $rgName -ErrorAction SilentlyContinue)
                        foreach ($nic in $nics) {
                            if (-not $nic.VirtualMachine -and -not $nic.PrivateEndpoint) {
                                $orphanedResources.Add([PSCustomObject]@{
                                    SubscriptionId  = Protect-SubscriptionId $subId
                                    ResourceType    = "NetworkInterface"
                                    ResourceName    = Protect-Value -Value $nic.Name -Prefix "NIC" -Length 4
                                    ResourceGroup   = Protect-ResourceGroup $rgName
                                    Details         = "Unattached NIC (no VM or private endpoint)"
                                    EstMonthlyCost  = 0
                                    CreatedDate     = $null
                                })
                            }
                        }
                        # Unassociated PIPs
                        $pips = @(Get-AzPublicIpAddress -ResourceGroupName $rgName -ErrorAction SilentlyContinue)
                        foreach ($pip in $pips) {
                            if (-not $pip.IpConfiguration) {
                                $orphanedResources.Add([PSCustomObject]@{
                                    SubscriptionId  = Protect-SubscriptionId $subId
                                    ResourceType    = "PublicIP"
                                    ResourceName    = Protect-Value -Value $pip.Name -Prefix "PIP" -Length 4
                                    ResourceGroup   = Protect-ResourceGroup $rgName
                                    Details         = "Unassociated PIP ($(if ($pip.Sku) { $pip.Sku.Name } else { 'Unknown' }), $($pip.PublicIpAllocationMethod))"
                                    EstMonthlyCost  = if ($pip.Sku -and $pip.Sku.Name -eq 'Standard') { 3.65 } else { 0 }
                                    CreatedDate     = $null
                                })
                            }
                        }
                    }
                }
                catch {
                    Write-Step -Step "Orphaned" -Message "Failed for $(Protect-ResourceGroup $rgName) -- $($_.Exception.Message)" -Status "Warn"
                }
            }
            Write-Host "    [OK] Orphaned resources: $(SafeCount $orphanedResources) found" -ForegroundColor Green
        }

        # -- FSLogix Storage Analysis --
        if ($IncludeStorageAnalysis -and $script:hasAzStorage) {
            Write-Host "    Collecting storage data..." -ForegroundColor Gray
            foreach ($rgName in $subAvdRgs) {
                try {
                    $storageAccounts = @(Get-AzStorageAccount -ResourceGroupName $rgName -ErrorAction SilentlyContinue)
                    foreach ($sa in $storageAccounts) {
                        try {
                            $ctx = $sa.Context
                            $shares = @(Get-AzStorageShare -Context $ctx -ErrorAction SilentlyContinue)
                            foreach ($share in $shares) {
                                $shareName = $share.Name
                                $usedBytes = 0
                                try {
                                    $shareUsage = Get-AzRmStorageShare -StorageAccount $sa -Name $shareName -GetShareUsage -ErrorAction SilentlyContinue
                                    $usedBytes = if ($shareUsage.ShareUsageBytes) { $shareUsage.ShareUsageBytes } else { 0 }
                                }
                                catch { Write-Verbose "    [WARN] Share usage query failed: $($_.Exception.Message)" }

                                $shareProps = SafeProp $share 'ShareProperties'
                    $quotaGB = if ($shareProps) { SafeProp $shareProps 'QuotaInGiB' } else { 0 }
                    if ($null -eq $quotaGB) { $quotaGB = 0 }
                                $usedGB = [math]::Round($usedBytes / 1GB, 2)
                                $usagePct = if ($quotaGB -gt 0) { [math]::Round(($usedGB / $quotaGB) * 100, 1) } else { 0 }

                                # Check for private endpoints
                                $hasPE = $false
                                try {
                                    $peConns = @(Get-AzPrivateEndpointConnection -PrivateLinkResourceId $sa.Id -ErrorAction SilentlyContinue)
                                    $hasPE = ($peConns.Count -gt 0)
                                }
                                catch { Write-Verbose "    [WARN] Storage PE check failed: $($_.Exception.Message)" }

                                $isFslogix = $shareName -match 'fslogix|profile|odfc|msix'

                                $entry = [PSCustomObject]@{
                                    SubscriptionId     = Protect-SubscriptionId $subId
                                    ResourceGroup      = Protect-ResourceGroup $rgName
                                    StorageAccountName = Protect-StorageAccountName $sa.StorageAccountName
                                    ShareName          = if ($ScrubPII) { Protect-Value -Value $shareName -Prefix "Share" -Length 4 } else { $shareName }
                                    SkuName            = $(if ($sa.Sku) { $sa.Sku.Name } else { 'Unknown' })
                                    Kind               = $sa.Kind
                                    AccessTier         = $sa.AccessTier
                                    QuotaGB            = $quotaGB
                                    UsedGB             = $usedGB
                                    UsagePct           = $usagePct
                                    HasPrivateEndpoint = $hasPE
                                    IsFSLogixLikely    = $isFslogix
                                    LargeFileShares    = ($sa.LargeFileSharesState -eq "Enabled")
                                    Location           = $sa.PrimaryLocation
                                }

                                $fslogixStorageAnalysis.Add($entry)
                                if ($isFslogix) { $fslogixShares.Add($entry) }
                            }
                        }
                        catch { Write-Verbose "    [WARN] Storage account error: $($_.Exception.Message)" }
                    }
                }
                catch {
                    Write-Step -Step "Storage" -Message "Failed for $(Protect-ResourceGroup $rgName) -- $($_.Exception.Message)" -Status "Warn"
                }
            }
            Write-Host "    [OK] Storage: $(SafeCount $fslogixStorageAnalysis) shares ($(SafeCount $fslogixShares) FSLogix)" -ForegroundColor Green
        }

        # -- Diagnostic Settings --
        if ($IncludeDiagnosticSettings) {
            Write-Host "    Collecting diagnostic settings..." -ForegroundColor Gray
            # Check host pools
            foreach ($hp in $hostPools) {
                $rawHpId = $rawHostPoolIds[$hp.HostPoolName]
                if (-not $rawHpId) { continue }
                try {
                    $diagUri = "${rawHpId}/providers/Microsoft.Insights/diagnosticSettings?api-version=2021-05-01-preview"
                    $diagResp = Invoke-AzRestMethod -Path $diagUri -Method GET -ErrorAction SilentlyContinue
                    $diagCount = 0
                    $workspaceTargets = @()
                    if ($diagResp.StatusCode -eq 200) {
                        $diagResult = ($diagResp.Content | ConvertFrom-Json).value
                        $diagCount = @($diagResult).Count
                        $workspaceTargets = @($diagResult | ForEach-Object {
                            $dProps = SafeProp $_ 'properties'
                            $wsId = if ($dProps) { SafeProp $dProps 'workspaceId' } else { $null }
                            if ($wsId) { Protect-ArmId $wsId }
                        } | Where-Object { $_ })
                    }
                    $diagnosticSettings.Add([PSCustomObject]@{
                        ResourceType    = "HostPool"
                        ResourceName    = $hp.HostPoolName
                        ResourceId      = Protect-ArmId $rawHpId
                        SettingsCount   = $diagCount
                        HasDiagnostics  = ($diagCount -gt 0)
                        WorkspaceTargets = ($workspaceTargets -join "; ")
                    })
                }
                catch { Write-Verbose "    [WARN] Diagnostic settings check failed: $($_.Exception.Message)" }
            }
            Write-Host "    [OK] Diagnostic settings: $(SafeCount $diagnosticSettings) resources checked" -ForegroundColor Green
        }

        # -- Alert Rules --
        if ($IncludeAlertRules) {
            Write-Host "    Collecting alert rules..." -ForegroundColor Gray
            # Query subscription-wide (alerts are often in monitoring RGs, not AVD RGs)
            try {
                $alertUri = "/subscriptions/$subId/providers/Microsoft.Insights/metricAlerts?api-version=2018-03-01"
                $alertResp = Invoke-AzRestMethod -Path $alertUri -Method GET -ErrorAction SilentlyContinue
                if ($alertResp.StatusCode -eq 200) {
                    $alertResult = ($alertResp.Content | ConvertFrom-Json).value
                    foreach ($alert in SafeArray $alertResult) {
                        $alertProps = SafeProp $alert 'properties'
                        $alertScopes = SafeProp $alertProps 'scopes'
                        $alertRg = if ($alert.id) { ($alert.id -split '/')[4] } else { '' }
                        $alertRules.Add([PSCustomObject]@{
                            SubscriptionId = Protect-SubscriptionId $subId
                            ResourceGroup  = Protect-ResourceGroup $alertRg
                            AlertName      = $alert.name
                            Severity       = SafeProp $alertProps 'severity'
                            Enabled        = SafeProp $alertProps 'enabled'
                            Description    = if ($ScrubPII) { '[SCRUBBED]' } else { SafeProp $alertProps 'description' }
                            TargetType     = if ($alertScopes) { ($alertScopes | ForEach-Object { ($_ -split '/')[-2] } | Select-Object -First 1) } else { 'Unknown' }
                        })
                    }
                }
            }
            catch { Write-Verbose "    [WARN] Metric alert rules query failed: $($_.Exception.Message)" }

            # Scheduled query rules (log alerts) -- also subscription-wide
            try {
                $sqrUri = "/subscriptions/$subId/providers/Microsoft.Insights/scheduledQueryRules?api-version=2023-03-15-preview"
                $sqrResp = Invoke-AzRestMethod -Path $sqrUri -Method GET -ErrorAction SilentlyContinue
                if ($sqrResp.StatusCode -eq 200) {
                    $sqrResult = ($sqrResp.Content | ConvertFrom-Json).value
                    foreach ($sqr in SafeArray $sqrResult) {
                        $sqrProps = SafeProp $sqr 'properties'
                        $sqrRg = if ($sqr.id) { ($sqr.id -split '/')[4] } else { '' }
                        $alertRules.Add([PSCustomObject]@{
                            SubscriptionId = Protect-SubscriptionId $subId
                            ResourceGroup  = Protect-ResourceGroup $sqrRg
                            AlertName      = $sqr.name
                            Severity       = SafeProp $sqrProps 'severity'
                            Enabled        = SafeProp $sqrProps 'enabled'
                            Description    = if ($ScrubPII) { '[SCRUBBED]' } else { SafeProp $sqrProps 'description' }
                            TargetType     = "ScheduledQueryRule"
                        })
                    }
                }
            }
            catch { Write-Verbose "    [WARN] Scheduled query rules query failed: $($_.Exception.Message)" }

            # Also check subscription-level Activity Log alerts (Service Health alerts live here)
            try {
                $alaUri = "/subscriptions/$subId/providers/Microsoft.Insights/activityLogAlerts?api-version=2020-10-01"
                $alaResp = Invoke-AzRestMethod -Path $alaUri -Method GET -ErrorAction SilentlyContinue
                if ($alaResp.StatusCode -eq 200) {
                    $alaResult = ($alaResp.Content | ConvertFrom-Json).value
                    foreach ($ala in SafeArray $alaResult) {
                        $alaProps = SafeProp $ala 'properties'
                        $alaEnabled = SafeProp $alaProps 'enabled'
                        $alaDesc = SafeProp $alaProps 'description'
                        $alaCondition = SafeProp $alaProps 'condition'
                        $alaAllOf = if ($alaCondition) { SafeProp $alaCondition 'allOf' } else { @() }

                        # Determine if this is a Service Health alert and extract covered services
                        $isServiceHealth = $false
                        $coveredServices = @()
                        foreach ($clause in SafeArray $alaAllOf) {
                            $field = SafeProp $clause 'field'
                            $equals = SafeProp $clause 'equals'
                            $containsAny = SafeProp $clause 'containsAny'
                            if ($field -eq 'category' -and $equals -eq 'ServiceHealth') {
                                $isServiceHealth = $true
                            }
                            if ($field -like '*impactedServices*' -or $field -like '*ServiceName*') {
                                if ($containsAny) { $coveredServices += @($containsAny) }
                                elseif ($equals) { $coveredServices += $equals }
                            }
                        }

                        $alertRules.Add([PSCustomObject]@{
                            SubscriptionId  = Protect-SubscriptionId $subId
                            ResourceGroup   = if ($ala.id) { Protect-ResourceGroup (($ala.id -split '/')[4]) } else { '' }
                            AlertName       = $ala.name
                            Severity        = 'Sev4'
                            Enabled         = $alaEnabled
                            Description     = if ($ScrubPII) { '[SCRUBBED]' } else { $alaDesc }
                            TargetType      = if ($isServiceHealth) { 'ServiceHealth' } else { 'ActivityLogAlert' }
                            ServicesCovered = ($coveredServices -join ', ')
                        })
                    }
                }
            }
            catch { Write-Verbose "    [WARN] Activity log alerts query failed: $($_.Exception.Message)" }

            # Collect fired alert instances (last 30 days)
            try {
                Write-Host "    Collecting alert history (last 30 days)..." -ForegroundColor Gray
                $ahUri = "/subscriptions/$subId/providers/Microsoft.AlertsManagement/alerts?api-version=2019-05-05-preview&timeRange=30d"
                $ahResp = Invoke-AzRestMethod -Path $ahUri -Method GET -ErrorAction SilentlyContinue
                if ($ahResp.StatusCode -eq 200) {
                    $ahResult = ($ahResp.Content | ConvertFrom-Json).value
                    foreach ($ah in SafeArray $ahResult) {
                        $ahProps = SafeProp $ah 'properties'
                        $ahEssentials = SafeProp $ahProps 'essentials'
                        $alertHistory.Add([PSCustomObject]@{
                            AlertId          = $ah.name
                            Severity         = SafeProp $ahEssentials 'severity'
                            SignalType       = SafeProp $ahEssentials 'signalType'
                            AlertState       = SafeProp $ahEssentials 'alertState'
                            MonitorCondition = SafeProp $ahEssentials 'monitorCondition'
                            TargetResource   = if ($ScrubPII) { '[SCRUBBED]' } else { SafeProp $ahEssentials 'targetResource' }
                            TargetResourceType = SafeProp $ahEssentials 'targetResourceType'
                            MonitorService   = SafeProp $ahEssentials 'monitorService'
                            AlertRuleName    = SafeProp $ahEssentials 'alertRule'
                            StartDateTime    = SafeProp $ahEssentials 'startDateTime'
                            LastModifiedDateTime = SafeProp $ahEssentials 'lastModifiedDateTime'
                            MonitorConditionResolvedDateTime = SafeProp $ahEssentials 'monitorConditionResolvedDateTime'
                        })
                    }
                }
                Write-Host "    [OK] Alert history: $(SafeCount $alertHistory) fired alerts" -ForegroundColor Green
            }
            catch { Write-Verbose "    [WARN] Alert history query failed: $($_.Exception.Message)" }

            Write-Host "    [OK] Alert rules: $(SafeCount $alertRules) found" -ForegroundColor Green
        }

        # -- Activity Log --
        if ($IncludeActivityLog) {
            Write-Host "    Collecting activity log (last 7 days)..." -ForegroundColor Gray
            $actStart = (Get-Date).AddDays(-7)
            foreach ($rgName in $subAvdRgs) {
                try {
                    $logs = Get-AzActivityLog -ResourceGroupName $rgName -StartTime $actStart -ErrorAction SilentlyContinue -MaxRecord 200
                    foreach ($log in SafeArray $logs) {
                        $activityLogEntries.Add([PSCustomObject]@{
                            SubscriptionId  = Protect-SubscriptionId $subId
                            ResourceGroup   = Protect-ResourceGroup $rgName
                            Timestamp       = $log.EventTimestamp
                            Category        = SafeProp $log 'Category'
                            OperationName   = SafeProp $log 'OperationName'
                            Status          = SafeProp (SafeProp $log 'Status') 'Value'
                            Level           = SafeProp $log 'Level'
                            Caller          = if ($ScrubPII) { '[SCRUBBED]' } else { SafeProp $log 'Caller' }
                            ResourceId      = Protect-ArmId (SafeProp $log 'ResourceId')
                            Description     = if ($ScrubPII) { '[SCRUBBED]' } else { SafeProp (SafeProp $log 'Properties') 'statusMessage' }
                        })
                    }
                }
                catch {
                    Write-Step -Step "Activity Log" -Message "Failed for $(Protect-ResourceGroup $rgName) -- $($_.Exception.Message)" -Status "Warn"
                }
            }
            Write-Host "    [OK] Activity log: $(SafeCount $activityLogEntries) entries" -ForegroundColor Green
        }

        # -- Policy Assignments --
        if ($IncludePolicyAssignments) {
            Write-Host "    Collecting policy assignments..." -ForegroundColor Gray
            foreach ($rgName in $subAvdRgs) {
                try {
                    $policyUri = "/subscriptions/$subId/resourceGroups/$rgName/providers/Microsoft.Authorization/policyAssignments?api-version=2022-06-01"
                    $policyResp = Invoke-AzRestMethod -Path $policyUri -Method GET -ErrorAction SilentlyContinue
                    if ($policyResp.StatusCode -eq 200) {
                        $policyResult = ($policyResp.Content | ConvertFrom-Json).value
                        foreach ($pa in SafeArray $policyResult) {
                            $paProps = SafeProp $pa 'properties'
                            $policyAssignments.Add([PSCustomObject]@{
                                SubscriptionId    = Protect-SubscriptionId $subId
                                ResourceGroup     = Protect-ResourceGroup $rgName
                                AssignmentName    = $pa.name
                                DisplayName       = SafeProp $paProps 'displayName'
                                PolicyDefId       = SafeProp $paProps 'policyDefinitionId'
                                EnforcementMode   = SafeProp $paProps 'enforcementMode'
                                Scope             = Protect-ArmId (SafeProp $paProps 'scope')
                            })
                        }
                    }
                }
                catch { Write-Verbose "    [WARN] Policy query failed: $($_.Exception.Message)" }
            }
            Write-Host "    [OK] Policy assignments: $(SafeCount $policyAssignments) found" -ForegroundColor Green
        }
    } # end per-subscription extended collection

    # -- Image Analysis (post-loop, uses collected VM data) --
    if ($IncludeImageAnalysis) {
        Write-Host "  Collecting image version data..." -ForegroundColor Gray
        
        # Marketplace image freshness check
        $marketplaceSkus = @{}
        foreach ($v in $vms) {
            if ($v.ImageSource -eq 'Marketplace' -and $v.ImagePublisher -and $v.ImageOffer -and $v.ImageSku) {
                $key = "$($v.ImagePublisher)|$($v.ImageOffer)|$($v.ImageSku)"
                if (-not $marketplaceSkus.ContainsKey($key)) {
                    $marketplaceSkus[$key] = @{ Publisher = $v.ImagePublisher; Offer = $v.ImageOffer; Sku = $v.ImageSku; Count = 0 }
                }
                $marketplaceSkus[$key].Count++
            }
        }

        foreach ($key in $marketplaceSkus.Keys) {
            $info = $marketplaceSkus[$key]
            try {
                $firstMatchVm = $vms | Where-Object { $_.ImagePublisher -eq $info.Publisher -and $_.ImageOffer -eq $info.Offer } | Select-Object -First 1
                $queryLocation = if ($firstMatchVm) { SafeProp $firstMatchVm 'Region' } else { $null }
                if (-not $queryLocation) { $queryLocation = "eastus" }
                $latestImages = @(Invoke-WithRetry { Get-AzVMImage -Location $queryLocation -PublisherName $info.Publisher -Offer $info.Offer -Skus $info.Sku -ErrorAction SilentlyContinue } | Sort-Object -Property Version -Descending | Select-Object -First 5)
                $latestVersion = if ($latestImages.Count -gt 0) { $latestImages[0].Version } else { "Unknown" }
                $marketplaceImageDetails.Add([PSCustomObject]@{
                    Publisher      = $info.Publisher
                    Offer          = $info.Offer
                    Sku            = $info.Sku
                    LatestVersion  = $latestVersion
                    VersionCount   = $latestImages.Count
                    VMCount        = $info.Count # count-safe: custom hashtable property
                })
            }
            catch { Write-Verbose "    [WARN] Marketplace image query failed: $($_.Exception.Message)" }
        }

        # Gallery image analysis
        $galleryImages = @{}
        foreach ($v in $vms) {
            if ($v.ImageSource -eq 'ComputeGallery' -and $v.ImageId) {
                $rawImgId = if (-not $ScrubPII) { $v.ImageId } else { $null }
                if (-not $rawImgId) { continue }
                # Gallery image ID format: /subscriptions/.../galleries/xxx/images/yyy/versions/zzz
                $imgParts = $rawImgId -split '/'
                if ($imgParts.Count -ge 13) {
                    $galleryRg      = $imgParts[4]
                    $galleryName    = $imgParts[8]
                    $imgDefName     = $imgParts[10]
                    $galleryKey = "$galleryRg|$galleryName|$imgDefName"
                    if (-not $galleryImages.ContainsKey($galleryKey)) {
                        $galleryImages[$galleryKey] = @{ RG = $galleryRg; Gallery = $galleryName; ImageDef = $imgDefName; Count = 0 }
                    }
                    $galleryImages[$galleryKey].Count++
                }
            }
        }

        foreach ($key in $galleryImages.Keys) {
            $info = $galleryImages[$key]
            try {
                $versions = @(Get-AzGalleryImageVersion -ResourceGroupName $info.RG -GalleryName $info.Gallery -GalleryImageDefinitionName $info.ImageDef -ErrorAction SilentlyContinue)
                foreach ($ver in $versions) {
                    $galleryImageDetails.Add([PSCustomObject]@{
                        GalleryName = Protect-Value -Value $info.Gallery -Prefix "Gallery" -Length 4
                        ImageName   = Protect-Value -Value $info.ImageDef -Prefix "Image" -Length 4
                        Version     = $ver.Name
                        Location    = $ver.Location
                        ProvState   = SafeProp $ver 'ProvisioningState'
                        CreatedDate = SafeProp $ver 'PublishedDate'
                        EndOfLife   = SafeProp $ver 'EndOfLifeDate'
                        ReplicaCount = SafeCount (SafeProp (SafeProp $ver 'PublishingProfile') 'TargetRegions')
                    })
                }
                $galleryAnalysis.Add([PSCustomObject]@{
                    GalleryName    = Protect-Value -Value $info.Gallery -Prefix "Gallery" -Length 4
                    ImageName      = Protect-Value -Value $info.ImageDef -Prefix "Image" -Length 4
                    VersionCount   = $versions.Count
                    LatestVersion  = if ($versions.Count -gt 0) { ($versions | Sort-Object -Property Name -Descending | Select-Object -First 1).Name } else { "None" }
                    VMCount        = $info.Count # count-safe: custom hashtable property
                })
            }
            catch { Write-Verbose "    [WARN] Gallery image query failed: $($_.Exception.Message)" }
        }

        Write-Host "  [OK] Images: $(SafeCount $marketplaceImageDetails) marketplace SKUs, $(SafeCount $galleryAnalysis) gallery images" -ForegroundColor Green
    }

    Write-Host ""
    Write-Host "  Extended collection complete" -ForegroundColor Green
    Write-Host ""
} # end hasExtendedCollection

# -- Nerdio Manager Detection (additional signals from RG/HP naming) --
# Signal: Resource group naming -- Nerdio creates RGs with patterns like nmw-*, nerdio-*
$allCollectedRGs = @(($vms | ForEach-Object { SafeProp $_ 'ResourceGroup' } | Where-Object { $_ }) + ($hostPools | ForEach-Object { SafeProp $_ 'ResourceGroup' } | Where-Object { $_ })) | Select-Object -Unique
# When ScrubPII is active, RG names are hashed -- check raw RG names from avdResourceGroups keys instead
$nerdioRGNames = @()
if (-not $ScrubPII) {
    $nerdioRGNames = @($allCollectedRGs | Where-Object { $_ -match '^(nmw-|nerdio-)' })
} else {
    # avdResourceGroups keys are "SubId|RGName" with raw names
    $nerdioRGNames = @($avdResourceGroups.Keys | ForEach-Object { ($_ -split '\|', 2)[1] } | Where-Object { $_ -match '^(nmw-|nerdio-)' })
}
if ($nerdioRGNames.Count -gt 0) {
    $nerdioDetected = $true
    $nerdioSignals.Add("Resource groups: $($nerdioRGNames.Count) RG(s) match Nerdio naming pattern")
}

# Signal: Host pool naming -- contains nerdio/NMW/nmw- (uses raw names stored in $rawHostPoolIds values or keys)
# $rawHostPoolIds maps scrubbed HP name -> raw ARM ID, so we extract raw HP names from the ARM IDs
$rawHpNames = @($rawHostPoolIds.Values | ForEach-Object { if ($_) { ($_ -split '/')[-1] } } | Where-Object { $_ })
$nerdioNamedPools = @($rawHpNames | Where-Object { $_ -match 'nerdio|NMW|nmw-' })
if ($nerdioNamedPools.Count -gt 0) {
    $nerdioDetected = $true
    $nerdioSignals.Add("Host pool naming: $($nerdioNamedPools.Count) pool(s) reference Nerdio in name")
    foreach ($np in $nerdioNamedPools) { $nerdioManagedPools[$np] = $true }
}

# If Nerdio detected but no specific pools tagged, assume all pools are managed
if ($nerdioDetected -and $nerdioManagedPools.Count -eq 0) {
    foreach ($rawHpId in $rawHostPoolIds.Values) {
        if ($rawHpId) { $nerdioManagedPools[($rawHpId -split '/')[-1]] = $true }
    }
}

# Export nerdio-state.json (uses scrubbed pool names so EP can match)
$nerdioExportPools = @($nerdioManagedPools.Keys | ForEach-Object { Protect-HostPoolName $_ })
$nerdioState = @{
    Detected     = $nerdioDetected
    Signals      = @($nerdioSignals)
    ManagedPools = $nerdioExportPools
}
$nerdioState | ConvertTo-Json -Depth 3 -Compress | Out-File -FilePath (Join-Path $outFolder 'nerdio-state.json') -Encoding UTF8
if ($nerdioDetected) {
    Write-Host "  Nerdio Manager detected -- $($nerdioExportPools.Count) managed pool(s)" -ForegroundColor Cyan
}

# Save Step 1 checkpoint + incremental data
Export-PackJson -FileName 'host-pools.json' -Data $hostPools
Export-PackJson -FileName 'session-hosts.json' -Data $sessionHosts
Export-PackJson -FileName 'virtual-machines.json' -Data $vms
Export-PackJson -FileName 'vmss.json' -Data $vmss
Export-PackJson -FileName 'vmss-instances.json' -Data $vmssInstances
Export-PackJson -FileName 'app-groups.json' -Data $appGroups
Export-PackJson -FileName 'scaling-plans.json' -Data $scalingPlans
Export-PackJson -FileName 'scaling-plan-assignments.json' -Data $scalingPlanAssignments
Export-PackJson -FileName 'scaling-plan-schedules.json' -Data $scalingPlanSchedules
if ($IncludeCapacityReservations) {
    Export-PackJson -FileName 'capacity-reservation-groups.json' -Data $capacityReservationGroups
}
# Save raw VM identifiers for metrics resume (not included in final pack)
@{ RawVmIds = @($rawVmIds); RawVmNames = @($rawVmNames) } | ConvertTo-Json -Depth 3 -Compress | Out-File -FilePath (Join-Path $outFolder '_raw-vm-ids.json') -Encoding UTF8
Save-Checkpoint 'step1-arm'
Write-Host "  [CHECKPOINT] Step 1 saved -- safe to resume from: $outFolder" -ForegroundColor DarkGray
Write-Host ""

} # end if/else resume step 1

# =========================================================
# STEP 2: Collect Azure Monitor Metrics
# =========================================================
if ($script:isResume -and (Test-Checkpoint 'step2-metrics')) {
    Write-Host "======================================================================" -ForegroundColor Cyan
    Write-Host "  Step 2: Azure Monitor Metrics -- RESUMED (loading from checkpoint)" -ForegroundColor Yellow
    Write-Host "======================================================================" -ForegroundColor Cyan
    Write-Host ""
    Import-StepData -FileName 'metrics-baseline.json' -Target $vmMetrics
    Import-StepData -FileName 'metrics-incident.json' -Target $vmMetricsIncident
    Write-Host "  Metrics reloaded: $(SafeCount $vmMetrics) datapoints" -ForegroundColor Green
    Write-Host ""
}
elseif ($SkipAzureMonitorMetrics) {
    Write-Host "======================================================================" -ForegroundColor Cyan
    Write-Host "  Step 2: Azure Monitor Metrics -- SKIPPED" -ForegroundColor Yellow
    Write-Host "======================================================================" -ForegroundColor Cyan
    Write-Host ""
}
else {
    $totalSteps = if ($SkipLogAnalyticsQueries) { 3 } else { 4 }
    Write-Host "======================================================================" -ForegroundColor Cyan
    Write-Host "  Step 2 of $totalSteps`: Collecting Azure Monitor Metrics" -ForegroundColor Cyan
    Write-Host "======================================================================" -ForegroundColor Cyan
    Write-Host ""

    # Normalize VM IDs: remove empty/whitespace entries and deduplicate
    $vmIds = @($rawVmIds | ForEach-Object { $_.ToString().Trim() } | Where-Object { $_ -ne '' } | Select-Object -Unique)
    $metricsEnd   = Get-Date
    $metricsStart = $metricsEnd.AddDays(-$MetricsLookbackDays)
    $grain = [TimeSpan]::FromMinutes($MetricsTimeGrainMinutes)

    Write-Host "  Collecting metrics for $(SafeCount $vmIds) VMs ($MetricsLookbackDays-day lookback, ${MetricsTimeGrainMinutes}m grain)" -ForegroundColor Gray
    Write-Host ""

    $metricsProcessed = [ref]0
    $metricsTotal = SafeCount $vmIds

    # Build display-safe labels for parallel runspace (Protect-* unavailable in -Parallel)
    $vmIdLabels = @{}
    foreach ($vid in $vmIds) {
        $vmIdLabels[$vid] = if ($ScrubPII) {
            $parts = $vid -split '/'
            $vmName = $parts[-1]
            $hash = [System.Security.Cryptography.SHA256]::Create().ComputeHash(
                [System.Text.Encoding]::UTF8.GetBytes($vmName)
            )
            "VM-" + [BitConverter]::ToString($hash[0..1]).Replace('-','')
        } else { $vid }
    }

    # Batch VMs to limit peak memory (large environments can produce millions of metric data points)
    $metricsBatchSize = 100
    for ($bIdx = 0; $bIdx -lt $vmIds.Count; $bIdx += $metricsBatchSize) {
        $bEnd = [Math]::Min($bIdx + $metricsBatchSize - 1, $vmIds.Count - 1)
        $vmBatch = $vmIds[$bIdx..$bEnd]
        $batchBag = [System.Collections.Concurrent.ConcurrentBag[object]]::new()
        if ($vmIds.Count -gt $metricsBatchSize) {
            $batchNum = [Math]::Floor($bIdx / $metricsBatchSize) + 1
            $batchTotal = [Math]::Ceiling($vmIds.Count / $metricsBatchSize)
            Write-Host "    Batch $batchNum of $batchTotal ($(SafeCount $vmBatch) VMs)" -ForegroundColor Gray
        }

    $vmBatch | ForEach-Object -Parallel {
        $vmId = $_
        $start = $using:metricsStart
        $end   = $using:metricsEnd
        $grain = $using:grain
        $bag   = $using:batchBag
        $processed = $using:metricsProcessed
        $labels = $using:vmIdLabels

        # Primary metrics: CPU + Memory
        $metricNames = @("Percentage CPU", "Available Memory Bytes")
        $aggregations = @("Average", "Maximum")

        $attempt = 0
        $maxAttempts = 4
        $success = $false

        while ($attempt -lt $maxAttempts -and -not $success) {
            $attempt++
            Write-Host "    Querying metrics for $($labels[$vmId]) (attempt $attempt)" -ForegroundColor Gray
            try {
                # collect all aggregator results in one list
                $metricObjectsAll = [System.Collections.Generic.List[object]]::new()
                foreach ($aggType in $aggregations) {
                    $objs = Get-AzMetric `
                        -ResourceId $vmId `
                        -MetricName $metricNames `
                        -AggregationType $aggType `
                        -StartTime $start -EndTime $end -TimeGrain $grain `
                        -ErrorAction Stop
                    if ($objs) { $metricObjectsAll.AddRange($objs) }
                }

                if (-not $metricObjectsAll -or ($metricObjectsAll | Measure-Object).Count -eq 0) {
                    Write-Host "    Get-AzMetric returned no metric objects for $($labels[$vmId])" -ForegroundColor Yellow
                    try {
                        $res = Get-AzResource -ResourceId $vmId -ErrorAction SilentlyContinue
                        if ($res) { Write-Host "    Resource exists: $($res.ResourceType) $($labels[$vmId]) ($($res.Location))" -ForegroundColor Gray }
                        else { Write-Host "    Get-AzResource returned no resource for $($labels[$vmId])" -ForegroundColor Yellow }
                    } catch { Write-Host "    Failed to query resource metadata: $($_.Exception.Message)" -ForegroundColor Yellow }
                } else {
                    Write-Host "    Got metric types: $($metricObjectsAll.Count) for $($labels[$vmId])" -ForegroundColor Gray
                }

                foreach ($m in $metricObjectsAll) {
                    $mName = $m.Name.Value
                    foreach ($ts in $m.Timeseries) {
                        foreach ($pt in $ts.Data) {
                            if ($null -ne $pt.Average) {
                                $bag.Add([PSCustomObject]@{
                                    VmId        = $vmId
                                    Metric      = $mName
                                    Aggregation = 'Average'
                                    TimeStamp   = $pt.TimeStamp
                                    Value       = $pt.Average
                                })
                            }
                            if ($null -ne $pt.Maximum) {
                                $bag.Add([PSCustomObject]@{
                                    VmId        = $vmId
                                    Metric      = $mName
                                    Aggregation = 'Maximum'
                                    TimeStamp   = $pt.TimeStamp
                                    Value       = $pt.Maximum
                                })
                            }
                        }
                    }
                }
                $success = $true
            }
            catch {
                $msg = $_.Exception.Message
                Write-Host "    Get-AzMetric error for $($labels[$vmId]): ${msg}" -ForegroundColor Yellow
                if ($msg -match '429|throttl' -and $attempt -lt $maxAttempts) {
                    $backoff = @(15, 45, 135)[$attempt - 1]
                    Write-Host "    throttled, backing off ${backoff} seconds" -ForegroundColor Yellow
                    Start-Sleep -Seconds $backoff
                }
                # Non-throttle errors or final attempt: will retry until attempts exhausted
            }
        }

        # Secondary metrics: Disk (best-effort, no retry)
        try {
            $diskMetricNames = @("OS Disk IOPS Consumed Percentage", "OS Disk Queue Depth", "Data Disk IOPS Consumed Percentage")
            $diskMetrics = Get-AzMetric `
                -ResourceId $vmId `
                -MetricName $diskMetricNames `
                -Aggregation @("Average", "Maximum") `
                -StartTime $start -EndTime $end -TimeGrain $grain `
                -ErrorAction SilentlyContinue

            foreach ($m in @($diskMetrics)) {
                $mName = $m.Name.Value
                foreach ($ts in $m.Timeseries) {
                    foreach ($pt in $ts.Data) {
                        foreach ($agg in @("Average", "Maximum")) {
                            $value = $null
                            if ($agg -eq "Average" -and $null -ne $pt.Average) { $value = $pt.Average }
                            if ($agg -eq "Maximum" -and $null -ne $pt.Maximum) { $value = $pt.Maximum }
                            if ($null -ne $value) {
                                $bag.Add([PSCustomObject]@{
                                    VmId        = $vmId
                                    Metric      = $mName
                                    Aggregation = $agg
                                    TimeStamp   = $pt.TimeStamp
                                    Value       = $value
                                })
                            }
                        }
                    }
                }
            }
        }
        catch { }

        [System.Threading.Interlocked]::Increment($processed) | Out-Null
        # update progress bar in parallel runspaces
        try {
            $pct = if ($using:metricsTotal -gt 0) { [math]::Round(($processed.Value / $using:metricsTotal) * 100) } else { 0 }
            Write-Progress -Activity "Collecting Azure Monitor metrics" -Status "$($processed.Value)/$($using:metricsTotal) VMs" -PercentComplete $pct
        } catch { }

    } -ThrottleLimit $MetricsParallel

        # Flush batch results (scrub VmId if needed)
        foreach ($item in $batchBag) {
            if ($ScrubPII) { $item.VmId = Protect-ArmId $item.VmId }
            $vmMetrics.Add($item)
        }
        $batchBag = $null
        if ($bIdx + $metricsBatchSize -lt $vmIds.Count) { [System.GC]::Collect() }
    }

    Write-Host "  [OK] Metrics collected: $(SafeCount $vmMetrics) datapoints for $metricsTotal VMs" -ForegroundColor Green
    Write-Host ""

    # -- Incident Window Metrics (optional) --
    if ($IncludeIncidentWindow) {
        Write-Host "  Collecting incident window metrics ($IncidentWindowStart -> $IncidentWindowEnd)..." -ForegroundColor Cyan

        $incidentCollected = [System.Collections.Concurrent.ConcurrentBag[object]]::new()

        $vmIds | ForEach-Object -Parallel {
            $vmId = $_
            $start = $using:IncidentWindowStart
            $end   = $using:IncidentWindowEnd
            $grain = $using:grain
            $bag   = $using:incidentCollected

            try {
                $metricObjects = Get-AzMetric `
                    -ResourceId $vmId `
                    -MetricName @("Percentage CPU", "Available Memory Bytes") `
                    -Aggregation @("Average", "Maximum") `
                    -StartTime $start -EndTime $end -TimeGrain $grain `
                    -ErrorAction Stop

                foreach ($m in $metricObjects) {
                    $mName = $m.Name.Value
                    foreach ($ts in $m.Timeseries) {
                        foreach ($pt in $ts.Data) {
                            foreach ($agg in @("Average", "Maximum")) {
                                $value = $null
                                if ($agg -eq "Average" -and $null -ne $pt.Average) { $value = $pt.Average }
                                if ($agg -eq "Maximum" -and $null -ne $pt.Maximum) { $value = $pt.Maximum }
                                if ($null -ne $value) {
                                    $bag.Add([PSCustomObject]@{
                                        VmId        = $vmId
                                        Metric      = $mName
                                        Aggregation = $agg
                                        TimeStamp   = $pt.TimeStamp
                                        Value       = $value
                                    })
                                }
                            }
                        }
                    }
                }
            }
            catch {
                $errMsg = $_.Exception.Message
                if ($errMsg -notmatch 'ResourceNotFound|ResourceGroupNotFound') {
                    Write-Verbose "    [WARN] Incident metric error for VM: $errMsg"
                }
            }
        } -ThrottleLimit $MetricsParallel

        foreach ($item in $incidentCollected) {
            if ($ScrubPII) { $item.VmId = Protect-ArmId $item.VmId }
            $vmMetricsIncident.Add($item)
        }

        Write-Host "  [OK] Incident metrics: $(SafeCount $vmMetricsIncident) datapoints" -ForegroundColor Green
        Write-Host ""
    }

    # Save Step 2 checkpoint
    Export-PackJson -FileName 'metrics-baseline.json' -Data $vmMetrics
    if ($IncludeIncidentWindow) {
        Export-PackJson -FileName 'metrics-incident.json' -Data $vmMetricsIncident
    }
    Save-Checkpoint 'step2-metrics'
    Write-Host "  [CHECKPOINT] Step 2 saved -- safe to resume from: $outFolder" -ForegroundColor DarkGray
    Write-Host ""
}

# =========================================================
# STEP 3: Log Analytics (KQL) Queries
# =========================================================
if ($script:isResume -and (Test-Checkpoint 'step3-kql')) {
    Write-Host "======================================================================" -ForegroundColor Cyan
    Write-Host "  Step 3: KQL Queries -- RESUMED (loading from checkpoint)" -ForegroundColor Yellow
    Write-Host "======================================================================" -ForegroundColor Cyan
    Write-Host ""
    Import-StepData -FileName 'la-results.json' -Target $laResults
    Write-Host "  KQL data reloaded: $(SafeCount $laResults) results" -ForegroundColor Green
    Write-Host ""
}
elseif ($SkipLogAnalyticsQueries -or (SafeCount $LogAnalyticsWorkspaceResourceIds) -eq 0) {
    Write-Host "======================================================================" -ForegroundColor Cyan
    if ($SkipLogAnalyticsQueries) {
        Write-Host "  Step 3: Log Analytics Queries -- SKIPPED (-SkipLogAnalyticsQueries)" -ForegroundColor Yellow
    }
    else {
        Write-Host "  Step 3: Log Analytics Queries -- SKIPPED (no workspace IDs provided)" -ForegroundColor Yellow
    }
    Write-Host "======================================================================" -ForegroundColor Cyan
    Write-Host ""
}
else {
    $totalSteps = if ($SkipAzureMonitorMetrics) { 3 } else { 4 }
    $stepNum = if ($SkipAzureMonitorMetrics) { 2 } else { 3 }
    Write-Host "======================================================================" -ForegroundColor Cyan
    Write-Host "  Step $stepNum of $totalSteps`: Log Analytics Queries" -ForegroundColor Cyan
    Write-Host "======================================================================" -ForegroundColor Cyan
    Write-Host ""
    # We'll initialize the progress bar after computing the total below once we know how many queries will run

    $queryStart = (Get-Date).AddDays(-$MetricsLookbackDays)
    $queryEnd   = Get-Date


    # Build query dispatch list
    $queryDispatchList = @(
        @{ Label = "CurrentWindow_TableDiscovery";          Query = $kqlQueries["kqlTableDiscovery"] },
        @{ Label = "CurrentWindow_WVDConnections";          Query = $kqlQueries["kqlWvdConnections"] },
        @{ Label = "CurrentWindow_WVDShortpathUsage";       Query = $kqlQueries["kqlShortpathUsage"] },
        @{ Label = "CurrentWindow_WVDPeakConcurrency";      Query = $kqlQueries["kqlPeakConcurrency"] },
        @{ Label = "CurrentWindow_WVDAutoscaleActivity";    Query = $kqlQueries["kqlAutoscaleActivity"] },
        @{ Label = "CurrentWindow_WVDAutoscaleDetailed";    Query = $kqlQueries["kqlAutoscaleDetailedActivity"] },
        @{ Label = "CurrentWindow_SessionDuration";         Query = $kqlQueries["kqlSessionDuration"] },
        @{ Label = "CurrentWindow_ProfileLoadPerformance";  Query = $kqlQueries["kqlProfileLoadPerformance"] },
        @{ Label = "CurrentWindow_ConnectionQuality";       Query = $kqlQueries["kqlConnectionQuality"] },
        @{ Label = "CurrentWindow_ConnectionQualityByRegion"; Query = $kqlQueries["kqlConnectionQualityByRegion"] },
        @{ Label = "CurrentWindow_ConnectionErrors";        Query = $kqlQueries["kqlConnectionErrors"] },
        @{ Label = "CurrentWindow_Disconnects";             Query = $kqlQueries["kqlDisconnects"] },
        @{ Label = "CurrentWindow_DisconnectReasons";       Query = $kqlQueries["kqlDisconnectReasons"] },
        @{ Label = "CurrentWindow_DisconnectsByHost";       Query = $kqlQueries["kqlDisconnectsByHost"] },
        @{ Label = "CurrentWindow_HourlyConcurrency";       Query = $kqlQueries["kqlHourlyConcurrency"] },
        @{ Label = "CurrentWindow_CrossRegionConnections";  Query = $kqlQueries["kqlCrossRegionConnections"] },
        @{ Label = "CurrentWindow_LoginTime";               Query = $kqlQueries["kqlLoginTime"] },
        @{ Label = "CurrentWindow_ConnectionSuccessRate";   Query = $kqlQueries["kqlConnectionSuccessRate"] },
        @{ Label = "CurrentWindow_ProcessCpu";              Query = $kqlQueries["kqlProcessCpu"] },
        @{ Label = "CurrentWindow_ProcessCpuSummary";       Query = $kqlQueries["kqlProcessCpuSummary"] },
        @{ Label = "CurrentWindow_ProcessMemory";           Query = $kqlQueries["kqlProcessMemory"] },
        @{ Label = "CurrentWindow_CpuPercentiles";          Query = $kqlQueries["kqlCpuPercentiles"] },
        @{ Label = "CurrentWindow_ReconnectionLoops";       Query = $kqlQueries["kqlReconnectionLoops"] },
        @{ Label = "CurrentWindow_DisconnectCpuCorrelation"; Query = $kqlQueries["kqlDisconnectCpuCorrelation"] },
        @{ Label = "CurrentWindow_ShortpathEffectiveness";  Query = $kqlQueries["kqlShortpathEffectiveness"] },
        @{ Label = "CurrentWindow_ShortpathByClient";       Query = $kqlQueries["kqlShortpathByClient"] },
        @{ Label = "CurrentWindow_ShortpathTransportRTT";   Query = $kqlQueries["kqlShortpathTransportRTT"] },
        @{ Label = "CurrentWindow_ShortpathByGateway";      Query = $kqlQueries["kqlShortpathByGateway"] },
        @{ Label = "CurrentWindow_MultiLinkTransport";      Query = $kqlQueries["kqlMultiLinkTransport"] },
        @{ Label = "CurrentWindow_AgentHealthStatus";       Query = $kqlQueries["kqlAgentHealthStatus"] },
        @{ Label = "CurrentWindow_AgentVersionDistribution"; Query = $kqlQueries["kqlAgentVersionDistribution"] },
        @{ Label = "CurrentWindow_AgentHealthChecks";       Query = $kqlQueries["kqlAgentHealthChecks"] },
        @{ Label = "CurrentWindow_ConnectionEnvironment";   Query = $kqlQueries["kqlConnectionEnvironment"] },
        @{ Label = "CurrentWindow_ErrorClassification";     Query = $kqlQueries["kqlErrorClassification"] },
        @{ Label = "CurrentWindow_CheckpointLoginDecomp";   Query = $kqlQueries["kqlCheckpointLoginDecomposition"] },
        @{ Label = "CurrentWindow_DisconnectHeatmap";       Query = $kqlQueries["kqlDisconnectHeatmap"] }
    ) | Where-Object { $null -ne $_.Query }

    # progress tracking for queries (use a global counter so parallel runspaces can update it safely)
    $global:laProcessed = 0
    $remainingQueryCount = @($queryDispatchList | Where-Object { $_.Label -ne "CurrentWindow_TableDiscovery" }).Count
    $laTotal = (SafeCount $LogAnalyticsWorkspaceResourceIds) * $remainingQueryCount

    # initialize KQL progress now that laTotal is set
    if ($laTotal -gt 0) { Write-Progress -Activity "Running KQL queries" -Status "0/$laTotal queries" -PercentComplete 0 }

    Write-Host "  Dispatching $(SafeCount $queryDispatchList) queries across $(SafeCount $LogAnalyticsWorkspaceResourceIds) workspace(s)" -ForegroundColor Gray
    Write-Host ""

    foreach ($wsId in $LogAnalyticsWorkspaceResourceIds) {
        # Handle cross-subscription workspace access
        $wsSubId = Get-SubFromArmId $wsId
        if ($wsSubId -and $wsSubId -ne $script:currentSubContext) {
            Write-Host "    switching context to workspace subscription $(Protect-SubscriptionId $wsSubId)" -ForegroundColor Gray
            try {
                Invoke-WithRetry { Set-AzContext -SubscriptionId $wsSubId -TenantId $TenantId -ErrorAction Stop | Out-Null }
                $script:currentSubContext = $wsSubId
            }
            catch {
                Write-Step -Step "KQL" -Message "Cannot access workspace subscription $(Protect-SubscriptionId $wsSubId) -- $($_.Exception.Message)" -Status "Error"
                continue
            }
        }

        $wsName = Get-NameFromArmId $wsId
        $wsNameSafe = Protect-Value -Value $wsName -Prefix 'WS' -Length 4
        Write-Step -Step "KQL" -Message "Workspace: $wsNameSafe" -Status "Progress"

        # Run TableDiscovery first (sequential) to validate connectivity
        $tdQuery = $queryDispatchList | Where-Object { $_.Label -eq "CurrentWindow_TableDiscovery" } | Select-Object -First 1
        if ($tdQuery) {
            $tdResult = Invoke-LaQuery -WorkspaceResourceId $wsId -Label $tdQuery.Label -Query $tdQuery.Query -StartTime $queryStart -EndTime $queryEnd
            foreach ($r in SafeArray $tdResult) {
                if ($ScrubPII) {
                    $null = Protect-KqlRow $r
                }
                $laResults.Add($r)
            }

            $tdStatus = ($tdResult | Where-Object { $_.PSObject.Properties.Name -contains 'Status' } | Select-Object -First 1)
            if ($tdStatus -and $tdStatus.Status -in @("WorkspaceNotFound", "QueryFailed", "InvalidWorkspaceId")) {
                Write-Step -Step "KQL" -Message "Workspace unreachable ($($tdStatus.Status)) -- skipping remaining queries" -Status "Error"
                if ($tdStatus.Status -eq "WorkspaceNotFound") {
                    Write-Host "    Verify the workspace resource ID is correct and that you have Log Analytics Reader access." -ForegroundColor Yellow
                    Write-Host "    Expected format: /subscriptions/<sub-id>/resourceGroups/<rg>/providers/Microsoft.OperationalInsights/workspaces/<name>" -ForegroundColor Gray
                }
                continue
            }
        }

        # Run remaining queries in parallel
        $remainingQueries = $queryDispatchList | Where-Object { $_.Label -ne "CurrentWindow_TableDiscovery" }
        $kqlCollected = [System.Collections.Concurrent.ConcurrentBag[object]]::new()

        # Serialize helper functions for parallel runspaces
        $invokeBody = (Get-Item "Function:\Invoke-LaQuery").ScriptBlock.ToString()
        $safePropBody = (Get-Item "Function:\SafeProp").ScriptBlock.ToString()
        $safeArrayBody = (Get-Item "Function:\SafeArray").ScriptBlock.ToString()

        # run each query in parallel but emit a progress token so the caller can update the bar
        $remainingQueries | ForEach-Object -Parallel {
            $kq    = $_
            $wsId  = $using:wsId
            $start = $using:queryStart
            $end   = $using:queryEnd
            $bag   = $using:kqlCollected

            # Re-create helper functions in parallel runspace
            Set-Item "Function:\Invoke-LaQuery" -Value ([scriptblock]::Create($using:invokeBody))
            Set-Item "Function:\SafeProp"       -Value ([scriptblock]::Create($using:safePropBody))
            Set-Item "Function:\SafeArray"      -Value ([scriptblock]::Create($using:safeArrayBody))

            try {
                $results = Invoke-LaQuery -WorkspaceResourceId $wsId -Label $kq.Label -Query $kq.Query -StartTime $start -EndTime $end
                foreach ($r in @($results)) {
                    $bag.Add($r)
                }
            }
            catch {
                $bag.Add([PSCustomObject]@{
                    WorkspaceResourceId = $wsId
                    Label               = $kq.Label
                    QueryName           = "Meta"
                    Status              = "QueryFailed"
                    Error               = $_.Exception.Message
                    RowCount            = 0
                })
            }
            # signal one query completed (only progress tokens should reach the main thread)
            [PSCustomObject]@{ _ProgressToken = $true; Progress = 1 }
        } -ThrottleLimit $KqlParallel | ForEach-Object {
            # Only process progress tokens -- ignore anything else that leaks from parallel runspaces
            if ($_.PSObject.Properties['_ProgressToken']) {
                $global:laProcessed += $_.Progress
                try {
                    $pct = if ($laTotal -gt 0) { [math]::Round(($global:laProcessed / $laTotal) * 100) } else { 0 }
                    Write-Progress -Activity "Running KQL queries" -Status "$global:laProcessed/$laTotal queries" -PercentComplete $pct
                } catch { }
            }
        }

        foreach ($item in $kqlCollected) {
            if ($ScrubPII) {
                $null = Protect-KqlRow $item
            }
            $laResults.Add($item)
        }

        Write-Step -Step "KQL" -Message "$wsNameSafe -- $(SafeCount $kqlCollected) results collected" -Status "Done"
    }

    # clear progress display when finished
    if ($laTotal -gt 0) { Write-Progress -Activity "Running KQL queries" -Completed }

    Write-Host ""
    Write-Host "  [OK] KQL collection complete: $(SafeCount $laResults) total results" -ForegroundColor Green
    Write-Host ""

    # -- Incident Window KQL Queries (optional) --
    if ($IncludeIncidentWindow) {
        Write-Host "  Collecting incident window KQL queries ($IncidentWindowStart -> $IncidentWindowEnd)..." -ForegroundColor Cyan

        $incidentQueryList = @(
            @{ Label = "IncidentWindow_WVDConnections";         Query = $kqlQueries["kqlWvdConnections"] },
            @{ Label = "IncidentWindow_WVDPeakConcurrency";     Query = $kqlQueries["kqlPeakConcurrency"] },
            @{ Label = "IncidentWindow_ProfileLoadPerformance"; Query = $kqlQueries["kqlProfileLoadPerformance"] },
            @{ Label = "IncidentWindow_ConnectionErrors";       Query = $kqlQueries["kqlConnectionErrors"] },
            @{ Label = "IncidentWindow_ConnectionQuality";      Query = $kqlQueries["kqlConnectionQuality"] }
        ) | Where-Object { $null -ne $_.Query }

        if ($incidentQueryList.Count -gt 0) {
            $incidentQueryStart = $IncidentWindowStart
            $incidentQueryEnd   = $IncidentWindowEnd

            foreach ($wsId in $LogAnalyticsWorkspaceResourceIds) {
                # Handle cross-subscription workspace access
                $wsSubId = Get-SubFromArmId $wsId
                if ($wsSubId -and $wsSubId -ne $script:currentSubContext) {
                    try {
                        Invoke-WithRetry { Set-AzContext -SubscriptionId $wsSubId -TenantId $TenantId -ErrorAction Stop | Out-Null }
                        $script:currentSubContext = $wsSubId
                    }
                    catch { continue }
                }

                $wsName = Get-NameFromArmId $wsId
                $wsNameSafe = Protect-Value -Value $wsName -Prefix 'WS' -Length 4
                Write-Step -Step "KQL" -Message "Incident queries: $wsNameSafe" -Status "Progress"

                $incidentCollectedKql = [System.Collections.Concurrent.ConcurrentBag[object]]::new()

                $incidentQueryList | ForEach-Object -Parallel {
                    $kq    = $_
                    $wsId  = $using:wsId
                    $start = $using:incidentQueryStart
                    $end   = $using:incidentQueryEnd
                    $bag   = $using:incidentCollectedKql

                    Set-Item "Function:\Invoke-LaQuery" -Value ([scriptblock]::Create($using:invokeBody))
                    Set-Item "Function:\SafeProp"       -Value ([scriptblock]::Create($using:safePropBody))
                    Set-Item "Function:\SafeArray"      -Value ([scriptblock]::Create($using:safeArrayBody))

                    try {
                        $results = Invoke-LaQuery -WorkspaceResourceId $wsId -Label $kq.Label -Query $kq.Query -StartTime $start -EndTime $end
                        foreach ($r in @($results)) { $bag.Add($r) }
                    }
                    catch {
                        $bag.Add([PSCustomObject]@{
                            WorkspaceResourceId = $wsId
                            Label               = $kq.Label
                            QueryName           = "Meta"
                            Status              = "QueryFailed"
                            Error               = $_.Exception.Message
                            RowCount            = 0
                        })
                    }
                } -ThrottleLimit $KqlParallel

                foreach ($item in $incidentCollectedKql) {
                    if ($ScrubPII) {
                        $null = Protect-KqlRow $item
                    }
                    $laResults.Add($item)
                }

                Write-Step -Step "KQL" -Message "$wsNameSafe -- $(SafeCount $incidentCollectedKql) incident results" -Status "Done"
            }

            Write-Host "  [OK] Incident window KQL complete" -ForegroundColor Green
            Write-Host ""
        }
    }
    # Save Step 3 checkpoint
    Export-PackJson -FileName 'la-results.json' -Data $laResults
    Save-Checkpoint 'step3-kql'
    Write-Host "  [CHECKPOINT] Step 3 saved -- safe to resume from: $outFolder" -ForegroundColor DarkGray
    Write-Host ""

    # -- Build Diagnostic Readiness from TableDiscovery --
    # Mirrors the EP's diagnostic readiness structure so the report can show data prerequisites
    $diagnosticReadiness = [System.Collections.Generic.List[object]]::new()
    $discoveredTables = @($laResults | Where-Object { $_.Label -eq "CurrentWindow_TableDiscovery" -and $_.QueryName -eq "AVD" -and $_.PSObject.Properties.Name -contains "Type" })
    
    if ($discoveredTables.Count -gt 0) {
        $tableNames = @($discoveredTables | ForEach-Object { $_.Type })
        $diagnosticGroups = @(
            @{ Name = "AVD Connections";      Tables = @("WVDConnections");                   Required = $true;  Purpose = "Login times, disconnect reasons, connection quality, Shortpath analysis" }
            @{ Name = "AVD Network Data";     Tables = @("WVDConnectionNetworkData");         Required = $true;  Purpose = "RTT latency, bandwidth, connection quality by region" }
            @{ Name = "AVD Errors";           Tables = @("WVDErrors");                        Required = $true;  Purpose = "Connection error codes, failure root cause analysis" }
            @{ Name = "AVD Autoscale";        Tables = @("WVDAutoscaleEvaluationPooled");     Required = $false; Purpose = "Scaling plan activity, scale-out/in events, failure tracking" }
            @{ Name = "Performance Counters"; Tables = @("Perf");                             Required = $false; Purpose = "Per-process CPU/memory, CPU percentiles, disconnect-CPU correlation" }
            @{ Name = "AVD Agent Health";     Tables = @("WVDAgentHealthStatus");             Required = $false; Purpose = "Session host agent health checks and version monitoring" }
            @{ Name = "FSLogix Events";       Tables = @("Event");                            Required = $false; Purpose = "FSLogix profile container attach/detach events, error codes" }
            @{ Name = "Multi-Link Transport"; Tables = @("WVDMultiLinkAdd");                  Required = $false; Purpose = "Actual transport negotiation: DIRECT/STUN/TURN/WEBSOCKET per connection" }
            @{ Name = "Connection Checkpoints"; Tables = @("WVDCheckpoints");                 Required = $false; Purpose = "Login time decomposition: brokering, auth, transport, logon, shell phases" }
        )
        foreach ($dg in $diagnosticGroups) {
            $found = @($dg.Tables | Where-Object { $_ -in $tableNames })
            $diagnosticReadiness.Add([PSCustomObject]@{
                Group     = $dg.Name
                Tables    = $dg.Tables -join ", "
                Available = ($found.Count -eq $dg.Tables.Count)
                Required  = $dg.Required
                Purpose   = $dg.Purpose
            })
        }
        Export-PackJson -FileName 'diagnostic-readiness.json' -Data $diagnosticReadiness
        $readyCount = @($diagnosticReadiness | Where-Object { $_.Available }).Count
        $totalCount = $diagnosticReadiness.Count
        Write-Host "  [OK] Diagnostic readiness: $readyCount/$totalCount data groups available" -ForegroundColor Green
        Write-Host ""
    }
}

# =========================================================
# STEP 4 (optional): Quota Usage
# =========================================================
if ($IncludeQuotaUsage) {
    Write-Host "======================================================================" -ForegroundColor Cyan
    Write-Host "  Collecting Quota Usage" -ForegroundColor Cyan
    Write-Host "======================================================================" -ForegroundColor Cyan
    Write-Host ""

    $avdRegions = @($vms | Where-Object { $_.Region } | Select-Object -ExpandProperty Region -Unique)

    foreach ($region in $avdRegions) {
        Write-Step -Step "Quota" -Message "Region: $region" -Status "Progress"
        try {
            # Switch to first subscription for quota query
            if ($script:currentSubContext -ne $SubscriptionIds[0]) {
                Invoke-WithRetry { Set-AzContext -SubscriptionId $SubscriptionIds[0] -TenantId $TenantId -ErrorAction Stop | Out-Null }
                $script:currentSubContext = $SubscriptionIds[0]
            }
            $usageData = @(Get-AzVMUsage -Location $region -ErrorAction Stop)

            foreach ($usage in $usageData) {
                $usageName  = SafeProp $usage.Name 'Value'
                $usageLocal = SafeProp $usage.Name 'LocalizedValue'
                $currentVal = $usage.CurrentValue
                $limitVal   = $usage.Limit

                # Only include relevant quota families
                if ($usageLocal -match 'Total Regional|Standard D|Standard E|Standard F|Standard B|Standard N|Standard L|Standard M|Standard H|DSv|ESv|FSv|BSv|NV|NC|ND') {
                    $available = $limitVal - $currentVal
                    $usagePct  = if ($limitVal -gt 0) { [math]::Round(($currentVal / $limitVal) * 100, 1) } else { 0 }

                    $quotaUsage.Add([PSCustomObject]@{
                        Region       = $region
                        Family       = $usageLocal
                        FamilyCode   = $usageName
                        CurrentUsage = $currentVal
                        Limit        = $limitVal
                        Available    = $available
                        UsagePct     = $usagePct
                    })
                }
            }
        }
        catch {
            Write-Step -Step "Quota" -Message "Failed for $region -- $($_.Exception.Message)" -Status "Warn"
        }
    }

    Write-Host "  [OK] Quota data: $(SafeCount $quotaUsage) entries across $(SafeCount $avdRegions) regions" -ForegroundColor Green
    Write-Host ""
}

# =========================================================
# STEP 5 (optional): Reserved Instances
# =========================================================
if ($IncludeReservedInstances -and $script:hasAzReservations) {
    Write-Host "======================================================================" -ForegroundColor Cyan
    Write-Host "  Collecting Reserved Instances" -ForegroundColor Cyan
    Write-Host "======================================================================" -ForegroundColor Cyan
    Write-Host ""

    try {
        Import-Module Az.Reservations -ErrorAction Stop
        Write-Host "  Fetching reservation orders..." -ForegroundColor Gray

        $allOrders = @(Get-AzReservationOrder -ErrorAction Stop)
        Write-Host "    Found $($allOrders.Count) reservation order(s)" -ForegroundColor Gray

        foreach ($order in $allOrders) {
            $orderId = ($order.Id -split '/')[-1]
            if (-not $orderId) { $orderId = $order.Name }
            if (-not $orderId) { continue }

            try {
                $orderReservations = @(Get-AzReservation -ReservationOrderId $orderId -ErrorAction Stop)
            }
            catch {
                Write-Host "    [WARN] Could not read order $orderId : $($_.Exception.Message)" -ForegroundColor Yellow
                continue
            }

            foreach ($res in $orderReservations) {
                # Defensive property extraction -- Az.Reservations objects vary by module version
                $skuName = $null
                if ($res.PSObject.Properties['Sku']) {
                    $skuName = if ($res.Sku -is [string]) { $res.Sku }
                              elseif ($res.Sku.PSObject.Properties['Name']) { $res.Sku.Name }
                              else { "$($res.Sku)" }
                }
                $skuName = $skuName ?? (SafeProp $res 'SkuName') ?? (SafeProp $res 'ReservedResourceType') ?? "Unknown"

                $location  = (SafeProp $res 'Location') ?? ""
                $quantity  = (SafeProp $res 'Quantity') ?? 0
                $provState = (SafeProp $res 'ProvisioningState') ?? (SafeProp $res 'State') ?? "Unknown"
                $displayName = (SafeProp $res 'DisplayName') ?? (SafeProp $res 'Name') ?? ""
                $term      = (SafeProp $res 'Term') ?? ""
                $appliedScope = (SafeProp $res 'AppliedScopeType') ?? (SafeProp $res 'UserFriendlyAppliedScopeType') ?? ""

                # Expiry -- try multiple property names
                $expiry = (SafeProp $res 'ExpiryDate') ?? (SafeProp $res 'ExpiryDateTime') ?? $null
                if ($expiry -and $expiry -is [string]) {
                    try { $expiry = [datetime]::Parse($expiry) } catch { $expiry = $null }
                }

                $effectiveDate = (SafeProp $res 'EffectiveDateTime') ?? (SafeProp $res 'BenefitStartTime') ?? $null
                if ($effectiveDate -and $effectiveDate -is [string]) {
                    try { $effectiveDate = [datetime]::Parse($effectiveDate) } catch { $effectiveDate = $null }
                }

                $reservedInstances.Add([PSCustomObject]@{
                    ReservationId     = if ($ScrubPII) { Protect-Value -Value ($res.Id ?? "") -Prefix "RI" -Length 6 } else { $res.Id ?? "" }
                    ReservationName   = if ($ScrubPII) { Protect-Value -Value $displayName -Prefix "Res" -Length 4 } else { $displayName }
                    SKU               = $skuName
                    Location          = $location
                    Quantity          = [int]$quantity
                    ProvisioningState = $provState
                    ExpiryDate        = $expiry
                    EffectiveDate     = $effectiveDate
                    Term              = $term
                    AppliedScopeType  = $appliedScope
                    Status            = if ($provState -eq "Succeeded") { "Active" } else { $provState }
                    DaysUntilExpiry   = if ($expiry) { [math]::Max(0, [math]::Round(($expiry - (Get-Date)).TotalDays, 0)) } else { "Unknown" }
                })
            }
        }

        Write-Host "  [OK] Found $($reservedInstances.Count) reservation(s) across $($allOrders.Count) order(s)" -ForegroundColor Green
    }
    catch {
        Write-Host "  [WARN] Could not read reservations: $($_.Exception.Message)" -ForegroundColor Yellow
        Write-Host "    This usually means the account lacks Reservations Reader role at the tenant level" -ForegroundColor Gray
    }

    Write-Host ""
}

# =========================================================
# OPTIONAL: Intune Managed Device Collection (via Microsoft Graph)
# =========================================================
if ($IncludeIntune -and $script:mgGraphConnected) {
    Write-Host "======================================================================" -ForegroundColor Cyan
    Write-Host "  Collecting Intune Managed Devices (Microsoft Graph)" -ForegroundColor Cyan
    Write-Host "======================================================================" -ForegroundColor Cyan
    Write-Host ""

    try {
        # Fetch managed devices with fields needed for session host cross-reference
        $graphUri = "https://graph.microsoft.com/v1.0/deviceManagement/managedDevices?`$select=id,deviceName,managedDeviceOwnerType,complianceState,isEncrypted,operatingSystem,osVersion,managementAgent,enrolledDateTime,lastSyncDateTime,azureADDeviceId,model,manufacturer,serialNumber"
        $allDevices = [System.Collections.Generic.List[object]]::new()
        $pageCount = 0

        $response = Invoke-MgGraphRequest -Method GET -Uri $graphUri -ErrorAction Stop
        $pageValue = $null
        if ($response -is [System.Collections.IDictionary]) {
            if ($response.ContainsKey('value')) { $pageValue = $response['value'] }
        } elseif ($null -ne $response.PSObject.Properties.Match('value') -and $response.PSObject.Properties.Match('value').Count -gt 0) {
            $pageValue = $response.value
        }
        if ($null -ne $pageValue) {
            foreach ($d in @($pageValue)) { $allDevices.Add($d) }
        }
        $pageCount++

        # Follow pagination
        $nextLink = $null
        if ($response -is [System.Collections.IDictionary]) {
            if ($response.ContainsKey('@odata.nextLink')) { $nextLink = $response['@odata.nextLink'] }
        } elseif ($null -ne $response.PSObject.Properties.Match('@odata.nextLink') -and $response.PSObject.Properties.Match('@odata.nextLink').Count -gt 0) {
            $nextLink = $response.'@odata.nextLink'
        }

        while ($null -ne $nextLink) {
            $retryCount = 0
            $pageSuccess = $false
            while (-not $pageSuccess -and $retryCount -lt 5) {
                try {
                    $response = Invoke-MgGraphRequest -Method GET -Uri $nextLink -ErrorAction Stop
                    $pageValue = $null
                    if ($response -is [System.Collections.IDictionary]) {
                        if ($response.ContainsKey('value')) { $pageValue = $response['value'] }
                    } elseif ($null -ne $response.PSObject.Properties.Match('value') -and $response.PSObject.Properties.Match('value').Count -gt 0) {
                        $pageValue = $response.value
                    }
                    if ($null -ne $pageValue) {
                        foreach ($d in @($pageValue)) { $allDevices.Add($d) }
                    }
                    $pageSuccess = $true
                    $pageCount++
                } catch {
                    $retryCount++
                    $sc = $null
                    try { if ($null -ne $_.Exception.Response) { $sc = [int]$_.Exception.Response.StatusCode } } catch { }
                    if ($sc -eq 429 -and $retryCount -lt 5) {
                        $waitSec = [math]::Pow(2, $retryCount + 1)
                        Write-Host "    [WAIT] Throttled -- waiting ${waitSec}s (attempt $retryCount/5)" -ForegroundColor Yellow
                        Start-Sleep -Seconds $waitSec
                    } else {
                        throw
                    }
                }
            }
            $nextLink = $null
            if ($response -is [System.Collections.IDictionary]) {
                if ($response.ContainsKey('@odata.nextLink')) { $nextLink = $response['@odata.nextLink'] }
            } elseif ($null -ne $response.PSObject.Properties.Match('@odata.nextLink') -and $response.PSObject.Properties.Match('@odata.nextLink').Count -gt 0) {
                $nextLink = $response.'@odata.nextLink'
            }
        }

        # Filter to Windows devices only (session hosts are Windows)
        foreach ($device in $allDevices) {
            $os = $null
            if ($device -is [System.Collections.IDictionary]) {
                if ($device.ContainsKey('operatingSystem')) { $os = $device['operatingSystem'] }
            } else {
                if ($device.PSObject.Properties.Match('operatingSystem').Count -gt 0) { $os = $device.operatingSystem }
            }

            if ($null -ne $os -and $os -match 'Windows') {
                # Extract fields safely (handles both Hashtable and PSObject)
                $getName = { param($obj, $prop)
                    if ($obj -is [System.Collections.IDictionary]) { if ($obj.ContainsKey($prop)) { return $obj[$prop] } else { return $null } }
                    if ($obj.PSObject.Properties.Match($prop).Count -gt 0) { return $obj.$prop } else { return $null }
                }

                $deviceName = & $getName $device 'deviceName'
                $intuneManagedDevices.Add([PSCustomObject]@{
                    DeviceName          = if ($ScrubPII -and $null -ne $deviceName) { Protect-VMName $deviceName } else { $deviceName }
                    ComplianceState     = & $getName $device 'complianceState'
                    IsEncrypted         = & $getName $device 'isEncrypted'
                    OperatingSystem     = $os
                    OsVersion           = & $getName $device 'osVersion'
                    ManagementAgent     = & $getName $device 'managementAgent'
                    EnrolledDateTime    = & $getName $device 'enrolledDateTime'
                    LastSyncDateTime    = & $getName $device 'lastSyncDateTime'
                    AzureADDeviceId     = & $getName $device 'azureADDeviceId'
                    Model               = & $getName $device 'model'
                    Manufacturer        = & $getName $device 'manufacturer'
                    OwnerType           = & $getName $device 'managedDeviceOwnerType'
                })
            }
        }

        Write-Host "  [OK] Intune devices: $($allDevices.Count) total, $($intuneManagedDevices.Count) Windows devices ($pageCount pages)" -ForegroundColor Green
    }
    catch {
        Write-Host "  [WARN] Intune collection failed: $($_.Exception.Message)" -ForegroundColor Yellow
        Write-Host "    Session host enrollment analysis will not be available" -ForegroundColor Gray
    }

    # === Conditional Access Policies (via same Graph session) ===
    Write-Host "  Collecting Conditional Access Policies (Microsoft Graph)" -ForegroundColor Cyan
    try {
        $caUri = "https://graph.microsoft.com/v1.0/identity/conditionalAccess/policies"
        $caAllPolicies = [System.Collections.Generic.List[object]]::new()

        $caResponse = Invoke-MgGraphRequest -Method GET -Uri $caUri -ErrorAction Stop
        $caPageValue = $null
        if ($caResponse -is [System.Collections.IDictionary]) {
            if ($caResponse.ContainsKey('value')) { $caPageValue = $caResponse['value'] }
        } elseif ($null -ne $caResponse.PSObject.Properties.Match('value') -and $caResponse.PSObject.Properties.Match('value').Count -gt 0) {
            $caPageValue = $caResponse.value
        }
        if ($null -ne $caPageValue) {
            foreach ($p in @($caPageValue)) { $caAllPolicies.Add($p) }
        }

        # Follow pagination
        $caNextLink = $null
        if ($caResponse -is [System.Collections.IDictionary]) {
            if ($caResponse.ContainsKey('@odata.nextLink')) { $caNextLink = $caResponse['@odata.nextLink'] }
        } elseif ($null -ne $caResponse.PSObject.Properties.Match('@odata.nextLink') -and $caResponse.PSObject.Properties.Match('@odata.nextLink').Count -gt 0) {
            $caNextLink = $caResponse.'@odata.nextLink'
        }

        while ($null -ne $caNextLink) {
            $caRetry = 0
            $caPageOk = $false
            while (-not $caPageOk -and $caRetry -lt 5) {
                try {
                    $caResponse = Invoke-MgGraphRequest -Method GET -Uri $caNextLink -ErrorAction Stop
                    $caPageValue = $null
                    if ($caResponse -is [System.Collections.IDictionary]) {
                        if ($caResponse.ContainsKey('value')) { $caPageValue = $caResponse['value'] }
                    } elseif ($null -ne $caResponse.PSObject.Properties.Match('value') -and $caResponse.PSObject.Properties.Match('value').Count -gt 0) {
                        $caPageValue = $caResponse.value
                    }
                    if ($null -ne $caPageValue) {
                        foreach ($p in @($caPageValue)) { $caAllPolicies.Add($p) }
                    }
                    $caPageOk = $true
                } catch {
                    $caRetry++
                    $caSC = $null
                    try { if ($null -ne $_.Exception.Response) { $caSC = [int]$_.Exception.Response.StatusCode } } catch { }
                    if ($caSC -eq 429 -and $caRetry -lt 5) {
                        $caWait = [math]::Pow(2, $caRetry + 1)
                        Write-Host "    [WAIT] Throttled -- waiting ${caWait}s (attempt $caRetry/5)" -ForegroundColor Yellow
                        Start-Sleep -Seconds $caWait
                    } else { throw }
                }
            }
            $caNextLink = $null
            if ($caResponse -is [System.Collections.IDictionary]) {
                if ($caResponse.ContainsKey('@odata.nextLink')) { $caNextLink = $caResponse['@odata.nextLink'] }
            } elseif ($null -ne $caResponse.PSObject.Properties.Match('@odata.nextLink') -and $caResponse.PSObject.Properties.Match('@odata.nextLink').Count -gt 0) {
                $caNextLink = $caResponse.'@odata.nextLink'
            }
        }

        # Extract relevant fields from each CA policy (store structured data, not raw blobs)
        $getName = { param($obj, $prop)
            if ($obj -is [System.Collections.IDictionary]) { if ($obj.ContainsKey($prop)) { return $obj[$prop] } else { return $null } }
            if ($obj.PSObject.Properties.Match($prop).Count -gt 0) { return $obj.$prop } else { return $null }
        }
        foreach ($cap in $caAllPolicies) {
            $displayName = & $getName $cap 'displayName'
            $state = & $getName $cap 'state'
            $conditions = & $getName $cap 'conditions'
            $grantControls = & $getName $cap 'grantControls'
            $sessionControls = & $getName $cap 'sessionControls'

            # Extract application conditions
            $appConditions = if ($null -ne $conditions) { & $getName $conditions 'applications' } else { $null }
            $includeApps = if ($null -ne $appConditions) { & $getName $appConditions 'includeApplications' } else { @() }
            $excludeApps = if ($null -ne $appConditions) { & $getName $appConditions 'excludeApplications' } else { @() }

            # Extract user conditions
            $userConditions = if ($null -ne $conditions) { & $getName $conditions 'users' } else { $null }
            $includeUsers = if ($null -ne $userConditions) { & $getName $userConditions 'includeUsers' } else { @() }
            $includeGroups = if ($null -ne $userConditions) { & $getName $userConditions 'includeGroups' } else { @() }

            # Extract grant controls
            $builtInControls = if ($null -ne $grantControls) { & $getName $grantControls 'builtInControls' } else { @() }
            $grantOperator = if ($null -ne $grantControls) { & $getName $grantControls 'operator' } else { $null }

            # Extract session controls
            $signInFreq = if ($null -ne $sessionControls) { & $getName $sessionControls 'signInFrequency' } else { $null }
            $persistentBrowser = if ($null -ne $sessionControls) { & $getName $sessionControls 'persistentBrowser' } else { $null }

            # Extract location conditions
            $locationCond = if ($null -ne $conditions) { & $getName $conditions 'locations' } else { $null }
            $includeLocations = if ($null -ne $locationCond) { & $getName $locationCond 'includeLocations' } else { @() }

            # Extract platform conditions
            $platformCond = if ($null -ne $conditions) { & $getName $conditions 'platforms' } else { $null }
            $includePlatforms = if ($null -ne $platformCond) { & $getName $platformCond 'includePlatforms' } else { @() }

            $conditionalAccessPolicies.Add([PSCustomObject]@{
                DisplayName         = if ($ScrubPII -and $null -ne $displayName) { Protect-Value -Value $displayName -Prefix "CA" } else { $displayName }
                State               = $state
                IncludeApplications = if ($null -ne $includeApps) { @($includeApps) } else { @() }
                ExcludeApplications = if ($null -ne $excludeApps) { @($excludeApps) } else { @() }
                IncludeUsers        = if ($null -ne $includeUsers) { @($includeUsers) } else { @() }
                IncludeGroups       = if ($null -ne $includeGroups) { @($includeGroups) } else { @() }
                BuiltInControls     = if ($null -ne $builtInControls) { @($builtInControls) } else { @() }
                GrantOperator       = $grantOperator
                SignInFrequency     = $signInFreq
                PersistentBrowser   = $persistentBrowser
                IncludeLocations    = if ($null -ne $includeLocations) { @($includeLocations) } else { @() }
                IncludePlatforms    = if ($null -ne $includePlatforms) { @($includePlatforms) } else { @() }
            })
        }

        Write-Host "  [OK] Conditional Access policies: $($conditionalAccessPolicies.Count)" -ForegroundColor Green
    }
    catch {
        Write-Host "  [WARN] CA policy collection failed: $($_.Exception.Message)" -ForegroundColor Yellow
        Write-Host "    Conditional Access analysis will not be available" -ForegroundColor Gray
    }

    if ($DisconnectGraphOnExit) {
        try {
            Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null
            Write-Host "  [OK] Graph session disconnected (-DisconnectGraphOnExit)" -ForegroundColor Gray
        } catch { }
    } elseif ($script:mgGraphConnected -and ($script:mgGraphReusedContext -or $script:mgGraphConnectedByScript)) {
        Write-Host "  [OK] Graph session retained for reuse (set -DisconnectGraphOnExit to sign out)" -ForegroundColor Gray
    }
    Write-Host ""
}

# =========================================================
# EXPORT: Write Collection Pack
# =========================================================
Write-Host "" 
Write-Host "======================================================================" -ForegroundColor Cyan
Write-Host "  Exporting Collection Pack" -ForegroundColor Cyan
Write-Host "======================================================================" -ForegroundColor Cyan
Write-Host ""

# Final exports (optional data + metadata -- other files already saved at checkpoints)
if ($IncludeQuotaUsage) {
    Export-PackJson -FileName "quota-usage.json" -Data $quotaUsage
}
if ($IncludeReservedInstances) {
    Export-PackJson -FileName "reserved-instances.json" -Data $reservedInstances
}
if ($IncludeIntune -and (SafeCount $intuneManagedDevices) -gt 0) {
    Export-PackJson -FileName "intune-managed-devices.json" -Data $intuneManagedDevices
}
if ($IncludeIntune -and (SafeCount $conditionalAccessPolicies) -gt 0) {
    Export-PackJson -FileName "conditional-access-policies.json" -Data $conditionalAccessPolicies
}

# Extended data exports
if ($IncludeResourceTags -and (SafeCount $resourceTags) -gt 0) {
    Export-PackJson -FileName "resource-tags.json" -Data $resourceTags
}
if ($IncludeCostData) {
    if ((SafeCount $actualCostData) -gt 0) {
        Export-PackJson -FileName "actual-cost-data.json" -Data $actualCostData
    }
    if (($vmActualMonthlyCost.Keys).Count -gt 0) {
        # Convert hashtable to list for JSON serialization
        $vmCostList = [System.Collections.Generic.List[object]]::new()
        foreach ($key in $vmActualMonthlyCost.Keys) {
            $vmCostList.Add([PSCustomObject]@{ VMName = Protect-VMName $key; MonthlyCost = $vmActualMonthlyCost[$key] })
        }
        Export-PackJson -FileName "vm-actual-monthly-cost.json" -Data $vmCostList
    }
    if ((SafeCount $infraCostData) -gt 0) {
        Export-PackJson -FileName "infra-cost-data.json" -Data $infraCostData
    }
    # Export cost access status
    Export-PackJson -FileName "cost-access.json" -Data ([PSCustomObject]@{
        Granted = @($costAccessGranted)
        Denied  = @($costAccessDenied)
    })
}
if ($IncludeNetworkTopology) {
    if ((SafeCount $subnetAnalysis) -gt 0) {
        Export-PackJson -FileName "subnet-analysis.json" -Data $subnetAnalysis
    }
    if ((SafeCount $vnetAnalysis) -gt 0) {
        Export-PackJson -FileName "vnet-analysis.json" -Data $vnetAnalysis
    }
    if ((SafeCount $privateEndpointFindings) -gt 0) {
        Export-PackJson -FileName "private-endpoint-findings.json" -Data $privateEndpointFindings
    }
    if ((SafeCount $nsgRuleFindings) -gt 0) {
        Export-PackJson -FileName "nsg-rule-findings.json" -Data $nsgRuleFindings
    }
}
if ($IncludeOrphanedResources -and (SafeCount $orphanedResources) -gt 0) {
    Export-PackJson -FileName "orphaned-resources.json" -Data $orphanedResources
}
if ($IncludeStorageAnalysis) {
    if ((SafeCount $fslogixStorageAnalysis) -gt 0) {
        Export-PackJson -FileName "fslogix-storage-analysis.json" -Data $fslogixStorageAnalysis
    }
    if ((SafeCount $fslogixShares) -gt 0) {
        Export-PackJson -FileName "fslogix-shares.json" -Data $fslogixShares
    }
}
if ($IncludeDiagnosticSettings -and (SafeCount $diagnosticSettings) -gt 0) {
    Export-PackJson -FileName "diagnostic-settings.json" -Data $diagnosticSettings
}
if ($IncludeAlertRules -and (SafeCount $alertRules) -gt 0) {
    Export-PackJson -FileName "alert-rules.json" -Data $alertRules
}
if ($IncludeAlertRules -and (SafeCount $alertHistory) -gt 0) {
    Export-PackJson -FileName "alert-history.json" -Data $alertHistory
}
if ($IncludeActivityLog -and (SafeCount $activityLogEntries) -gt 0) {
    Export-PackJson -FileName "activity-log.json" -Data $activityLogEntries
}
if ($IncludePolicyAssignments -and (SafeCount $policyAssignments) -gt 0) {
    Export-PackJson -FileName "policy-assignments.json" -Data $policyAssignments
}
if ($IncludeImageAnalysis) {
    if ((SafeCount $galleryAnalysis) -gt 0) {
        Export-PackJson -FileName "gallery-analysis.json" -Data $galleryAnalysis
    }
    if ((SafeCount $galleryImageDetails) -gt 0) {
        Export-PackJson -FileName "gallery-image-details.json" -Data $galleryImageDetails
    }
    if ((SafeCount $marketplaceImageDetails) -gt 0) {
        Export-PackJson -FileName "marketplace-image-details.json" -Data $marketplaceImageDetails
    }
}

# Metadata
$metadata = [PSCustomObject]@{
    SchemaVersion            = $script:SchemaVersion
    ScriptVersion            = $script:ScriptVersion
    CollectionTimestamp      = (Get-Date -Format "yyyy-MM-dd HH:mm:ss UTC")
    SubscriptionIds          = @($SubscriptionIds | ForEach-Object { Protect-SubscriptionId $_ })
    TenantId                 = $(if ($ScrubPII) { '****-****-****' } else { $TenantId })
    MetricsLookbackDays      = $MetricsLookbackDays
    IncidentWindowQueried    = [bool]$IncludeIncidentWindow
    SkipAzureMonitorMetrics  = [bool]$SkipAzureMonitorMetrics
    SkipLogAnalyticsQueries  = [bool]$SkipLogAnalyticsQueries
    SkipActualCosts          = -not [bool]$IncludeCostData
    PIIScrubbed              = [bool]$ScrubPII
    ExtendedCollections      = [PSCustomObject]@{
        CostData            = [bool]$IncludeCostData
        NetworkTopology     = [bool]$IncludeNetworkTopology
        ImageAnalysis       = [bool]$IncludeImageAnalysis
        StorageAnalysis     = [bool]$IncludeStorageAnalysis
        OrphanedResources   = [bool]$IncludeOrphanedResources
        DiagnosticSettings  = [bool]$IncludeDiagnosticSettings
        AlertRules          = [bool]$IncludeAlertRules
        ActivityLog         = [bool]$IncludeActivityLog
        PolicyAssignments   = [bool]$IncludePolicyAssignments
        ResourceTags        = [bool]$IncludeResourceTags
        IntuneDevices       = [bool]$IncludeIntune
        ConditionalAccess   = [bool]$IncludeIntune
    }
    Counts                   = [PSCustomObject]@{
        HostPools             = SafeCount $hostPools
        SessionHosts          = SafeCount $sessionHosts
        VMs                   = SafeCount $vms
        VMSS                  = SafeCount $vmss
        Metrics               = SafeCount $vmMetrics
        KQLResults            = SafeCount $laResults
        AppGroups             = SafeCount $appGroups
        ScalingPlans          = SafeCount $scalingPlans
        ReservedInstances     = SafeCount $reservedInstances
        QuotaEntries          = SafeCount $quotaUsage
        ResourceTags          = SafeCount $resourceTags
        CostEntries           = SafeCount $actualCostData
        VMsWithCosts          = ($vmActualMonthlyCost.Keys).Count
        Subnets               = SafeCount $subnetAnalysis
        VNets                 = SafeCount $vnetAnalysis
        PrivateEndpoints      = SafeCount $privateEndpointFindings
        NSGRiskyRules         = SafeCount $nsgRuleFindings
        OrphanedResources     = SafeCount $orphanedResources
        StorageShares         = SafeCount $fslogixStorageAnalysis
        DiagnosticSettings    = SafeCount $diagnosticSettings
        AlertRules            = SafeCount $alertRules
        AlertHistory          = SafeCount $alertHistory
        ActivityLogEntries    = SafeCount $activityLogEntries
        PolicyAssignments     = SafeCount $policyAssignments
        GalleryImages         = SafeCount $galleryAnalysis
        MarketplaceImages     = SafeCount $marketplaceImageDetails
        IntuneDevices         = SafeCount $intuneManagedDevices
        ConditionalAccessPolicies = SafeCount $conditionalAccessPolicies
    }
    AnalysisErrors           = @()
    CollectorTool            = "aperture-data-collector"
    CollectorVersion         = $script:ScriptVersion
}

$metadata | ConvertTo-Json -Depth 5 | Out-File -FilePath (Join-Path $outFolder "collection-metadata.json") -Encoding UTF8
Write-Host "    [OK] collection-metadata.json" -ForegroundColor Green

# -- Create ZIP --
# make sure diagnostic transcript is closed before archiving
if (Get-Command Stop-Transcript -ErrorAction SilentlyContinue) { try { Stop-Transcript -ErrorAction SilentlyContinue | Out-Null } catch { } }

# Remove checkpoint and internal files before archiving (they're internal bookkeeping)
Get-ChildItem -Path $outFolder -Filter '_checkpoint_*.json' -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
Get-ChildItem -Path $outFolder -Filter '_raw-vm-ids.json' -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
# Diagnostic log contains raw Write-Host output with unscrubbed identifiers -- remove when PII scrubbing
if ($ScrubPII) {
    Get-ChildItem -Path $outFolder -Filter 'diagnostic.log' -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
}

# -- PII Lookup Key (kept OUTSIDE the pack -- never shared with consultant) --
if ($ScrubPII -and $script:piiCache.Count -gt 0) { # count-safe: hashtable
    $lookupEntries = [System.Collections.Generic.List[object]]::new()
    foreach ($entry in $script:piiCache.GetEnumerator()) {
        $parts = $entry.Key -split ':', 2
        $lookupEntries.Add([PSCustomObject]@{
            AnonymizedValue = $entry.Value
            Category        = $parts[0]
            OriginalValue   = $parts[1]
        })
    }
    $lookupEntries = $lookupEntries | Sort-Object Category, AnonymizedValue
    $keyFilePath = "$outFolder-PII-KEY.csv"
    $lookupEntries | Export-Csv -Path $keyFilePath -NoTypeInformation
    Write-Host ""
    Write-Host "  [KEY] PII Lookup Key: $keyFilePath" -ForegroundColor Magenta
    Write-Host "     This file maps anonymized names back to real resource names." -ForegroundColor Gray
    Write-Host "     KEEP THIS FILE -- do NOT send it with the collection pack." -ForegroundColor Yellow
}

$zipPath = "$outFolder.zip"
try {
    Compress-Archive -Path $outFolder -DestinationPath $zipPath -Force
    Write-Host ""
    Write-Host "  [OK] Collection pack created: $zipPath" -ForegroundColor Green

    # Calculate size
    $zipSize = (Get-Item $zipPath).Length
    $sizeMB = [math]::Round($zipSize / 1MB, 2)
    Write-Host "    Size: $sizeMB MB" -ForegroundColor Gray
}
catch {
    Write-Host ""
    Write-Host "  [WARN] Could not create ZIP -- data is in folder: $outFolder" -ForegroundColor Yellow
}

# make sure diagnostic transcript is closed
if (Get-Command Stop-Transcript -ErrorAction SilentlyContinue) {
    try { Stop-Transcript -ErrorAction SilentlyContinue | Out-Null } catch { }
}

# =========================================================
# Summary
# =========================================================
$elapsed = (Get-Date) - $script:collectionStart

Write-Host ""
Write-Host "+=======================================================================+" -ForegroundColor Green
Write-Host "|                     COLLECTION COMPLETE                               |" -ForegroundColor Green
Write-Host "+=======================================================================+" -ForegroundColor Green
Write-Host ""
Write-Host "  Host Pools:      $(SafeCount $hostPools)" -ForegroundColor White
Write-Host "  Session Hosts:   $(SafeCount $sessionHosts)" -ForegroundColor White
Write-Host "  VMs:             $(SafeCount $vms)" -ForegroundColor White
Write-Host "  Metrics:         $(SafeCount $vmMetrics) datapoints" -ForegroundColor White
Write-Host "  KQL Results:     $(SafeCount $laResults)" -ForegroundColor White
Write-Host "  Scaling Plans:   $(SafeCount $scalingPlans)" -ForegroundColor White
Write-Host "  App Groups:      $(SafeCount $appGroups)" -ForegroundColor White
if ($IncludeCapacityReservations) {
    Write-Host "  Capacity Res.:   $(SafeCount $capacityReservationGroups)" -ForegroundColor White
}
if ($IncludeReservedInstances) {
    Write-Host "  Reserved Inst.:  $(SafeCount $reservedInstances)" -ForegroundColor White
}
if ($IncludeQuotaUsage) {
    Write-Host "  Quota Entries:   $(SafeCount $quotaUsage)" -ForegroundColor White
}
if ($IncludeResourceTags -and (SafeCount $resourceTags) -gt 0) {
    Write-Host "  Resource Tags:   $(SafeCount $resourceTags)" -ForegroundColor White
}
if ($IncludeCostData) {
    Write-Host "  Cost Entries:    $(SafeCount $actualCostData) ($(($vmActualMonthlyCost.Keys).Count) VMs)" -ForegroundColor White
}
if ($IncludeNetworkTopology) {
    Write-Host "  Subnets:         $(SafeCount $subnetAnalysis)" -ForegroundColor White
    Write-Host "  VNets:           $(SafeCount $vnetAnalysis)" -ForegroundColor White
    if ((SafeCount $nsgRuleFindings) -gt 0) {
        Write-Host "  Risky NSG Rules: $(SafeCount $nsgRuleFindings)" -ForegroundColor Yellow
    }
}
if ($IncludeOrphanedResources -and (SafeCount $orphanedResources) -gt 0) {
    Write-Host "  Orphaned Res.:   $(SafeCount $orphanedResources)" -ForegroundColor Yellow
}
if ($IncludeStorageAnalysis -and (SafeCount $fslogixStorageAnalysis) -gt 0) {
    Write-Host "  Storage Shares:  $(SafeCount $fslogixStorageAnalysis)" -ForegroundColor White
}
if ($IncludeDiagnosticSettings -and (SafeCount $diagnosticSettings) -gt 0) {
    Write-Host "  Diag Settings:   $(SafeCount $diagnosticSettings)" -ForegroundColor White
}
if ($IncludeAlertRules -and (SafeCount $alertRules) -gt 0) {
    Write-Host "  Alert Rules:     $(SafeCount $alertRules)" -ForegroundColor White
}
if ($IncludeActivityLog -and (SafeCount $activityLogEntries) -gt 0) {
    Write-Host "  Activity Log:    $(SafeCount $activityLogEntries) entries" -ForegroundColor White
}
if ($IncludePolicyAssignments -and (SafeCount $policyAssignments) -gt 0) {
    Write-Host "  Policy Assigns:  $(SafeCount $policyAssignments)" -ForegroundColor White
}
if ($IncludeImageAnalysis) {
    Write-Host "  Gallery Images:  $(SafeCount $galleryAnalysis)" -ForegroundColor White
    Write-Host "  Marketplace SKUs:$(SafeCount $marketplaceImageDetails)" -ForegroundColor White
}
if ($ScrubPII) {
    Write-Host "  PII:             Scrubbed (identifiers anonymized)" -ForegroundColor Magenta
    Write-Host "  PII Key:         $keyFilePath" -ForegroundColor Magenta
    Write-Host ""
    Write-Host "  [WARN] IMPORTANT: The PII key file maps anonymized names to real names." -ForegroundColor Yellow
    Write-Host "    Send ONLY the .zip file to your consultant." -ForegroundColor Yellow
    Write-Host "    Keep the PII key file to cross-reference findings." -ForegroundColor Yellow
}
Write-Host ""
Write-Host "  Runtime: $([math]::Round($elapsed.TotalMinutes, 1)) minutes" -ForegroundColor Gray
Write-Host "  Output:  $zipPath" -ForegroundColor Gray
Write-Host ""

if ((SafeCount $subsSkipped) -gt 0) {
    Write-Host "  [WARN] Skipped subscriptions: $(($subsSkipped | ForEach-Object { Protect-SubscriptionId $_ }) -join ', ')" -ForegroundColor Yellow
    Write-Host ""
}

Write-Host "  To analyze this data with Aperture:" -ForegroundColor Cyan
Write-Host "    .\Aperture-Assessment.ps1 -CollectionPack `"$zipPath`"" -ForegroundColor White
Write-Host ""
