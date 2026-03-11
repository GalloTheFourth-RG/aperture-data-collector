# Collection Pack Schema Reference

The AVD Data Collector outputs a collection pack — a ZIP archive containing JSON files that describe your AVD environment. This document details the schema for each file.

## Schema Version

Current schema version: **2.0**

The schema version is recorded in `collection-metadata.json` and used by consumer tools to validate compatibility.

| Schema Version | Collector Version | Notes |
|---------------|-------------------|-------|
| 2.0 | 1.1.0 | Extended collection (cost, network, storage, images, governance), diagnostic readiness |
| 1.1 | 1.0.0 | Initial release, compatible with Enhanced AVD Evidence Pack v4.12.0+ |

---

## File Reference

### collection-metadata.json

Top-level metadata about the collection run.

```json
{
  "SchemaVersion": "2.0",
  "ScriptVersion": "1.2.0",
  "CollectionTimestamp": "2026-03-01 12:00:00 UTC",
  "SubscriptionIds": ["xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"],
  "TenantId": "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx",
  "MetricsLookbackDays": 7,
  "IncidentWindowQueried": false,
  "SkipAzureMonitorMetrics": false,
  "SkipLogAnalyticsQueries": false,
  "SkipActualCosts": false,
  "Counts": {
    "HostPools": 5,
    "SessionHosts": 120,
    "VMs": 120,
    "VMSS": 0,
    "Metrics": 8400,
    "KQLResults": 350,
    "AppGroups": 6,
    "ScalingPlans": 3
  },
  "AnalysisErrors": [],
  "CollectorTool": "avd-data-collector",
  "CollectorVersion": "1.0.0"
}
```

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

### metrics-baseline.json

Array of Azure Monitor metric datapoints.

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

Same schema as `metrics-baseline.json`, covering the incident window period (if collected with `-IncludeIncidentWindow`).

### la-results.json

Array of KQL query results. Each row includes metadata fields plus the query-specific columns.

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

### scaling-plans.json

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

| Field | Type | Description |
|-------|------|-------------|
| ScalingPlanName | string | Parent scaling plan |
| HostPoolArmId | string | Target host pool ARM ID |
| HostPoolName | string | Target host pool name |
| IsEnabled | bool | Whether scaling is active |

### scaling-plan-schedules.json

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

### app-groups.json

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

### vmss.json

| Field | Type | Description |
|-------|------|-------------|
| SubscriptionId | string | Azure subscription ID |
| VMSSName | string | Scale set name |
| VMSize | string | VM SKU |
| Capacity | int | Current instance count |
| Location | string | Azure region |
| Zones | string | Availability zones |

### vmss-instances.json

| Field | Type | Description |
|-------|------|-------------|
| VMSSName | string | Parent scale set |
| InstanceId | string | Instance ID |
| Name | string | Instance name |
| VMSize | string | VM SKU |
| PowerState | string | Power state |

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

## Compatibility

This schema is designed for compatibility with the [Enhanced AVD Evidence Pack](https://github.com/intrepidtechie/enhanced-avd-evidence-pack) `-CollectionPack` parameter. The Evidence Pack validates `SchemaVersion` in `collection-metadata.json` and supports versions `1.1` and `2.0`.

### Notes for Consumers

- All JSON files use UTF-8 encoding
- Arrays may be empty `[]` if no data was collected for that category
- DateTime values are in ISO 8601 format
- The `Tags` field in `virtual-machines.json` is a key-value object `{ "tag1": "value1" }`
- `SkipActualCosts` is dynamically set based on whether `-IncludeCostData` was used. When cost data is collected, this is `false`; otherwise `true`
