# platform

Shared CI/CD building blocks for JMa9-Dev applications: GitHub Actions reusable
workflows and Bicep templates for deploying .NET apps to Azure App Service.

## Principles

- Code in GitHub, deployments with GitHub Actions.
- Azure login with OIDC (workload identity federation) – no passwords or client secrets.
- Infrastructure as code (Bicep).
- Environments: `dev` (automatic deploy from `main`). `prod` (GitHub Environment with approval)
  is added only when an app is ready for real use – see *Adding prod* below.
- Build, lint and tests run on every pull request before merge.

## Contents

| Path | Purpose |
|------|---------|
| `.github/workflows/dotnet-ci.yml` | Restore, `dotnet format` lint, build, test |
| `.github/workflows/dotnet-publish.yml` | Publish once, upload zip artifact |
| `.github/workflows/deploy-appservice.yml` | OIDC login, Bicep deploy, zip deploy, smoke test |
| `infra/appservice/main.bicep` | Linux App Service plan + Web App |
| `scripts/bootstrap-app.sh` | One-time Azure + GitHub setup for a new app |

## Adding a new application

1. Create the repository (e.g. from the `hello-app` template) in `JMa9-Dev`.
2. Add `infra/dev.bicepparam` and `infra/prod.bicepparam` that reference
   `../.platform/infra/appservice/main.bicep`.
3. Add `.github/workflows/pr.yml` and `.github/workflows/deploy.yml` calling the
   reusable workflows here (copy from `hello-app`).
4. Run the bootstrap once (creates the `dev` environment):

   ```powershell
   # Windows
   powershell -ExecutionPolicy Bypass -File .\scripts\bootstrap-app.ps1 -App <app-name>
   ```

   ```bash
   # macOS / Linux
   ./scripts/bootstrap-app.sh <app-name> swedencentral JMa9-Dev
   ```

5. In the app repository, protect `main`: require a pull request and the `ci / Build, lint & test` status check.

## How the flow works

```
PR ─► dotnet-ci (format, build, test)          ── must pass before merge
main ─► dotnet-ci ─► dotnet-publish ─► deploy dev   [─► (approval) ─► deploy prod, once added]
```

Each environment has its own managed identity with Contributor rights on its own
resource group only. The federated credential trusts only
`repo:JMa9-Dev/<app>:environment:<env>`, so a workflow can reach prod only through
the approved `prod` environment.

## Adding prod

When an app is ready for real use:

1. Re-run the bootstrap with prod: `-Environments dev,prod` (PowerShell) or
   `ENVIRONMENTS="dev prod" ./scripts/bootstrap-app.sh <app>` (bash).
   The prod environment requires approval by the signed-in GitHub user.
2. Add `infra/prod.bicepparam` (e.g. `skuName = 'B1'`).
3. Add a `deploy-prod` job to the app's `deploy.yml` with `needs: deploy-dev` and
   `environment: prod` (same shape as `deploy-dev`).

## Versioning

Apps currently call `@main`. Once the workflows stabilise, tag releases (`v1`) and
reference `@v1` so changes here don't break apps unexpectedly.

## Local Bicep validation

The `.bicepparam` files in app repositories expect this repository checked out at
`.platform/` in the app repository root:

```bash
git clone https://github.com/JMa9-Dev/platform .platform
az bicep build-params --file infra/dev.bicepparam --stdout > /dev/null
```
