# KQL Query Reference

The Aperture Data Collector includes 36 pre-built KQL queries that run against Log Analytics workspaces. Each query targets specific AVD diagnostic tables and performance counters.

## Prerequisites

Your Log Analytics workspace must have AVD Diagnostics configured. The collector runs `TableDiscovery` first to verify which tables are available.

Required tables vary by query category:
- **WVDConnections** — connection, login, concurrency queries
- **WVDErrors** — error classification, disconnect analysis
- **WVDConnectionNetworkData** — RTT, bandwidth, Shortpath effectiveness
- **WVDCheckpoints** — Shortpath detection, login decomposition
- **WVDAgentHealthStatus** — agent health, version distribution
- **WVDAutoscaleEvaluationPooled** — autoscale activity
- **WVDMultiLinkAdd** — multi-link transport analysis
- **Perf** — CPU/memory process-level performance
- **Event** — Windows event log data

---

## Query Categories

### Connections & Sessions

| Query | File | Description |
|-------|------|-------------|
| WVD Connections | `kqlWvdConnections.kql` | Connection summary by user and client OS |
| Connection Success Rate | `kqlConnectionSuccessRate.kql` | Per-host-pool success/failure rates |
| Login Time | `kqlLoginTime.kql` | Login duration percentiles by host pool |
| Session Duration | `kqlSessionDuration.kql` | Average and max session length by user |
| Peak Concurrency | `kqlPeakConcurrency.kql` | Maximum concurrent sessions (15-min bins) |
| Hourly Concurrency | `kqlHourlyConcurrency.kql` | Weekday concurrency patterns by hour |
| Connection Environment | `kqlConnectionEnvironment.kql` | Join type, OS version, OS description distribution |

### Errors & Disconnects

| Query | File | Description |
|-------|------|-------------|
| Connection Errors | `kqlConnectionErrors.kql` | Top 50 errors by code and message |
| Error Classification | `kqlErrorClassification.kql` | Errors grouped by symbolic code, source, and operation |
| Disconnects | `kqlDisconnects.kql` | Unexpected disconnects (<60s sessions) per host |
| Disconnect Reasons | `kqlDisconnectReasons.kql` | Categorized disconnect causes (network, auth, server, etc.) |
| Disconnects by Host | `kqlDisconnectsByHost.kql` | Per-host breakdown: network drops, timeouts, auth failures, resource issues |
| Disconnect Heatmap | `kqlDisconnectHeatmap.kql` | Abnormal disconnects by hour-of-day and day-of-week |
| Disconnect CPU Correlation | `kqlDisconnectCpuCorrelation.kql` | Pre-disconnect CPU levels to identify resource-driven disconnects |
| Reconnection Loops | `kqlReconnectionLoops.kql` | Users with 3+ reconnects within 30-minute windows |

### Network & Shortpath

| Query | File | Description |
|-------|------|-------------|
| Connection Quality | `kqlConnectionQuality.kql` | RTT and bandwidth statistics by client OS |
| Connection Quality by Region | `kqlConnectionQualityByRegion.kql` | RTT and bandwidth by gateway region |
| Cross-Region Connections | `kqlCrossRegionConnections.kql` | RTT breakdown per gateway-region × session-host pair |
| Shortpath Usage | `kqlShortpathUsage.kql` | Transport type distribution (Shortpath UDP vs TCP/WebSocket) |
| Shortpath Effectiveness | `kqlShortpathEffectiveness.kql` | RTT and disconnect rate comparison: Shortpath vs TCP |
| Shortpath by Client | `kqlShortpathByClient.kql` | Transport type by client OS, type, and version |
| Shortpath by Gateway | `kqlShortpathByGateway.kql` | Transport type and Private Link usage by gateway region |
| Shortpath Transport RTT | `kqlShortpathTransportRTT.kql` | RTT and bandwidth by transport category |
| Multi-Link Transport | `kqlMultiLinkTransport.kql` | Multi-link transport type distribution |

### Performance

| Query | File | Description |
|-------|------|-------------|
| Process CPU | `kqlProcessCpu.kql` | Per-process CPU usage by host (top 200 by P95) |
| Process CPU Summary | `kqlProcessCpuSummary.kql` | Fleet-wide process CPU summary (top 50 processes) |
| Process Memory | `kqlProcessMemory.kql` | Per-process memory (Working Set) summary |
| CPU Percentiles | `kqlCpuPercentiles.kql` | Per-host CPU percentiles with spike analysis and sizing confidence |

### Profiles & Login

| Query | File | Description |
|-------|------|-------------|
| Profile Load Performance | `kqlProfileLoadPerformance.kql` | Per-host profile load time percentiles, slow login detection |
| Checkpoint Login Decomposition | `kqlCheckpointLoginDecomposition.kql` | Full login phase timing: brokering → auth → transport → logon → shell |

### Agent Health

| Query | File | Description |
|-------|------|-------------|
| Agent Health Status | `kqlAgentHealthStatus.kql` | Latest agent state per session host |
| Agent Version Distribution | `kqlAgentVersionDistribution.kql` | Agent and SxS stack version distribution across fleet |
| Agent Health Checks | `kqlAgentHealthChecks.kql` | Per-check pass/fail rates (domain join, URL access, IMDS, etc.) |

### Autoscale

| Query | File | Description |
|-------|------|-------------|
| Autoscale Activity | `kqlAutoscaleActivity.kql` | Autoscale evaluation result summary |
| Autoscale Detailed Activity | `kqlAutoscaleDetailedActivity.kql` | Per-pool autoscale stats: evaluations, success/fail, host/session counts |

### Discovery

| Query | File | Description |
|-------|------|-------------|
| Table Discovery | `kqlTableDiscovery.kql` | Validates which AVD diagnostic tables have recent data |

---

## Customizing Queries

All queries are plain `.kql` files in the `queries/` directory. You can:

1. **Edit existing queries** — adjust filters, time ranges, or aggregation
2. **Add new queries** — create a new `.kql` file and add a dispatch entry in `Collect-ApertureData.ps1`
3. **Remove queries** — delete the `.kql` file; the collector skips missing queries automatically

### Adding a New Query

1. Create `queries/kqlMyNewQuery.kql` with your KQL
2. Add to the `$queryDispatchList` in `Collect-ApertureData.ps1`:
   ```powershell
   @{ Label = "CurrentWindow_MyNewQuery"; Query = $kqlQueries["kqlMyNewQuery"] }
   ```
3. The results will automatically be included in `la-results.json`

### Query Timeout Considerations

Log Analytics queries don't have a configurable timeout. For large workspaces (>1TB retention), consider:
- Adding `| take N` limits to expensive queries
- Using `| where TimeGenerated > ago(7d)` to limit scan range
- Splitting complex joins into simpler queries
