// =====================================================================
// Plataforma de datos cripto - Infraestructura como código
// Despliega: ADLS Gen2, Key Vault, Azure SQL, Data Factory, Databricks
// y los permisos RBAC con identidad administrada.
// =====================================================================

@description('Ambiente a desplegar')
@allowed([
  'dev'
  'prod'
])
param env string

@description('Sufijo corto para que los nombres sean únicos (ej. tus iniciales)')
@minLength(2)
@maxLength(6)
param suffix string

@description('Región principal de los recursos')
param location string = resourceGroup().location

@description('Región del servidor SQL (puede diferir por restricciones de capacidad)')
param sqlLocation string = location

@description('Usuario administrador SQL')
param sqlAdminLogin string = 'sqladmin'

@description('Contraseña del administrador SQL')
@secure()
param sqlAdminPassword string

@description('Correo (UPN) del administrador de Microsoft Entra del servidor SQL')
param entraAdminLogin string

@description('Object ID del administrador de Entra (az ad signed-in-user show --query id -o tsv)')
param entraAdminObjectId string

@description('IP pública de tu PC para el firewall de SQL. Vacío = no crear la regla')
param clientIp string = ''

@description('Usar la oferta gratuita de Azure SQL Database')
param useSqlFreeOffer bool = true

// ---------------------------------------------------------------------
// Nombres y etiquetas
// ---------------------------------------------------------------------
var tags = {
  proyecto: 'cripto'
  ambiente: env
}

var storageName = toLower('stcripto${env}${suffix}')
var keyVaultName = 'kv-cripto-${env}-${suffix}'
var sqlServerName = 'sql-cripto-${env}-${suffix}'
var sqlDbName = 'sqldb-cripto'
var adfName = 'adf-cripto-${env}-${suffix}'
var databricksName = 'dbw-cripto-${env}-${suffix}'
var lakeContainers = [
  'bronze'
  'silver'
  'gold'
]

// IDs de roles integrados de Azure
var roles = {
  storageBlobDataContributor: 'ba92f5b4-2d11-453d-a403-e96b0029c9fe'
  keyVaultSecretsUser: '4633458b-17de-408a-b874-0445c86b69e6'
  keyVaultSecretsOfficer: 'b86a8fe4-44ce-4948-aee5-eccb2c155cd7'
  contributor: 'b24988ac-6180-42a0-ab88-20f7382dd24c'
}

// ---------------------------------------------------------------------
// 1. Data lake: ADLS Gen2
// ---------------------------------------------------------------------
resource storage 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: storageName
  location: location
  tags: tags
  kind: 'StorageV2'
  sku: {
    name: 'Standard_LRS'
  }
  properties: {
    isHnsEnabled: true // Esto lo convierte en ADLS Gen2
    accessTier: 'Hot'
    allowBlobPublicAccess: false
    minimumTlsVersion: 'TLS1_2'
    supportsHttpsTrafficOnly: true
  }
}

resource blobService 'Microsoft.Storage/storageAccounts/blobServices@2023-05-01' = {
  parent: storage
  name: 'default'
  properties: {
    // Eliminación temporal: permite recuperar archivos o contenedores borrados por error
    deleteRetentionPolicy: {
      enabled: true
      days: 7
      allowPermanentDelete: false
    }
    containerDeleteRetentionPolicy: {
      enabled: true
      days: 7
    }
  }
}

resource containers 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' = [for c in lakeContainers: {
  parent: blobService
  name: c
  properties: {
    publicAccess: 'None'
  }
}]

// ---------------------------------------------------------------------
// 2. Key Vault (modelo RBAC)
// ---------------------------------------------------------------------
resource keyVault 'Microsoft.KeyVault/vaults@2023-07-01' = {
  name: keyVaultName
  location: location
  tags: tags
  properties: {
    tenantId: subscription().tenantId
    sku: {
      family: 'A'
      name: 'standard'
    }
    enableRbacAuthorization: true
    enableSoftDelete: true
    softDeleteRetentionInDays: 7
  }
}

resource sqlPasswordSecret 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = {
  parent: keyVault
  name: 'sql-admin-password'
  properties: {
    value: sqlAdminPassword
  }
}

// ---------------------------------------------------------------------
// 3. Azure SQL (servidor + base serverless)
// ---------------------------------------------------------------------
resource sqlServer 'Microsoft.Sql/servers@2023-08-01-preview' = {
  name: sqlServerName
  location: sqlLocation
  tags: tags
  properties: {
    administratorLogin: sqlAdminLogin
    administratorLoginPassword: sqlAdminPassword
    minimalTlsVersion: '1.2'
    publicNetworkAccess: 'Enabled'
    administrators: {
      administratorType: 'ActiveDirectory'
      principalType: 'User'
      login: entraAdminLogin
      sid: entraAdminObjectId
      tenantId: subscription().tenantId
      azureADOnlyAuthentication: false // Autenticación mixta: Entra + SQL
    }
  }
}

// Equivale a "Permitir que los servicios de Azure accedan a este servidor"
resource sqlFirewallAzure 'Microsoft.Sql/servers/firewallRules@2023-08-01-preview' = {
  parent: sqlServer
  name: 'AllowAllWindowsAzureIps'
  properties: {
    startIpAddress: '0.0.0.0'
    endIpAddress: '0.0.0.0'
  }
}

resource sqlFirewallClient 'Microsoft.Sql/servers/firewallRules@2023-08-01-preview' = if (!empty(clientIp)) {
  parent: sqlServer
  name: 'ClientIp'
  properties: {
    startIpAddress: clientIp
    endIpAddress: clientIp
  }
}

resource sqlDb 'Microsoft.Sql/servers/databases@2023-08-01-preview' = {
  parent: sqlServer
  name: sqlDbName
  location: sqlLocation
  tags: tags
  sku: {
    name: 'GP_S_Gen5'
    tier: 'GeneralPurpose'
    family: 'Gen5'
    capacity: 2
  }
  properties: {
    autoPauseDelay: 60
    minCapacity: json('0.5')
    requestedBackupStorageRedundancy: 'Local'
    useFreeLimit: useSqlFreeOffer
    freeLimitExhaustionBehavior: useSqlFreeOffer ? 'AutoPause' : null
  }
}

// ---------------------------------------------------------------------
// 4. Data Factory con identidad administrada
// ---------------------------------------------------------------------
resource adf 'Microsoft.DataFactory/factories@2018-06-01' = {
  name: adfName
  location: location
  tags: tags
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    publicNetworkAccess: 'Enabled'
    // Git se conecta solo en dev; prod recibe cambios por CI/CD
  }
}

// ---------------------------------------------------------------------
// 5. Databricks Premium en modo serverless
// Sin grupo de recursos administrado ni clústeres propios:
// Databricks gestiona el cómputo y ADF lo usa mediante Databricks Jobs.
// ---------------------------------------------------------------------
resource databricks 'Microsoft.Databricks/workspaces@2026-01-01' = {
  name: databricksName
  location: location
  tags: tags
  sku: {
    name: 'premium'
  }
  properties: {
    computeMode: 'Serverless'
  }
}

// ---------------------------------------------------------------------
// 6. Permisos RBAC (mínimo privilegio)
// ---------------------------------------------------------------------

// ADF -> lake: leer y escribir datos
resource raAdfStorage 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storage.id, adf.id, roles.storageBlobDataContributor)
  scope: storage
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roles.storageBlobDataContributor)
    principalId: adf.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

// ADF -> Key Vault: solo leer secretos
resource raAdfKeyVault 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(keyVault.id, adf.id, roles.keyVaultSecretsUser)
  scope: keyVault
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roles.keyVaultSecretsUser)
    principalId: adf.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

// ADF -> Databricks: lanzar Jobs serverless
resource raAdfDatabricks 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(databricks.id, adf.id, roles.contributor)
  scope: databricks
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roles.contributor)
    principalId: adf.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

// Tú -> lake: navegar archivos desde el portal
resource raUserStorage 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storage.id, entraAdminObjectId, roles.storageBlobDataContributor)
  scope: storage
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roles.storageBlobDataContributor)
    principalId: entraAdminObjectId
    principalType: 'User'
  }
}

// Tú -> Key Vault: administrar secretos
resource raUserKeyVault 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(keyVault.id, entraAdminObjectId, roles.keyVaultSecretsOfficer)
  scope: keyVault
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roles.keyVaultSecretsOfficer)
    principalId: entraAdminObjectId
    principalType: 'User'
  }
}

// ---------------------------------------------------------------------
// Salidas útiles para los siguientes pasos
// ---------------------------------------------------------------------
output storageAccountName string = storage.name
output dfsEndpoint string = storage.properties.primaryEndpoints.dfs
output keyVaultUri string = keyVault.properties.vaultUri
output sqlServerFqdn string = sqlServer.properties.fullyQualifiedDomainName
output dataFactoryName string = adf.name
output dataFactoryPrincipalId string = adf.identity.principalId
output databricksUrl string = 'https://${databricks.properties.workspaceUrl}'
