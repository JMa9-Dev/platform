<#
.SYNOPSIS
  Azure side of the GitHub -> Azure OIDC bootstrap for one application.

.DESCRIPTION
  For each environment (default: dev only; add prod with -Environments dev,prod):
    - resource group                  rg-<app>-<env>
    - user-assigned managed identity  id-github-<app>-<env>
    - federated credential trusting   repo:<org>/<app>:environment:<env>
    - Contributor role on that resource group only
  Then in GitHub (<org>/<app>):
    - one GitHub environment per Azure environment, deployments from main only
    - prod requires approval by the signed-in GitHub user
    - environment variables AZURE_CLIENT_ID, AZURE_TENANT_ID,
      AZURE_SUBSCRIPTION_ID, AZURE_RESOURCE_GROUP
  Writes the Azure ids to bootstrap-<app>.json next to this script.
  Safe to re-run. Requires: Azure CLI, GitHub CLI, Owner on the subscription.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\bootstrap-azure.ps1 -App hello-app
#>
param(
    [Parameter(Mandatory = $true)][string]$App,
    [string]$Location = "swedencentral",
    [string]$Org = "JMa9-Dev",
    [string[]]$Environments = @("dev")
)

$ErrorActionPreference = "Stop"

function Invoke-Az {
    # Runs az and fails the script on a non-zero exit code.
    $output = & az @args
    if ($LASTEXITCODE -ne 0) { throw "az $($args -join ' ') failed (exit $LASTEXITCODE)" }
    return $output
}

function Invoke-Gh {
    # Runs gh (passing pipeline input through) and fails the script on a non-zero exit code.
    $output = $input | & gh @args
    if ($LASTEXITCODE -ne 0) { throw "gh $($args -join ' ') failed (exit $LASTEXITCODE)" }
    return $output
}

$missing = @()
if (-not (Get-Command az -ErrorAction SilentlyContinue)) { $missing += "winget install Microsoft.AzureCLI" }
if (-not (Get-Command gh -ErrorAction SilentlyContinue)) { $missing += "winget install GitHub.cli" }
if ($missing.Count -gt 0) {
    Write-Host "Missing tools. Install them with:" -ForegroundColor Red
    $missing | ForEach-Object { Write-Host "  $_" }
    Write-Host "Then open a NEW PowerShell window and run this script again."
    exit 1
}

# Sign in to GitHub if needed.
& gh auth status 2>$null | Out-Null
if ($LASTEXITCODE -ne 0) {
    Write-Host "Signing in to GitHub..."
    & gh auth login --hostname github.com --git-protocol https --web
    if ($LASTEXITCODE -ne 0) { throw "gh auth login failed" }
}

# Sign in if needed.
& az account show --output none 2>$null
if ($LASTEXITCODE -ne 0) {
    Write-Host "Signing in to Azure (a browser window opens)..."
    Invoke-Az login --output none | Out-Null
}

$subscriptionName = Invoke-Az account show --query name -o tsv
$subscriptionId   = Invoke-Az account show --query id -o tsv
$tenantId         = Invoke-Az account show --query tenantId -o tsv

Write-Host ""
Write-Host "Subscription : $subscriptionName ($subscriptionId)"
Write-Host "Repository   : $Org/$App"
Write-Host "Location     : $Location"
Write-Host "Environments : $($Environments -join ', ')"
$answer = Read-Host "Continue? [y/N]"
if ($answer -notmatch '^[Yy]$') { exit 1 }

Write-Host "==> Registering resource providers (may take a minute)"
foreach ($ns in @("Microsoft.Web", "Microsoft.ManagedIdentity")) {
    Invoke-Az provider register --namespace $ns --wait --output none | Out-Null
}

$result = [ordered]@{
    org            = $Org
    app            = $App
    tenantId       = $tenantId
    subscriptionId = $subscriptionId
    environments   = [ordered]@{}
}

foreach ($envName in $Environments) {
    $rg       = "rg-$App-$envName"
    $identity = "id-github-$App-$envName"
    $subject  = "repo:$Org/${App}:environment:$envName"

    Write-Host "==> [$envName] resource group $rg"
    Invoke-Az group create --name $rg --location $Location --tags "app=$App" "environment=$envName" --output none | Out-Null

    Write-Host "==> [$envName] managed identity $identity"
    Invoke-Az identity create --name $identity --resource-group $rg --output none | Out-Null
    $clientId    = Invoke-Az identity show --name $identity --resource-group $rg --query clientId -o tsv
    $principalId = Invoke-Az identity show --name $identity --resource-group $rg --query principalId -o tsv

    Write-Host "==> [$envName] federated credential for $subject"
    & az identity federated-credential show --name "github-$envName" --identity-name $identity --resource-group $rg --output none 2>$null
    if ($LASTEXITCODE -ne 0) {
        Invoke-Az identity federated-credential create `
            --name "github-$envName" `
            --identity-name $identity `
            --resource-group $rg `
            --issuer "https://token.actions.githubusercontent.com" `
            --subject $subject `
            --audiences "api://AzureADTokenExchange" `
            --output none | Out-Null
    }

    Write-Host "==> [$envName] Contributor role on $rg"
    $scope = "/subscriptions/$subscriptionId/resourceGroups/$rg"
    $existing = Invoke-Az role assignment list --assignee $principalId --role Contributor --scope $scope --query "length(@)" -o tsv
    if ($existing -eq "0") {
        # A new identity can take a moment to replicate; retry a few times.
        $assigned = $false
        for ($i = 1; $i -le 6 -and -not $assigned; $i++) {
            & az role assignment create `
                --assignee-object-id $principalId `
                --assignee-principal-type ServicePrincipal `
                --role Contributor `
                --scope $scope `
                --output none 2>$null
            if ($LASTEXITCODE -eq 0) { $assigned = $true } else { Start-Sleep -Seconds 10 }
        }
        if (-not $assigned) { throw "Role assignment failed for $identity" }
    }

    $result.environments[$envName] = [ordered]@{
        resourceGroup = $rg
        clientId      = $clientId
    }
}

$outFile = Join-Path $PSScriptRoot "bootstrap-$App.json"
$result | ConvertTo-Json -Depth 5 | Set-Content -Path $outFile -Encoding UTF8
Write-Host "Azure ids written to $outFile (no secrets)."

# ---------------------------------------------------------------------------
# GitHub side: environments, deployment branch policy, prod approval, variables
# ---------------------------------------------------------------------------
$repo = "$Org/$App"
$reviewerLogin = Invoke-Gh api user --jq .login
$reviewerId    = Invoke-Gh api "users/$reviewerLogin" --jq .id

foreach ($envName in $Environments) {
    Write-Host "==> [$envName] GitHub environment in $repo"
    $envConfig = [ordered]@{
        deployment_branch_policy = @{ protected_branches = $false; custom_branch_policies = $true }
    }
    if ($envName -eq "prod") {
        $envConfig.reviewers = @(@{ type = "User"; id = [int64]$reviewerId })
    }
    $envConfig | ConvertTo-Json -Depth 5 -Compress |
        Invoke-Gh api --method PUT "repos/$repo/environments/$envName" --input - | Out-Null

    # Allow deployments from main only (ignore "already exists").
    & gh api --method POST "repos/$repo/environments/$envName/deployment-branch-policies" -f name=main -f type=branch 2>$null | Out-Null

    $vars = [ordered]@{
        AZURE_CLIENT_ID       = $result.environments[$envName].clientId
        AZURE_TENANT_ID       = $tenantId
        AZURE_SUBSCRIPTION_ID = $subscriptionId
        AZURE_RESOURCE_GROUP  = $result.environments[$envName].resourceGroup
    }
    foreach ($name in $vars.Keys) {
        Invoke-Gh variable set $name --repo $repo --env $envName --body $vars[$name] | Out-Null
    }
}

Write-Host ""
Write-Host "Done. Push to main in $repo to deploy; prod waits for approval by $reviewerLogin." -ForegroundColor Green
