#!/usr/bin/env bash
# One-time bootstrap for a new application repository.
#
# For each environment (default: dev; set ENVIRONMENTS="dev prod" to add prod) this script:
#   1. creates a resource group               rg-<app>-<env>
#   2. creates a user-assigned managed identity id-github-<app>-<env>
#   3. adds a federated credential trusting   repo:<org>/<app>:environment:<env>
#   4. grants the identity Contributor on that resource group only
#   5. creates the GitHub Environment and stores the Azure ids as environment variables
#   6. limits deployments to the main branch; prod also requires approval
#
# Requirements: az CLI (logged in: az login), gh CLI (logged in: gh auth login),
# and Owner or User Access Administrator rights on the subscription.
#
# Usage: ./bootstrap-app.sh <app-name> [location] [org] [prod-reviewer]
#   e.g. ./bootstrap-app.sh hello-app swedencentral JMa9-Dev jma9
set -euo pipefail

APP="${1:?usage: bootstrap-app.sh <app-name> [location] [org] [prod-reviewer]}"
LOCATION="${2:-swedencentral}"
ORG="${3:-JMa9-Dev}"
REVIEWER="${4:-$(gh api user --jq .login)}"
REPO="$ORG/$APP"

SUBSCRIPTION_ID=$(az account show --query id -o tsv)
TENANT_ID=$(az account show --query tenantId -o tsv)
REVIEWER_ID=$(gh api "users/$REVIEWER" --jq .id)

echo "Subscription: $(az account show --query name -o tsv) ($SUBSCRIPTION_ID)"
echo "Repository:   $REPO"
read -r -p "Continue? [y/N] " answer
[[ "$answer" =~ ^[Yy]$ ]] || exit 1

for ENV in ${ENVIRONMENTS:-dev}; do
  RG="rg-$APP-$ENV"
  IDENTITY="id-github-$APP-$ENV"
  echo "==> $ENV: resource group $RG"
  az group create --name "$RG" --location "$LOCATION" --tags app="$APP" environment="$ENV" --output none

  echo "==> $ENV: managed identity $IDENTITY"
  az identity create --name "$IDENTITY" --resource-group "$RG" --output none
  CLIENT_ID=$(az identity show --name "$IDENTITY" --resource-group "$RG" --query clientId -o tsv)
  PRINCIPAL_ID=$(az identity show --name "$IDENTITY" --resource-group "$RG" --query principalId -o tsv)

  echo "==> $ENV: federated credential for repo:$REPO:environment:$ENV"
  az identity federated-credential create \
    --name "github-$ENV" \
    --identity-name "$IDENTITY" \
    --resource-group "$RG" \
    --issuer "https://token.actions.githubusercontent.com" \
    --subject "repo:$REPO:environment:$ENV" \
    --audiences "api://AzureADTokenExchange" \
    --output none

  echo "==> $ENV: Contributor role on $RG"
  az role assignment create \
    --assignee-object-id "$PRINCIPAL_ID" \
    --assignee-principal-type ServicePrincipal \
    --role Contributor \
    --scope "/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RG" \
    --output none

  echo "==> $ENV: GitHub environment"
  if [[ "$ENV" == "prod" ]]; then
    gh api --method PUT "repos/$REPO/environments/$ENV" --input - <<JSON >/dev/null
{
  "reviewers": [{ "type": "User", "id": $REVIEWER_ID }],
  "deployment_branch_policy": { "protected_branches": false, "custom_branch_policies": true }
}
JSON
  else
    gh api --method PUT "repos/$REPO/environments/$ENV" --input - <<JSON >/dev/null
{
  "deployment_branch_policy": { "protected_branches": false, "custom_branch_policies": true }
}
JSON
  fi
  gh api --method POST "repos/$REPO/environments/$ENV/deployment-branch-policies" \
    -f name=main -f type=branch >/dev/null 2>&1 || true # ignore "already exists"

  gh variable set AZURE_CLIENT_ID       --repo "$REPO" --env "$ENV" --body "$CLIENT_ID"
  gh variable set AZURE_TENANT_ID       --repo "$REPO" --env "$ENV" --body "$TENANT_ID"
  gh variable set AZURE_SUBSCRIPTION_ID --repo "$REPO" --env "$ENV" --body "$SUBSCRIPTION_ID"
  gh variable set AZURE_RESOURCE_GROUP  --repo "$REPO" --env "$ENV" --body "$RG"
done

echo "Done. Push to main in $REPO to deploy (prod waits for approval by $REVIEWER)."
