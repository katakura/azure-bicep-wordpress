//
// VERY SECURE AND CHEAP (BAD SLOW) WORDPRESS SITE ON AZURE
//

@description('Azure resource SKU/Plan (0:Not Cheap, 1:Normal, 2:Cheap)')
@maxValue(2)
@minValue(0)
param cheapLevel int = 2

@description('MySQL admin user name')
param adminName string = 'dbadmin'

@description('MySQL admin password')
@secure()
param adminPass string

@description('wordpress endpoint prefix name ([foo].azurewebsites.net)')
param appName string = 'wordpress-${uniqueString(resourceGroup().id)}'

@description('deploy azure region')
param location string = resourceGroup().location

// variables
var vnetName = 'vnet-wordpress'

var logAnalyticsName = 'log-wordpress'
var appInsightsName = 'appins-wordpress'

var appServicePlanName = 'plan-wordpress'

var storageName = take('stwp${uniqueString(resourceGroup().id)}', 24)
var storagePeName = 'pe-storage'
var shareName = 'wpdata'

var dbName = 'mysql-wordpress-${uniqueString(resourceGroup().id)}'
var databaseName = 'wp01'

var kvName = take('kv-${uniqueString(resourceGroup().id)}', 24)
var dbPassKvKeyName = 'dbpassword'
var kvPeName = 'pe-keyvault'

var cheapLevels = [
  // Level 0
  {
    plan: {
      tier: 'PremiumV3'
      name: 'P2V3'
      family: 'P'
      capacity: 1
    }
    storage: {
      sku: 'Premium_LRS'
      kind: 'FileStorage'
    }
    mysql: {
      name: 'Standard_D2ds_v4'
      tier: 'GeneralPurpose'
    }
  }
  // Level 1
  {
    plan: {
      tier: 'Standard'
      name: 'S1'
      family: 'S'
      capacity: 1
    }
    storage: {
      sku: 'Premium_LRS'
      kind: 'FileStorage'
    }
    mysql: {
      name: 'Standard_B2s'
      tier: 'Burstable'
    }
  }
  // Level 2
  {
    plan: {
      tier: 'Basic'
      name: 'B1'
      capacity: 1
    }
    storage: {
      sku: 'Standard_LRS'
      kind: 'StorageV2'
    }
    mysql: {
      name: 'Standard_B1s'
      tier: 'Burstable'
    }
  }
]

// Key Vault
// Used (only) to hold the MySQL administrator password
resource keyVault 'Microsoft.KeyVault/vaults@2021-11-01-preview' = {
  name: kvName
  location: location
  properties: {
    sku: {
      family: 'A'
      name: 'standard'
    }
    createMode: 'default'
    enabledForDeployment: false
    enabledForDiskEncryption: false
    enabledForTemplateDeployment: false
    enableRbacAuthorization: false
    enableSoftDelete: false
    tenantId: tenant().tenantId
    networkAcls: {
      defaultAction: 'Deny'
      bypass: 'AzureServices'
      ipRules: []
    }
    accessPolicies: [
      {
        objectId: webApps.identity.principalId
        tenantId: webApps.identity.tenantId
        permissions: {
          keys: []
          secrets: [
            'get'
          ]
          certificates: []
        }
      }
    ]
  }
}

// Key Vault secret
// MySQL administrator password
resource keyVaultSecrets 'Microsoft.KeyVault/vaults/secrets@2021-11-01-preview' = {
  parent: keyVault
  name: dbPassKvKeyName
  properties: {
    value: adminPass
  }
}

// Private Endpoint for Key Vault
// Endpoint for closed access to Key Vault resources from within a VNET
resource kvPrivateEndpoint 'Microsoft.Network/privateEndpoints@2021-05-01' = {
  name: kvPeName
  location: location
  properties: {
    privateLinkServiceConnections: [
      {
        name: 'connection-${vnetName}'
        properties: {
          privateLinkServiceId: keyVault.id
          groupIds: [
            'vault'
          ]
        }
      }
    ]
    subnet: {
      id: virtualNetwork.properties.subnets[1].id
    }
  }
}

// DNS Zones (Key Vault)
// Spell to resolve Key Vault to name from inside VNET
resource kvDnsZones 'Microsoft.Network/privateDnsZones@2020-06-01' = {
  name: 'privatelink.vaultcore.azure.net'
  location: 'global'
}

// DNS Zones VNET link (Key Vault)
// Spell to resolve Key Vault to name from inside VNET
resource kvDnsZonesVnetLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2020-06-01' = {
  parent: kvDnsZones
  name: 'link-${vnetName}'
  location: 'global'
  properties: {
    registrationEnabled: false
    virtualNetwork: {
      id: virtualNetwork.id
    }
  }
}

// DNS Zone Group (Key Vault)
// Spell to resolve Key Vault to name from inside VNET
resource kvPeDnsZoneGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2021-05-01' = {
  parent: kvPrivateEndpoint
  name: 'group-kv'
  properties: {
    privateDnsZoneConfigs: [
      {
        name: 'pl_kv'
        properties: {
          privateDnsZoneId: kvDnsZones.id
        }
      }
    ]
  }
}

// Virtual Network
// All PaaS communicate via this VNET
resource virtualNetwork 'Microsoft.Network/virtualNetworks@2021-05-01' = {
  name: vnetName
  location: location
  properties: {
    addressSpace: {
      addressPrefixes: [
        '192.168.192.0/24'
      ]
    }
    subnets: [
      {
        name: 'snet-apps'
        properties: {
          addressPrefix: '192.168.192.0/26'
          delegations: [
            {
              name: 'delegation'
              properties: {
                serviceName: 'Microsoft.Web/serverfarms'
              }
            }
          ]
        }
      }
      {
        name: 'snet-pe'
        properties: {
          addressPrefix: '192.168.192.64/26'
          privateEndpointNetworkPolicies: 'Disabled'
        }
      }
      {
        name: 'snet-db'
        properties: {
          addressPrefix: '192.168.192.128/26'
          delegations: [
            {
              name: 'delegation'
              properties: {
                serviceName: 'Microsoft.DBforMySQL/flexibleServers'
              }
            }
          ]
        }
      }
    ]
  }
}

// Log Analytics workspace
// 
resource logAnalyticsWorkspace 'Microsoft.OperationalInsights/workspaces@2021-12-01-preview' = {
  name: logAnalyticsName
  location: location
  properties: {
    retentionInDays: 30
    sku: {
      name: 'PerGB2018'
    }
  }
}

// Application Insights
//
resource appInsights 'Microsoft.Insights/components@2020-02-02' = {
  name: appInsightsName
  location: location
  kind: 'web'
  properties: {
    Application_Type: 'web'
    WorkspaceResourceId: logAnalyticsWorkspace.id
  }
}

// App Service Plan
// VNET Integration available for Basic Tier in April 2022.
resource appServicePlan 'Microsoft.Web/serverfarms@2021-03-01' = {
  name: appServicePlanName
  location: location
  kind: 'linux'
  properties: {
    elasticScaleEnabled: false
    reserved: true
    zoneRedundant: false
  }
  sku: cheapLevels[cheapLevel].plan
}

// Web apps
// Launch WordPress, the official Dockerhub image
resource webApps 'Microsoft.Web/sites@2021-03-01' = {
  name: appName
  kind: 'app,linux'
  location: location
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    siteConfig: {
      appSettings: [
        {
          name: 'APPINSIGHTS_INSTRUMENTATIONKEY'
          value: appInsights.properties.InstrumentationKey
        }
        {
          name: 'APPLICATIONINSIGHTS_CONNECTION_STRING'
          value: appInsights.properties.ConnectionString
        }
        {
          name: 'ApplicationInsightsAgent_EXTENSION_VERSION'
          value: '~3'
        }
        {
          name: 'XDT_MicrosoftApplicationInsights_Mode'
          value: 'Recommended'
        }
        {
          name: 'DOCKER_REGISTRY_SERVER_URL'
          value: 'https://index.docker.io'
        }
        {
          name: 'WORDPRESS_DB_PASSWORD'
          value: '@Microsoft.KeyVault(VaultName=${kvName};SecretName=${dbPassKvKeyName})'
        }
        {
          name: 'WORDPRESS_DB_HOST'
          value: '${dbName}.mysql.database.azure.com'
        }
        {
          name: 'WORDPRESS_DB_USER'
          value: adminName
        }
        {
          name: 'WORDPRESS_DB_NAME'
          value: databaseName
        }
        {
          name: 'WORDPRESS_TABLE_PREFIX'
          value: 'wp_'
        }
        {
          name: 'WORDPRESS_CONFIG_EXTRA'
          value: 'define(\'MYSQL_CLIENT_FLAGS\', MYSQLI_CLIENT_SSL);'
        }
      ]
      azureStorageAccounts: {
        'wpmapping': {
          type: 'AzureFiles'
          accountName: storageAccount.name
          shareName: shareName
          accessKey: storageAccount.listKeys().keys[0].value
          mountPath: '/var/www/html'
        }
      }
      // linuxFxVersion: 'DOCKER|wordpress:latest'
      linuxFxVersion: 'DOCKER|katakura/wordpress:latest'

      alwaysOn: true
      logsDirectorySizeLimit: 100
      httpLoggingEnabled: true
      vnetRouteAllEnabled: true
      vnetName: vnetName
    }
    serverFarmId: appServicePlan.id
    clientAffinityEnabled: false
    virtualNetworkSubnetId: virtualNetwork.properties.subnets[0].id
  }
  dependsOn: [
    fileShare
    mySqlServerDatabase
  ]
}

// Storage
// For WordPress persistent area
resource storageAccount 'Microsoft.Storage/storageAccounts@2021-08-01' = {
  name: storageName
  location: location
  sku: {
    name: cheapLevels[cheapLevel].storage.sku
  }
  kind: cheapLevels[cheapLevel].storage.kind
  properties: {
    isNfsV3Enabled: false
    isHnsEnabled: false
    isSftpEnabled: false
    minimumTlsVersion: 'TLS1_2'
    allowBlobPublicAccess: false
    networkAcls: {
      bypass: 'AzureServices'
      defaultAction: 'Deny'
    }
    supportsHttpsTrafficOnly: true
  }
}

// Storage share folder
// For WordPress persistent area
resource fileShare 'Microsoft.Storage/storageAccounts/fileServices/shares@2021-08-01' = {
  name: '${storageAccount.name}/default/${shareName}'
  properties: {}
}

// Private Endpoint for file storage
// Endpoint for closed access to storage resources from within a VNET
resource storagePrivateEndpoint 'Microsoft.Network/privateEndpoints@2021-05-01' = {
  name: storagePeName
  location: location
  properties: {
    privateLinkServiceConnections: [
      {
        name: 'connection-${vnetName}'
        properties: {
          privateLinkServiceId: storageAccount.id
          groupIds: [
            'file'
          ]
        }
      }
    ]
    subnet: {
      id: virtualNetwork.properties.subnets[1].id
    }
  }
}

// DNS Zones (Storage)
// Spell to resolve Storage to name from inside VNET
resource storageDnsZones 'Microsoft.Network/privateDnsZones@2020-06-01' = {
  name: 'privatelink.file.core.windows.net'
  location: 'global'
}

// DNS Zones VNET link (Storage)
// Spell to resolve Storage to name from inside VNET
resource storageDnsZonesVnetLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2020-06-01' = {
  parent: storageDnsZones
  name: 'link-${vnetName}'
  location: 'global'
  properties: {
    registrationEnabled: false
    virtualNetwork: {
      id: virtualNetwork.id
    }
  }
}

// DNS Zone Group (Storage)
// Spell to resolve Storage to name from inside VNET
resource storagePeDnsZoneGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2021-05-01' = {
  parent: storagePrivateEndpoint
  name: 'group-storage'
  properties: {
    privateDnsZoneConfigs: [
      {
        name: 'pl_storage'
        properties: {
          privateDnsZoneId: storageDnsZones.id
        }
      }
    ]
  }
}

// Database for MySQL flexible server
//
resource mySqlServer 'Microsoft.DBforMySQL/flexibleServers@2021-05-01' = {
  name: dbName
  location: location
  sku: cheapLevels[cheapLevel].mysql
  properties: {
    version: '8.0.21'
    administratorLogin: adminName
    administratorLoginPassword: adminPass
    network: {
      delegatedSubnetResourceId: virtualNetwork.properties.subnets[2].id
      privateDnsZoneResourceId: dbDnsZones.id
    }
    backup: {
      backupRetentionDays: 7
      geoRedundantBackup: 'Disabled'
    }
  }
  dependsOn: [
    dbDnsZonesVnetLink
  ]
}

// Database for MySQL flexible server database
//
resource mySqlServerDatabase 'Microsoft.DBforMySQL/flexibleServers/databases@2021-05-01' = {
  parent: mySqlServer
  name: databaseName
  properties: {
    charset: 'UTF8MB4'
    collation: 'UTF8MB4_GENERAL_CI'
  }
}

// DNS Zones (DB)
// Spell to resolve Database to name from inside VNET
resource dbDnsZones 'Microsoft.Network/privateDnsZones@2020-06-01' = {
  name: 'privatelink.mysql.database.azure.com'
  location: 'global'
}

// DNS Zones VNET link (DB)
// Spell to resolve Database to name from inside VNET
resource dbDnsZonesVnetLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2020-06-01' = {
  parent: dbDnsZones
  name: 'link-${vnetName}'
  location: 'global'
  properties: {
    registrationEnabled: false
    virtualNetwork: {
      id: virtualNetwork.id
    }
  }
}
