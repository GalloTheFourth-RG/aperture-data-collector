# Examples

Usage examples for the AVD Data Collector.

## Quick Collection

```powershell
# Minimal — ARM inventory only (fastest, ~2-3 min)
.\Collect-AVDData.ps1 `
    -TenantId "your-tenant-id" `
    -SubscriptionIds @("your-sub-id") `
    -SkipAzureMonitorMetrics `
    -SkipLogAnalyticsQueries `
    -SkipDisclaimer
```

## Full Collection

```powershell
# Full collection with all data sources
.\Collect-AVDData.ps1 `
    -TenantId "your-tenant-id" `
    -SubscriptionIds @("sub-id-1", "sub-id-2") `
    -LogAnalyticsWorkspaceResourceIds @(
        "/subscriptions/xxx/resourceGroups/rg/providers/Microsoft.OperationalInsights/workspaces/ws1"
    ) `
    -IncludeCapacityReservations `
    -IncludeQuotaUsage `
    -SkipDisclaimer
```

## Incident Investigation

```powershell
# Collect baseline + incident window for comparison
.\Collect-AVDData.ps1 `
    -TenantId "your-tenant-id" `
    -SubscriptionIds @("your-sub-id") `
    -LogAnalyticsWorkspaceResourceIds @("workspace-id") `
    -IncludeIncidentWindow `
    -IncidentWindowStart (Get-Date "2025-05-28 14:00") `
    -IncidentWindowEnd (Get-Date "2025-05-28 16:00") `
    -MetricsLookbackDays 14 `
    -SkipDisclaimer
```

## Multi-Subscription with Custom Output

```powershell
# Collect from multiple subscriptions, output to specific path
.\Collect-AVDData.ps1 `
    -TenantId "your-tenant-id" `
    -SubscriptionIds @("sub-1", "sub-2", "sub-3") `
    -LogAnalyticsWorkspaceResourceIds @("ws-1", "ws-2") `
    -OutputPath "C:\AVD-Collections" `
    -MetricsLookbackDays 14 `
    -MetricsTimeGrainMinutes 5 `
    -SkipDisclaimer
```

## Feed into Aperture (AVD Health Intelligence)

```powershell
# Step 1: Collect (run in customer environment)
.\Collect-AVDData.ps1 `
    -TenantId $tenantId `
    -SubscriptionIds $subIds `
    -LogAnalyticsWorkspaceResourceIds $wsIds `
    -SkipDisclaimer

# Step 2: Analyze offline (run anywhere — no Azure needed)
.\Aperture-Assessment.ps1 `
    -CollectionPack "AVD-CollectionPack-20250601-120000.zip"
```
