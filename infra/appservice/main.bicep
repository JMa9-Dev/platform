// Shared template: Linux App Service plan + Web App for a .NET application.
// Deployed at resource group scope. App repositories reference this file from
// their .bicepparam files:  using '../.platform/infra/appservice/main.bicep'
targetScope = 'resourceGroup'

@description('Short application name, e.g. hello-app.')
@maxLength(20)
param appName string

@description('Environment name.')
@allowed([
  'dev'
  'prod'
])
param environmentName string

@description('Azure region. Defaults to the resource group location.')
param location string = resourceGroup().location

@description('App Service plan SKU, e.g. F1, B1, P0v3.')
param skuName string = 'B1'

@description('.NET runtime version on App Service.')
param dotnetVersion string = '10.0'

@description('Health check path exposed by the application.')
param healthCheckPath string = '/healthz'

@description('Additional app settings as a key/value object.')
param appSettings object = {}

var suffix = uniqueString(resourceGroup().id)
var isFreeTier = skuName == 'F1'
var tags = {
  app: appName
  environment: environmentName
  managedBy: 'bicep'
}
var allAppSettings = union({ APP_ENVIRONMENT: environmentName }, appSettings)

resource plan 'Microsoft.Web/serverfarms@2024-04-01' = {
  name: 'asp-${appName}-${environmentName}'
  location: location
  tags: tags
  kind: 'linux'
  sku: {
    name: skuName
  }
  properties: {
    reserved: true // required for Linux
  }
}

resource site 'Microsoft.Web/sites@2024-04-01' = {
  name: 'app-${appName}-${environmentName}-${suffix}'
  location: location
  tags: tags
  kind: 'app,linux'
  properties: {
    serverFarmId: plan.id
    httpsOnly: true
    siteConfig: {
      linuxFxVersion: 'DOTNETCORE|${dotnetVersion}'
      alwaysOn: !isFreeTier // not supported on the Free tier
      healthCheckPath: isFreeTier ? null : healthCheckPath
      ftpsState: 'Disabled'
      minTlsVersion: '1.2'
      http20Enabled: true
      appSettings: [
        for setting in items(allAppSettings): {
          name: setting.key
          value: setting.value
        }
      ]
    }
  }
}

// Disable basic (username/password) publishing credentials; deployments use Entra ID tokens.
resource ftpCredentials 'Microsoft.Web/sites/basicPublishingCredentialsPolicies@2024-04-01' = {
  parent: site
  name: 'ftp'
  properties: {
    allow: false
  }
}

resource scmCredentials 'Microsoft.Web/sites/basicPublishingCredentialsPolicies@2024-04-01' = {
  parent: site
  name: 'scm'
  properties: {
    allow: false
  }
}

output webAppName string = site.name
output defaultHostName string = site.properties.defaultHostName
