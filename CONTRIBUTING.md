# Contributing to Aperture Data Collector

Thanks for your interest in contributing! This project welcomes contributions in the form of bug fixes, new KQL queries, documentation improvements, and feature enhancements.

## How to Contribute

### Reporting Issues

- Use GitHub Issues for bug reports and feature requests
- Include your PowerShell version (`$PSVersionTable`), Az module versions, and any error messages
- Sanitize any Azure resource IDs, subscription IDs, or other sensitive data before sharing

### Pull Requests

1. Fork the repository
2. Create a feature branch (`git checkout -b feature/my-improvement`)
3. Make your changes
4. Test locally against an AVD environment if possible
5. Submit a pull request with a clear description

### Adding a New KQL Query

1. Create a new `.kql` file in the `queries/` directory
2. Follow the naming convention: `kqlYourQueryName.kql`
3. Add the query dispatch entry in `src/Collect-ApertureData.ps1` (in the `$queryDispatchList` array)
4. Use appropriate label format: `CurrentWindow_YourQueryName`
5. Update `docs/QUERIES.md` with a description of what the query collects

### KQL Query Guidelines

- Use `union isfuzzy=true` with a fallback empty row when the table might not exist
- Filter with `| where TimeGenerated > ago(14d)` in discovery queries
- Use `| take` limits on expensive queries to prevent workspace overload
- Use `dcount()` over `count(distinct ...)` for Kusto performance
- Add comments in the `.kql` file if the query logic is complex

## Code Style

- Use `Set-StrictMode -Version Latest` compatible patterns
- Always null-check with `SafeProp`, `SafeArray`, `SafeCount` helpers
- Wrap API calls in `try/catch` — failures should warn, not crash
- Use `[System.Collections.Generic.List[object]]::new()` for data containers (not arrays)
- Prefer bulk API calls over per-resource calls (e.g., `Get-AzVM -ResourceGroupName` over `Get-AzVM -Name`)

## Testing

Since this tool runs against live Azure environments, full integration testing requires an AVD deployment. However:

- **Syntax check**: `pwsh -Command "& { [System.Management.Automation.Language.Parser]::ParseFile('src/Collect-ApertureData.ps1', [ref]$null, [ref]$null) }"`
- **Dry run**: Use `-DryRun` to validate parameter handling and environment detection
- Ensure the output ZIP can be imported by Aperture (`aperture-assessment`) with `-CollectionPack`

## License

By contributing, you agree that your contributions will be licensed under the MIT License.
