<#
.SYNOPSIS
  Turns ON "Azure SQL Databases" (Microsoft.Security/pricings/SqlServers) and optionally
  express vulnerability assessment on one managed instance.
  SAFETY: GET/PUT only; PUT limited to those two Microsoft.Security settings;
          no database access; dry run unless -Apply is passed.
#>
param(
  [Parameter(Mandatory)][string]$SubscriptionId,
  [string]$ExpectedSubscriptionName = 'ba-ise-at33658-nch-preprod',
  [bool]$EnableSqlPlan = $true,
  [switch]$EnableExpressVA,
  [string]$ResourceGroup,
  [string]$ManagedInstanceName,
  [switch]$Apply            # without this switch, the script is a dry run
)

$ErrorActionPreference = 'Stop'
$dryRun = -not $Apply
if ($dryRun) { Write-Host "*** DRY RUN: nothing will be changed (use -Apply to change) ***" -ForegroundColor Yellow }

# ---------- Token from your own az login ----------
$token = az account get-access-token --resource https://management.azure.com --subscription $SubscriptionId --query accessToken -o tsv
if ([string]::IsNullOrWhiteSpace($token)) { throw "Could not get a token. Run 'az login' first." }
$headers = @{ Authorization = "Bearer $token" }
$arm = 'https://management.azure.com'
$sub = $SubscriptionId

function Invoke-Arm {
  param(
    [Parameter(Mandatory)][ValidateSet('GET','PUT')][string]$Method,
    [Parameter(Mandatory)][string]$Path,
    $Body,
    [switch]$AllowNotFound
  )
  if ($Method -eq 'PUT') {
    $okPlan = $Path -match '^/subscriptions/[^/]+/providers/Microsoft\.Security/pricings/SqlServers\?'
    $okVa   = $Path -match '^/subscriptions/[^/]+/resourceGroups/[^/]+/providers/Microsoft\.Sql/managedInstances/[^/]+/providers/Microsoft\.Security/sqlVulnerabilityAssessments/default\?'
    if (-not ($okPlan -or $okVa)) { throw "BLOCKED: PUT to an unexpected path: $Path" }
  }
  $p = @{ Method = $Method; Uri = "$arm$Path"; Headers = $headers }
  if ($Body) { $p.Body = ($Body | ConvertTo-Json -Depth 5); $p.ContentType = 'application/json' }
  try { Invoke-RestMethod @p }
  catch {
    $code = 0
    if ($_.Exception.Response) { $code = [int]$_.Exception.Response.StatusCode }
    if ($code -eq 404 -and $AllowNotFound) { return $null }
    if ($code -eq 401) { throw "401 Unauthorized: run 'az login' again (right tenant?)." }
    if ($code -eq 403) { throw "403 Forbidden: missing permission for $Path" }
    throw "HTTP $code on $Method $Path`n$($_.ErrorDetails.Message)"
  }
}

# ---------- 1. Confirm subscription ----------
$subInfo = Invoke-Arm -Method GET -Path "/subscriptions/$($sub)?api-version=2022-12-01"
Write-Host "Subscription: $($subInfo.displayName) ($sub)"
if ($ExpectedSubscriptionName -and $subInfo.displayName -ne $ExpectedSubscriptionName) {
  throw "Subscription name mismatch. Expected '$ExpectedSubscriptionName', got '$($subInfo.displayName)'."
}

# ---------- 2. Show the 4 switches ----------
$api = 'api-version=2024-01-01'
$map = [ordered]@{
  'SqlServers'                    = 'Azure SQL Databases'
  'SqlServerVirtualMachines'      = 'SQL servers on machines'
  'OpenSourceRelationalDatabases' = 'Open-source relational databases'
  'CosmosDbs'                     = 'Azure Cosmos DB'
}
Write-Host "`nCurrent Databases plan switches:"
foreach ($k in $map.Keys) {
  $t = (Invoke-Arm -Method GET -Path "/subscriptions/$sub/providers/Microsoft.Security/pricings/$($k)?$api").properties.pricingTier
  Write-Host ("  {0,-34}{1,-4} ({2})" -f $map[$k], $(if ($t -eq 'Standard') {'On'} else {'Off'}), $t)
}

# ---------- 3. Azure SQL Databases plan ----------
if ($EnableSqlPlan) {
  $planPath = "/subscriptions/$sub/providers/Microsoft.Security/pricings/SqlServers?$api"
  $tier = (Invoke-Arm -Method GET -Path $planPath).properties.pricingTier
  if ($tier -eq 'Standard') {
    Write-Host "`nAzure SQL Databases: already On (Standard). No change."
  } elseif ($dryRun) {
    Write-Host "`nDRY RUN: would change Azure SQL Databases from '$tier' to 'Standard' (On)."
    Write-Host "Applies to ALL Azure SQL resources in this subscription (list price about `$15/instance/month)."
  } else {
    Invoke-Arm -Method PUT -Path $planPath -Body @{ properties = @{ pricingTier = 'Standard' } } | Out-Null
    $tier = (Invoke-Arm -Method GET -Path $planPath).properties.pricingTier
    if ($tier -ne 'Standard') { throw "Not Standard after update (got: $tier)." }
    Write-Host "`nAzure SQL Databases: turned ON (Standard)."
  }
}

# ---------- 4. Optional express VA ----------
if ($EnableExpressVA) {
  if (-not $ResourceGroup -or -not $ManagedInstanceName) { throw "Pass -ResourceGroup and -ManagedInstanceName for express VA." }
  $miPath = "/subscriptions/$sub/resourceGroups/$ResourceGroup/providers/Microsoft.Sql/managedInstances/$ManagedInstanceName"
  $mi = Invoke-Arm -Method GET -Path "$($miPath)?api-version=2021-11-01"
  Write-Host "`nManaged instance found: $($mi.id)"

  $idType = if ($mi.identity) { $mi.identity.type } else { 'None' }
  if ($idType -notmatch 'SystemAssigned') {
    $msg = "No system-assigned identity on the instance (found: $idType). Express VA requires it."
    if ($dryRun) { Write-Warning $msg } else { throw $msg }
  } else { Write-Host "System-assigned identity: present." }

  $vaPath = "$miPath/providers/Microsoft.Security/sqlVulnerabilityAssessments/default?api-version=2026-04-01-preview"
  $va = Invoke-Arm -Method GET -Path $vaPath -AllowNotFound
  $state = if ($va) { $va.properties.state } else { 'NotConfigured' }
  if ($state -eq 'Enabled') {
    Write-Host "Express vulnerability assessment: already Enabled. No change."
  } elseif ($dryRun) {
    Write-Host "DRY RUN: would enable express vulnerability assessment (current: $state)."
  } else {
    Invoke-Arm -Method PUT -Path $vaPath -Body @{ properties = @{ state = 'Enabled' } } | Out-Null
    $state = (Invoke-Arm -Method GET -Path $vaPath).properties.state
    if ($state -ne 'Enabled') { throw "Express VA not enabled after update (state: $state)." }
    Write-Host "Express vulnerability assessment: Enabled."
  }
}

if ($dryRun) { Write-Host "`nDRY RUN complete. Re-run with -Apply to make the change." -ForegroundColor Yellow }
else { Write-Host "`nDone. Verify in Defender for Cloud > Environment settings > Defender plans > Databases > Select types." }