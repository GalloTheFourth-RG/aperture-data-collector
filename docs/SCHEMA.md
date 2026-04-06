# Collection Pack Schema Reference

The Aperture Data Collector outputs a collection pack — a ZIP archive containing JSON files that describe your AVD environment. This document details the schema for each file.

## Schema Version

Current schema version: **2.0**

The schema version is recorded in `collection-metadata.json` and used by consumer tools to validate compatibility.

| Schema Version | Collector Version | Notes |
|---------------|-------------------|-------|
| 2.0 | 1.1.0+ | Extended collection (cost, network, storage, images, governance), diagnostic readiness |
| 1.1 | 1.0.0 | Initial release, compatible with Aperture v4.12.0+ |

---

## File Reference

### collection-metadata.json

Top-level metadata about the collection run.

```json
{
  "SchemaVersion": "2.0",
  "ScriptVersion": "1.4.3",
  "CollectionTimestamp": "2026-04-01 12:00:00 UTC",
  "SubscriptionIds": ["xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"],
  "TenantId": "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx",
  "MetricsLookbackDays": 7,
  "MetricsFormat": "pre-aggregated",
  "IncidentWindowQueried": false,
  "SkipAzureMonitorMetrics": false,
  "SkipLogAnalyticsQueries": false,
  "SkipActualCosts": true,
  "PIIScrubbed": false,
  "ExtendedCollections": {
    "CostData": false,
    "NetworkTopology": false,
    "ImageAnalysis": false,
    "StorageAnalysis": false,
    "OrphanedResources": false,
    "DiagnosticSettings": false,
    "AlertRules": false,
    "ActivityLog": false,
    "PolicyAssignments": false,
    "ResourceTags": false,
    "IntuneDevices": false,
    "ConditionalAccess": false
  },
  "Counts": {
    "HostPools": 5,
    "SessionHosts": 120,
    "VMs": 120,
    "VMSS": 0,
    "Metrics": 8400,
    "KQLResults": 350,
    "AppGroups": 6,
    "ScalingPlans": 3,
    "ReservedInstances": 0,
    "QuotaEntries": 0,
    "ResourceTags": 0,
    "CostEntries": 0,
    "VMsWithCosts": 0,
    "Subnets": 0,
    "VNets": 0,
    "PrivateEndpoints": 0,
    "WorkspacePrivateEndpoints": 0,
    "AVDWorkspaces": 3,
    "NSGRiskyRules": 0,
    "OrphanedResources": 0,
    "StorageShares": 0,
    "DiagnosticSettings": 0,
    "AlertRules": 0,
    "AlertHistory": 0,
    "ActivityLogEntries": 0,
    "PolicyAssignments": 0,
    "GalleryImages": 0,
    "MarketplaceImages": 0,
    "IntuneDevices": 0,
    "ConditionalAccessPolicies": 0
  },
  "AnalysisErrors": [],
  "CollectionDurationSeconds": 45.2,
  "DiagnosticCounts": {
    "TotalEvents": 0,
    "Errors": 0,
    "Warnings": 0,
    "Skipped": 0
  },
  "SkippedSubscriptions": [],
  "CollectorTool": "aperture-data-collector",
  "CollectorVersion": "1.4.3"
}
```

---

## Core Files

These files are always produced by the collector.

### host-pools.json

Array of host pool configurations.

| Field | Type | Description |
|-------|------|-------------|
| SubscriptionId | string | Azure subscription ID |
| ResourceGroup | string | Resource group name |
| HostPoolName | string | Host pool name |
| HostPoolType | string | Pooled or Personal |
| LoadBalancer | string | BreadthFirst or DepthFirst |
| MaxSessions | int | Maximum session limit |
| StartVMOnConnect | bool | Start VM on Connect enabled |
| PreferredAppGroupType | string | Desktop or RailApplications |
| Location | string | Azure region |
| ValidationEnv | bool | Validation environment flag |
| CustomRdpProperty | string | Custom RDP properties string |
| Id | string | ARM resource ID |

### session-hosts.json

Array of session host status records.

| Field | Type | Description |
|-------|------|-------------|
| SubscriptionId | string | Azure subscription ID |
| ResourceGroup | string | Resource group name |
| HostPoolName | string | Parent host pool |
| SessionHostName | string | FQDN of session host |
| SessionHostArmName | string | ARM name (pool/host format) |
| Status | string | Available, Unavailable, Shutdown, etc. |
| AllowNewSession | bool | Drain mode status |
| ActiveSessions | int | Current active sessions |
| AssignedUser | string | Assigned user (personal pools) |
| UpdateState | string | Agent update state |
| LastHeartBeat | datetime | Last agent heartbeat |

### virtual-machines.json

Array of VM inventory with full configuration detail.

| Field | Type | Description |
|-------|------|-------------|
| SubscriptionId | string | Azure subscription ID |
| ResourceGroup | string | VM resource group |
| HostPoolName | string | Associated host pool |
| SessionHostName | string | Short VM name |
| VMName | string | Azure VM name |
| VMId | string | ARM resource ID |
| VMSize | string | VM SKU (e.g., Standard_D4s_v5) |
| Region | string | Azure region |
| Zones | string | Availability zone(s), comma-separated |
| OSDiskType | string | Managed disk type |
| OSDiskEphemeral | bool | Uses ephemeral OS disk |
| DataDiskCount | int | Number of data disks |
| PowerState | string | running, deallocated, stopped, etc. |
| ImagePublisher | string | Marketplace publisher |
| ImageOffer | string | Marketplace offer |
| ImageSku | string | Marketplace SKU |
| ImageVersion | string | Image version |
| ImageId | string | Gallery or managed image ARM ID |
| ImageSource | string | ComputeGallery, Marketplace, ManagedImage, Custom |
| AccelNetEnabled | bool | Accelerated Networking |
| SubnetId | string | Subnet ARM ID |
| NsgId | string | NSG ARM ID |
| PrivateIp | string | Private IP address |
| SecurityType | string | TrustedLaunch, ConfidentialVM, Standard |
| SecureBoot | bool | Secure Boot enabled |
| VTpm | bool | vTPM enabled |
| HostEncryption | bool | Encryption at Host |
| IdentityType | string | SystemAssigned, UserAssigned, etc. |
| HasAadExtension | bool | Entra ID join extension present |
| HasAmaAgent | bool | Azure Monitor Agent present |
| HasMmaAgent | bool | Legacy MMA agent present |
| HasEndpointProtection | bool | Endpoint protection extension |
| HasGuestConfig | bool | Guest Configuration extension |
| HasDiskEncryption | bool | Azure Disk Encryption extension |
| LicenseType | string | Windows_Client (AHUB) or null |
| OSDiskEncryptionType | string | OS disk encryption type |
| Tags | object | Azure resource tags |
| TimeCreated | datetime | VM creation timestamp |

### avd-workspaces.json

Array of AVD workspace configurations.

| Field | Type | Description |
|-------|------|-------------|
| SubscriptionId | string | Azure subscription ID |
| ResourceGroup | string | Workspace resource group |
| WorkspaceName | string | Workspace name |
| FriendlyName | string | Display name |
| Location | string | Azure region |
| PublicNetworkAccess | string | Public network access setting |
| AppGroupCount | int | Number of associated application groups |
| Id | string | ARM resource ID |

### app-groups.json

Array of application group configurations.

| Field | Type | Description |
|-------|------|-------------|
| SubscriptionId | string | Azure subscription ID |
| ResourceGroup | string | Resource group |
| AppGroupName | string | Application group name |
| AppGroupType | string | Desktop or RemoteApp |
| HostPoolArmPath | string | Parent host pool ARM ID |
| HostPoolName | string | Parent host pool name |
| FriendlyName | string | Display name |
| Description | string | App group description |

### scaling-plans.json

Array of autoscale plan definitions.

| Field | Type | Description |
|-------|------|-------------|
| SubscriptionId | string | Azure subscription ID |
| ResourceGroup | string | Resource group |
| ScalingPlanName | string | Plan name |
| Location | string | Azure region |
| TimeZone | string | Schedule timezone |
| HostPoolType | string | Pooled |
| Description | string | Plan description |
| FriendlyName | string | Display name |
| ExclusionTag | string | Tag to exclude VMs from autoscale |
| Id | string | ARM resource ID |

### scaling-plan-assignments.json

Array of scaling plan to host pool assignments.

| Field | Type | Description |
|-------|------|-------------|
| ScalingPlanName | string | Parent scaling plan |
| HostPoolArmId | string | Target host pool ARM ID |
| HostPoolName | string | Target host pool name |
| IsEnabled | bool | Whether scaling is active |

### scaling-plan-schedules.json

Array of per-plan schedule details.

| Field | Type | Description |
|-------|------|-------------|
| ScalingPlanName | string | Parent scaling plan |
| ScheduleName | string | Schedule name |
| DaysOfWeek | string | Comma-separated days |
| RampUpStartTime | string | Ramp-up start |
| PeakStartTime | string | Peak start |
| RampDownStartTime | string | Ramp-down start |
| OffPeakStartTime | string | Off-peak start |
| RampUpCapacity | int | Ramp-up capacity threshold % |
| PeakLoadBalancing | string | Load balancing algorithm |
| RampDownCapacity | int | Ramp-down capacity threshold % |
| OffPeakLoadBalancing | string | Off-peak load balancing |

### vmss.json

Array of VM Scale Set configurations.

| Field | Type | Description |
|-------|------|-------------|
| SubscriptionId | string | Azure subscription ID |
| VMSSName | string | Scale set name |
| VMSize | string | VM SKU |
| Capacity | int | Current instance count |
| Location | string | Azure region |
| Zones | string | Availability zones |

### vmss-instances.json

Array of individual VMSS instance details.

| Field | Type | Description |
|-------|------|-------------|
| VMSSName | string | Parent scale set |
| InstanceId | string | Instance ID |
| Name | string | Instance name |
| VMSize | string | VM SKU |
| PowerState | string | Power state |

### metrics-baseline.json

Array of Azure Monitor metric datapoints (configurable lookback period, default 7 days).

| Field | Type | Description |
|-------|------|-------------|
| VmId | string | VM ARM resource ID |
| Metric | string | Metric name (e.g., "Percentage CPU") |
| Aggregation | string | Average or Maximum |
| TimeStamp | datetime | Datapoint timestamp |
| Value | double | Metric value |

Collected metrics:
- `Percentage CPU` — CPU utilization percentage
- `Available Memory Bytes` — Available memory in bytes
- `OS Disk IOPS Consumed Percentage` — OS disk IOPS utilization
- `OS Disk Queue Depth` — OS disk queue depth
- `Data Disk IOPS Consumed Percentage` — Data disk IOPS utilization

### metrics-incident.json

Same schema as `metrics-baseline.json`, covering the incident window period. Only present when collected with `-IncludeIncidentWindow`.

### la-results.json

Array of KQL query results from Log Analytics workspaces. Each row includes metadata fields plus query-specific columns.

| Field | Type | Description |
|-------|------|-------------|
| WorkspaceResourceId | string | Workspace ARM ID |
| Label | string | Query label (e.g., "CurrentWindow_WVDConnections") |
| QueryName | string | "AVD" for data rows, "Meta" for status rows |

Status rows (when a query fails or returns no data):

| Field | Type | Description |
|-------|------|-------------|
| Status | string | InvalidWorkspaceId, WorkspaceNotFound, QueryFailed, NoRowsReturned |
| Error | string | Error message (when Status is QueryFailed) |
| RowCount | int | Always 0 for status rows |

### diagnostic-readiness.json

Array of diagnostic capability assessments per Log Analytics table group. Only present when table discovery data is available.

| Field | Type | Description |
|-------|------|-------------|
| Group | string | Diagnostic capability group name (e.g., "AVD Connections") |
| Tables | string | Comma-separated required LA table names for the group |
| Available | bool | True if all tables in the group were discovered |
| Required | bool | Whether the group is considered required vs optional |
| Purpose | string | Human-readable explanation of what the data enables |

### capacity-reservation-groups.json

Collected when `-IncludeCapacityReservations` is specified.

| Field | Type | Description |
|-------|------|-------------|
| GroupName | string | CRG name |
| ReservationName | string | Individual reservation name |
| SKU | string | Reserved VM SKU |
| AllocatedCapacity | int | Reserved capacity |
| UtilizedVMs | int | VMs using the reservation |
| VMReferences | string | Semicolon-separated VM ARM IDs |

### quota-usage.json

Collected when `-IncludeQuotaUsage` is specified.

| Field | Type | Description |
|-------|------|-------------|
| Region | string | Azure region |
| Family | string | VM family name |
| FamilyCode | string | API family code |
| CurrentUsage | int | Current vCPU usage |
| Limit | int | Quota limit |
| Available | int | Available vCPUs |
| UsagePct | double | Usage percentage |

---

## Extended Collection — Cost Data

Collected when `-IncludeCostData` is specified. Requires Cost Management Reader role.

### actual-cost-data.json

Array of per-resource daily cost rows from Azure Cost Management API.

| Field | Type | Description |
|-------|------|-------------|
| SubscriptionId | string | Azure subscription ID |
| ResourceId | string | ARM resource ID |
| ResourceName | string | Resource name (last segment of ResourceId) |
| ResourceType | string | Azure resource type (e.g., Microsoft.Compute/virtualMachines) |
| MeterCategory | string | Cost meter category |
| PricingModel | string | Pricing model (e.g., OnDemand, Reservation) |
| Date | string/int | Usage date (format varies by billing type) |
| Cost | double | Row cost amount |
| Currency | string | Currency code (USD) |

### vm-actual-monthly-cost.json

Array of per-VM monthly cost aggregations.

| Field | Type | Description |
|-------|------|-------------|
| VMName | string | VM name |
| MonthlyCost | double | Total cost over the lookback period |

### infra-cost-data.json

Array of infrastructure cost rows grouped by resource type and meter category.

| Field | Type | Description |
|-------|------|-------------|
| SubscriptionId | string | Azure subscription ID |
| ResourceGroup | string | AVD resource group |
| ResourceType | string | Grouped Azure resource type |
| MeterCategory | string | Grouped meter category |
| MonthlyEstimate | double | Cost estimate rounded to 2 decimals |
| Currency | string | Currency code (USD) |

### cost-access.json

Single object recording which subscriptions had Cost Management API access.

| Field | Type | Description |
|-------|------|-------------|
| Granted | array of string | Subscription IDs where Cost Management returned HTTP 200 |
| Denied | array of string | Subscription IDs where Cost Management was denied |

---

## Extended Collection — Network Topology

Collected when `-IncludeNetworkTopology` is specified.

### subnet-analysis.json

Array of subnet details with IP utilization and security posture.

| Field | Type | Description |
|-------|------|-------------|
| SubscriptionId | string | Azure subscription ID |
| SubnetId | string | Subnet ARM ID |
| SubnetName | string | Subnet name |
| VNetName | string | Parent VNet name |
| AddressPrefix | string | Subnet CIDR (e.g., 10.0.1.0/24) |
| CIDR | int | Mask length |
| TotalIPs | int | Total IPv4 addresses in CIDR block |
| UsableIPs | int | TotalIPs minus 5 Azure-reserved addresses |
| UsedIPs | int | Count of subnet IP configurations |
| AvailableIPs | int | UsableIPs minus UsedIPs (floor 0) |
| UsagePct | double | Percent utilization of usable IPs |
| HasNSG | bool | Whether subnet has an NSG |
| NsgId | string | NSG ARM ID (empty if none) |
| HasRouteTable | bool | Whether subnet has a route table |
| RouteTableId | string | Route table ARM ID (empty if none) |
| HasNatGateway | bool | Whether subnet has a NAT gateway |
| NatGatewayId | string | NAT gateway ARM ID (empty if none) |
| SessionHostVMs | int | Count of session host VMs on this subnet |
| HostPools | string | Semicolon-separated host pool names using this subnet |
| IsPrivateSubnet | bool | True when no NAT gateway, no public IP, and has NSG or route table |
| HasLoadBalancer | bool | True if subnet has load balancer IP configs |
| HasPublicIP | bool | True if subnet has public IP associations |

### vnet-analysis.json

Array of VNet topology summaries.

| Field | Type | Description |
|-------|------|-------------|
| SubscriptionId | string | Azure subscription ID |
| VNetName | string | VNet name |
| Location | string | Azure region |
| AddressSpace | string | Semicolon-separated VNet address prefixes |
| DnsServers | string | Semicolon-separated DNS server IPs |
| DnsType | string | "Custom" if DNS servers exist, otherwise "Azure Default" |
| PeeringCount | int | Number of VNet peerings |
| DisconnectedPeers | int | Peerings not in Connected state |
| SubnetCount | int | Number of subnets in the VNet |

### private-endpoint-findings.json

Array of host pool private endpoint assessments.

| Field | Type | Description |
|-------|------|-------------|
| ResourceType | string | "HostPool" |
| ResourceName | string | Host pool name |
| HasPrivateEndpoint | bool | True if private endpoint connections exist |
| EndpointCount | int | Number of private endpoint connections |
| Subresources | string | Comma-separated unique GroupId values |
| Status | string | Comma-separated connection statuses, or "None" |

### workspace-private-endpoints.json

Array of AVD workspace private endpoint assessments.

| Field | Type | Description |
|-------|------|-------------|
| ResourceType | string | "Workspace" |
| ResourceName | string | Workspace name |
| HasPrivateEndpoint | bool | True if private endpoint connections exist |
| EndpointCount | int | Number of private endpoint connections |
| Subresources | string | Comma-separated unique GroupId values |
| HasFeedPE | bool | True when subresource list contains "feed" |
| HasGlobalPE | bool | True when subresource list contains "global" |
| Status | string | Comma-separated connection statuses, or "None" |

### nsg-rule-findings.json

Array of risky NSG inbound rules. Only includes rules flagged as security risks (inbound allow with wildcard ports or management port exposure from any/Internet source).

| Field | Type | Description |
|-------|------|-------------|
| NsgName | string | NSG name |
| RuleName | string | Security rule name |
| Direction | string | "Inbound" |
| Access | string | "Allow" |
| Priority | int | NSG rule priority |
| DestinationPorts | string | Destination port range(s) |
| SourceAddress | string | Source address prefix(es) |
| Risk | string | "Critical" for wildcard port, "High" for RDP/SSH exposure |

---

## Extended Collection — Image Analysis

Collected when `-IncludeImageAnalysis` is specified.

### gallery-analysis.json

Array of Azure Compute Gallery image summaries.

| Field | Type | Description |
|-------|------|-------------|
| GalleryName | string | Compute Gallery name |
| ImageName | string | Gallery image definition name |
| VersionCount | int | Number of image versions |
| LatestVersion | string | Most recent version name, or "None" |
| VMCount | int | Number of VMs using this gallery image |

### gallery-image-details.json

Array of individual gallery image version details.

| Field | Type | Description |
|-------|------|-------------|
| GalleryName | string | Compute Gallery name |
| ImageName | string | Image definition name |
| Version | string | Image version string |
| Location | string | Azure region |
| ProvState | string | Provisioning state |
| CreatedDate | datetime | Published date |
| EndOfLife | datetime | End-of-life date (if set) |
| ReplicaCount | int | Number of target replication regions |

### marketplace-image-details.json

Array of marketplace image version summaries for images in use.

| Field | Type | Description |
|-------|------|-------------|
| Publisher | string | Marketplace publisher |
| Offer | string | Marketplace offer |
| Sku | string | Marketplace SKU |
| LatestVersion | string | Most recent available version, or "Unknown" |
| VersionCount | int | Number of versions found (top 5) |
| VMCount | int | Number of VMs using this publisher/offer/SKU |

---

## Extended Collection — Storage Analysis

Collected when `-IncludeStorageAnalysis` is specified.

### fslogix-storage-analysis.json

Array of storage account and file share details for AVD resource groups.

| Field | Type | Description |
|-------|------|-------------|
| SubscriptionId | string | Azure subscription ID |
| ResourceGroup | string | Resource group |
| StorageAccountName | string | Storage account name |
| ShareName | string | File share name |
| SkuName | string | Storage SKU (e.g., Standard_LRS), or "Unknown" |
| Kind | string | Storage account kind |
| AccessTier | string | Access tier (if set) |
| QuotaGB | int | Configured share quota in GiB |
| UsedGB | double | Consumed space in GiB |
| UsagePct | double | Usage percentage |
| HasPrivateEndpoint | bool | Storage account has private endpoints |
| IsFSLogixLikely | bool | Heuristic flag from share name pattern (fslogix/profile/odfc/msix) |
| LargeFileShares | bool | Large file shares enabled |
| Location | string | Azure region |

### fslogix-shares.json

Filtered subset of `fslogix-storage-analysis.json` where `IsFSLogixLikely` is true. Same schema as above.

---

## Extended Collection — Orphaned Resources

Collected when `-IncludeOrphanedResources` is specified.

### orphaned-resources.json

Array of unattached or unused resources across AVD resource groups.

| Field | Type | Description |
|-------|------|-------------|
| SubscriptionId | string | Azure subscription ID |
| ResourceType | string | "ManagedDisk", "NetworkInterface", or "PublicIP" |
| ResourceName | string | Resource name |
| ResourceGroup | string | Resource group |
| Details | string | Human-readable orphan reason and context |
| EstMonthlyCost | double | Estimated monthly cost impact |
| CreatedDate | datetime | Creation timestamp (if available) |

---

## Extended Collection — Diagnostics & Alerts

### diagnostic-settings.json

Collected when `-IncludeDiagnosticSettings` is specified. Array of host pool diagnostic log configuration.

| Field | Type | Description |
|-------|------|-------------|
| ResourceType | string | "HostPool" |
| ResourceName | string | Host pool name |
| ResourceId | string | ARM resource ID |
| SettingsCount | int | Number of diagnostic settings |
| HasDiagnostics | bool | True when SettingsCount > 0 |
| WorkspaceTargets | string | Semicolon-separated workspace ARM IDs targeted |

### alert-rules.json

Collected when `-IncludeAlertRules` is specified. Array of Azure Monitor alert rules scoped to AVD resource groups. Includes metric alerts, scheduled query rules, and activity log alerts.

| Field | Type | Description |
|-------|------|-------------|
| SubscriptionId | string | Azure subscription ID |
| ResourceGroup | string | Resource group |
| AlertName | string | Alert rule name |
| Severity | string/int | Alert severity (Sev0-Sev4) |
| Enabled | bool | Whether the alert rule is enabled |
| Description | string | Rule description |
| TargetType | string | Target classification (resource type, "ScheduledQueryRule", "ServiceHealth", "ActivityLogAlert") |
| ServicesCovered | string | Comma-separated impacted services (activity log alerts only) |

### alert-history.json

Collected when `-IncludeAlertRules` is specified. Array of fired alert instances from the last 30 days.

| Field | Type | Description |
|-------|------|-------------|
| AlertId | string | Alert instance ID |
| Severity | string | Alert severity |
| SignalType | string | Signal type |
| AlertState | string | Current alert state |
| MonitorCondition | string | Monitor condition |
| TargetResource | string | Target resource name |
| TargetResourceType | string | Target resource type |
| MonitorService | string | Azure Monitor service |
| AlertRuleName | string | Source alert rule name |
| StartDateTime | datetime | Alert start timestamp |
| LastModifiedDateTime | datetime | Last update timestamp |
| MonitorConditionResolvedDateTime | datetime | Resolution timestamp (if resolved) |

### activity-log.json

Collected when `-IncludeActivityLog` is specified. Array of Activity Log entries (last 7 days) per AVD resource group.

| Field | Type | Description |
|-------|------|-------------|
| SubscriptionId | string | Azure subscription ID |
| ResourceGroup | string | Resource group |
| Timestamp | datetime | Event timestamp |
| Category | string | Activity log category |
| OperationName | string | Operation name |
| Status | string | Operation status |
| Level | string | Activity log level |
| Caller | string | Caller identity |
| ResourceId | string | ARM resource ID |
| Description | string | Status message from log properties |

---

## Extended Collection — Governance

### policy-assignments.json

Collected when `-IncludePolicyAssignments` is specified. Array of Azure Policy assignments scoped to AVD resource groups.

| Field | Type | Description |
|-------|------|-------------|
| SubscriptionId | string | Azure subscription ID |
| ResourceGroup | string | Resource group |
| AssignmentName | string | Policy assignment name |
| DisplayName | string | Friendly display name |
| PolicyDefId | string | Policy definition ARM ID |
| EnforcementMode | string | Enforcement mode |
| Scope | string | Assignment scope ARM ID |

### resource-tags.json

Collected when `-IncludeResourceTags` is specified. Array of tag key-value pairs from VMs and host pools.

| Field | Type | Description |
|-------|------|-------------|
| ResourceType | string | "VirtualMachine" or "HostPool" |
| ResourceName | string | Resource name |
| ResourceGroup | string | Resource group |
| TagKey | string | Tag key |
| TagValue | string | Tag value |

---

## Optional Integrations

### reserved-instances.json

Collected when `-IncludeReservedInstances` is specified. Requires `Az.Reservations` module and Reservations Reader role.

| Field | Type | Description |
|-------|------|-------------|
| ReservationId | string | Reservation ARM ID |
| ReservationName | string | Display name |
| SKU | string | Reserved SKU / resource type |
| Location | string | Reservation location |
| Quantity | int | Reserved quantity |
| ProvisioningState | string | Provisioning state |
| ExpiryDate | datetime | Expiry date |
| EffectiveDate | datetime | Start/effective date |
| Term | string | Reservation term (P1Y, P3Y) |
| AppliedScopeType | string | Scope type |
| Status | string | "Active" when Succeeded, otherwise provisioning state |
| DaysUntilExpiry | int/string | Days remaining or "Unknown" |

### intune-managed-devices.json

Collected when `-IncludeIntune` is specified. Requires `Microsoft.Graph.Authentication` module and `DeviceManagementManagedDevices.Read.All` permission. Only Windows devices are included.

| Field | Type | Description |
|-------|------|-------------|
| DeviceName | string | Device name (matches session host VM name for cross-reference) |
| ComplianceState | string | Intune compliance state (compliant, noncompliant, unknown, etc.) |
| IsEncrypted | bool | Whether the device reports disk encryption |
| OperatingSystem | string | OS type (always "Windows" — filtered during collection) |
| OsVersion | string | OS version string |
| ManagementAgent | string | Management agent type (mdm, easMdm, etc.) |
| EnrolledDateTime | string | ISO 8601 enrollment timestamp |
| LastSyncDateTime | string | ISO 8601 last sync timestamp |
| AzureADDeviceId | string | Entra ID device object ID |
| Model | string | Device model |
| Manufacturer | string | Device manufacturer |
| OwnerType | string | Device ownership (company, personal) |

### conditional-access-policies.json

Collected when `-IncludeIntune` is specified. Requires `Policy.Read.All` Graph permission.

| Field | Type | Description |
|-------|------|-------------|
| DisplayName | string | CA policy display name |
| State | string | Policy state (enabled, disabled, enabledForReportingButNotEnforced) |
| IncludeApplications | array | Included application IDs/keywords |
| ExcludeApplications | array | Excluded application IDs/keywords |
| IncludeUsers | array | Included users scope |
| IncludeGroups | array | Included group IDs |
| BuiltInControls | array | Grant controls (e.g., mfa, compliantDevice) |
| GrantOperator | string | Grant operator (AND/OR) |
| SignInFrequency | object | Session control for sign-in frequency |
| PersistentBrowser | object | Session control for persistent browser |
| IncludeLocations | array | Included named locations |
| IncludePlatforms | array | Included device platforms |

---

## Internal / Diagnostic Files

### diagnostic-events.json

Collector diagnostic log. Only present when warnings, errors, or skipped steps occurred during collection.

| Field | Type | Description |
|-------|------|-------------|
| Timestamp | string | Event timestamp (yyyy-MM-dd HH:mm:ss) |
| Severity | string | "Warn", "Error", or "Skip" |
| Step | string | Collection step/category name |
| Message | string | Diagnostic message text |
| ErrorDetail | string | Detailed error text (if available) |

---

## Compatibility

This schema is designed for compatibility with [Aperture](https://github.com/intrepidtechie/aperture-assessment) (`-CollectionPack` parameter). Aperture validates `SchemaVersion` in `collection-metadata.json` and supports versions `1.1` and `2.0`.

### Notes for Consumers

- All JSON files use UTF-8 encoding
- Arrays may be empty `[]` if no data was collected for that category
- DateTime values are in ISO 8601 format
- The `Tags` field in `virtual-machines.json` is a key-value object `{ "tag1": "value1" }`
- `SkipActualCosts` is dynamically set based on whether `-IncludeCostData` was used. When cost data is collected, this is `false`; otherwise `true`
- When `-ScrubPII` is enabled, identifiable fields (VM names, host pool names, usernames, IPs, subscription IDs, resource groups, ARM IDs) are replaced with deterministic SHA256-based anonymous IDs. Same entity maps to the same ID within a run, preserving correlations
- Extended collection files are only present when the corresponding parameter flag was enabled during collection

### Complete File Listing

| File | Category | Condition |
|------|----------|-----------|
| collection-metadata.json | Core | Always |
| host-pools.json | Core | Always |
| session-hosts.json | Core | Always |
| virtual-machines.json | Core | Always |
| avd-workspaces.json | Core | Always |
| app-groups.json | Core | Always |
| scaling-plans.json | Core | Always |
| scaling-plan-assignments.json | Core | Always |
| scaling-plan-schedules.json | Core | Always |
| vmss.json | Core | Always |
| vmss-instances.json | Core | Always |
| capacity-reservation-groups.json | Core | `-IncludeCapacityReservations` |
| metrics-baseline.json | Metrics | Unless `-SkipAzureMonitorMetrics` |
| metrics-incident.json | Metrics | `-IncludeIncidentWindow` |
| la-results.json | KQL | Unless `-SkipLogAnalyticsQueries` |
| diagnostic-readiness.json | KQL | When table discovery data available |
| quota-usage.json | Extended | `-IncludeQuotaUsage` |
| actual-cost-data.json | Cost | `-IncludeCostData` |
| vm-actual-monthly-cost.json | Cost | `-IncludeCostData` |
| infra-cost-data.json | Cost | `-IncludeCostData` |
| cost-access.json | Cost | Always (records API access status) |
| subnet-analysis.json | Network | `-IncludeNetworkTopology` |
| vnet-analysis.json | Network | `-IncludeNetworkTopology` |
| private-endpoint-findings.json | Network | `-IncludeNetworkTopology` |
| workspace-private-endpoints.json | Network | `-IncludeNetworkTopology` |
| nsg-rule-findings.json | Network | `-IncludeNetworkTopology` |
| gallery-analysis.json | Images | `-IncludeImageAnalysis` |
| gallery-image-details.json | Images | `-IncludeImageAnalysis` |
| marketplace-image-details.json | Images | `-IncludeImageAnalysis` |
| fslogix-storage-analysis.json | Storage | `-IncludeStorageAnalysis` |
| fslogix-shares.json | Storage | `-IncludeStorageAnalysis` |
| orphaned-resources.json | Governance | `-IncludeOrphanedResources` |
| diagnostic-settings.json | Diagnostics | `-IncludeDiagnosticSettings` |
| alert-rules.json | Diagnostics | `-IncludeAlertRules` |
| alert-history.json | Diagnostics | `-IncludeAlertRules` |
| activity-log.json | Diagnostics | `-IncludeActivityLog` |
| policy-assignments.json | Governance | `-IncludePolicyAssignments` |
| resource-tags.json | Governance | `-IncludeResourceTags` |
| reserved-instances.json | Integration | `-IncludeReservedInstances` |
| intune-managed-devices.json | Integration | `-IncludeIntune` |
| conditional-access-policies.json | Integration | `-IncludeIntune` |
| diagnostic-events.json | Internal | When warnings/errors/skips occurred |
