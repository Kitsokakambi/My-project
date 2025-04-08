// Customized version of teammate's Bicep script

@description('Prefix for naming Azure resources')
param prefix string = 'tshop'

@description('The name of the Managed Cluster resource.')
param clusterName string = '${prefix}-aks-cluster'

@description('The location of the Managed Cluster resource.')
param location string = resourceGroup().location

@description('Optional DNS prefix to use with hosted Kubernetes API server FQDN.')
param dnsPrefix string

@description('Disk size (in GB) for agent pool nodes (0 uses default).')
@minValue(0)
@maxValue(1023)
param osDiskSizeGB int = 0

@description('Node count for AKS.')
@minValue(1)
@maxValue(50)
param agentCount int = 3

@description('Virtual Machine size for agents.')
param agentVMSize string = 'standard_b2s'

@description('Linux admin username.')
param linuxAdminUsername string

@description('SSH RSA public key.')
param sshRSAPublicKey string

@description('VNet name.')
param vnetName string = '${prefix}-vnet'

@description('Public subnet name.')
param publicSubnetName string = '${prefix}-subnet-public'

@description('Private subnet name.')
param privateSubnetName string = '${prefix}-subnet-private'

@description('Container Registry name.')
param acrName string = '${prefix}acr${uniqueString(resourceGroup().id)}'

@description('Application Gateway name.')
param appGatewayName string = '${prefix}-appgw'

@description('App Service Plan name.')
param appServicePlanName string = '${prefix}-appservice-plan'

@description('Web App name.')
param webAppName string = '${prefix}-webapp${uniqueString(resourceGroup().id)}'

@description('Container image to deploy.')
param containerImage string = 'tshop-service:latest'

@description('Client ID for AKS service principal.')
@secure()
param aksServicePrincipalClientId string

@description('DB connection string.')
param dbConnection string

@description('DB host.')
param dbHost string

@description('DB port.')
param dbPort string = '3306'

@description('DB name.')
param dbName string = 'tshopdb'

@description('DB user.')
param dbUser string

@description('DB password.')
@secure()
param dbPassword string

var privateSubnetId = '${vnetName}/subnets/${privateSubnetName}'
var publicSubnetId = '${vnetName}/subnets/${publicSubnetName}'

// Create VNet
resource vnet 'Microsoft.Network/virtualNetworks@2021-05-01' = {
  name: vnetName
  location: location
  tags: {
    environment: 'dev'
    owner: 'yourname'
  }
  properties: {
    addressSpace: {
      addressPrefixes: ['10.0.0.0/16']
    }
    subnets: [
      {
        name: publicSubnetName
        properties: {
          addressPrefix: '10.0.1.0/24'
        }
      }
      {
        name: privateSubnetName
        properties: {
          addressPrefix: '10.0.2.0/24'
        }
      }
    ]
  }
}

// Container Registry
resource acr 'Microsoft.ContainerRegistry/registries@2021-06-01-preview' = {
  name: acrName
  location: location
  sku: {
    name: 'Basic'
  }
  properties: {
    adminUserEnabled: true
    networkRuleSet: {
      defaultAction: 'Allow'
    }
  }
  tags: {
    owner: 'yourname'
  }
}

// Public IP for App Gateway
resource appGatewayPublicIp 'Microsoft.Network/publicIPAddresses@2021-05-01' = {
  name: '${appGatewayName}-ip'
  location: location
  sku: {
    name: 'Basic'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
  }
}

// App Gateway
resource appGateway 'Microsoft.Network/applicationGateways@2021-05-01' = {
  name: appGatewayName
  location: location
  properties: {
    sku: {
      name: 'Standard_v2'
      tier: 'Standard_v2'
      capacity: 1
    }
    gatewayIPConfigurations: [
      {
        name: 'appGatewayIpConfig'
        properties: {
          subnet: {
            id: '${vnet.id}/subnets/${publicSubnetName}'
          }
        }
      }
    ]
    frontendIPConfigurations: [
      {
        name: 'frontendConfig'
        properties: {
          publicIPAddress: {
            id: appGatewayPublicIp.id
          }
        }
      }
    ]
    frontendPorts: [
      {
        name: 'httpPort'
        properties: {
          port: 80
        }
      }
    ]
    backendAddressPools: [
      {
        name: 'defaultPool'
        properties: {}
      }
    ]
    backendHttpSettingsCollection: [
      {
        name: 'defaultSettings'
        properties: {
          port: 80
          protocol: 'Http'
          requestTimeout: 30
        }
      }
    ]
    httpListeners: [
      {
        name: 'listener'
        properties: {
          frontendIPConfiguration: {
            id: resourceId('Microsoft.Network/applicationGateways/frontendIPConfigurations', appGatewayName, 'frontendConfig')
          }
          frontendPort: {
            id: resourceId('Microsoft.Network/applicationGateways/frontendPorts', appGatewayName, 'httpPort')
          }
          protocol: 'Http'
        }
      }
    ]
    requestRoutingRules: [
      {
        name: 'defaultRule'
        properties: {
          ruleType: 'Basic'
          httpListener: {
            id: resourceId('Microsoft.Network/applicationGateways/httpListeners', appGatewayName, 'listener')
          }
          backendAddressPool: {
            id: resourceId('Microsoft.Network/applicationGateways/backendAddressPools', appGatewayName, 'defaultPool')
          }
          backendHttpSettings: {
            id: resourceId('Microsoft.Network/applicationGateways/backendHttpSettingsCollection', appGatewayName, 'defaultSettings')
          }
        }
      }
    ]
  }
}

// AKS Cluster
resource aks 'Microsoft.ContainerService/managedClusters@2024-02-01' = {
  name: clusterName
  location: location
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    dnsPrefix: dnsPrefix
    addonProfiles: {
      ingressApplicationGateway: {
        enabled: true
        config: {
          applicationGatewayId: appGateway.id
        }
      }
    }
    agentPoolProfiles: [
      {
        name: 'systempool'
        osDiskSizeGB: osDiskSizeGB
        count: agentCount
        vmSize: agentVMSize
        osType: 'Linux'
        mode: 'System'
        type: 'VirtualMachineScaleSets'
        vnetSubnetID: '${vnet.id}/subnets/${privateSubnetName}'
      }
    ]
    servicePrincipalProfile: {
      clientId: aksServicePrincipalClientId
    }
    linuxProfile: {
      adminUsername: linuxAdminUsername
      ssh: {
        publicKeys: [
          {
            keyData: sshRSAPublicKey
          }
        ]
      }
    }
    networkProfile: {
      networkPlugin: 'azure'
      serviceCidr: '10.2.0.0/16'
      dnsServiceIP: '10.2.0.10'
      loadBalancerSku: 'basic'
    }
  }
}

// App Service Plan
resource appServicePlan 'Microsoft.Web/serverfarms@2022-09-01' = {
  name: appServicePlanName
  location: location
  sku: {
    name: 'F1'
    tier: 'Free'
  }
  kind: 'linux'
  properties: {
    reserved: true
  }
}

// Web App
resource webApp 'Microsoft.Web/sites@2022-09-01' = {
  name: webAppName
  location: location
  kind: 'app,linux,container'
  properties: {
    serverFarmId: appServicePlan.id
    siteConfig: {
      linuxFxVersion: 'DOCKER|${acr.properties.loginServer}/${containerImage}'
      appSettings: [
        {
          name: 'DOCKER_REGISTRY_SERVER_URL'
          value: 'https://${acr.properties.loginServer}/${containerImage}'
        }
        {
          name: 'WEBSITES_ENABLE_APP_SERVICE_STORAGE'
          value: 'false'
        }
        {
          name: 'DOCKER_ENABLE_CI'
          value: 'true'
        }
        {
          name: 'DB_CONNECTION'
          value: dbConnection
        }
        {
          name: 'DB_HOST'
          value: dbHost
        }
        {
          name: 'DB_PORT'
          value: dbPort
        }
        {
          name: 'DB_NAME'
          value: dbName
        }
        {
          name: 'DB_USER'
          value: dbUser
        }
        {
          name: 'DB_PASSWORD'
          value: dbPassword
        }
      ]
    }
  }
}

output aksFQDN string = aks.properties.fqdn
output appGatewayIP string = appGatewayPublicIp.properties.ipAddress
output webAppUrl string = 'https://${webApp.properties.defaultHostName}'
