param([string]$Cell)
$ErrorActionPreference='Stop'
New-Item -ItemType Directory -Force -Path inventory-evidence | Out-Null
$core=@(& ./.lab/inventory/collect.ps1 -Phase runtime)
$core | Write-Output
$core | Where-Object { $_.StartsWith('{') } | Set-Content -Encoding UTF8 inventory-evidence/core.json
$supplement=@(& ./.lab/inventory/supplement.ps1 -Phase runtime)
$supplement | Write-Output
$supplement | Where-Object { $_.StartsWith('{') } | Set-Content -Encoding UTF8 inventory-evidence/supplement.json
$binding=[ordered]@{
    cell=$Cell; source_commit=(git rev-parse HEAD).Trim();
    core_sha256=(Get-FileHash ./.lab/inventory/collect.ps1 -Algorithm SHA256).Hash;
    supplement_sha256=(Get-FileHash ./.lab/inventory/supplement.ps1 -Algorithm SHA256).Hash;
    github_run_id=$env:GITHUB_RUN_ID; github_run_attempt=$env:GITHUB_RUN_ATTEMPT; github_job=$env:GITHUB_JOB
}
$binding | ConvertTo-Json -Compress | Set-Content -Encoding UTF8 inventory-evidence/binding.json
Write-Output 'INVENTORY_BINDING_JSON_BEGIN'
$binding | ConvertTo-Json -Compress
Write-Output 'INVENTORY_BINDING_JSON_END'
Write-Output 'INVENTORY_COLLECTOR_COMPLETE: no setup/install/cache/archive bridge/publish actions'
