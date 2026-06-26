param location string = 'westus2'
param resourcePrefix string = 'iperf3'
param vmSize string = 'Standard_D64s_v3'
param adminUsername string = 'azureuser'

@secure()
param adminPublicKey string

param environment string = 'bench'
param tags object = {
  purpose: 'iperf3-benchmark'
  environment: environment
  createdDate: utcNow('u')
}

// Network configuration
var vnetName = '${resourcePrefix}-vnet'
var vnetPrefix = '10.0.0.0/16'
var subnetName = '${resourcePrefix}-subnet'
var subnetPrefix = '10.0.1.0/24'
var nsgName = '${resourcePrefix}-nsg'

// VM configuration
var vmNames = [
  '${resourcePrefix}-receiver'  // vmss000000
  '${resourcePrefix}-sender'    // vmss000001
]
var nicNames = [for i in range(0, 2): '${resourcePrefix}-nic-${i}']
var pipNames = [for i in range(0, 2): '${resourcePrefix}-pip-${i}']
var osDiskType = 'Premium_LRS'
var publisher = 'Canonical'
var offer = 'ubuntu-24_04-lts'
var sku = 'server'
var version = 'latest'

// Create virtual network
resource vnet 'Microsoft.Network/virtualNetworks@2023-09-01' = {
  name: vnetName
  location: location
  tags: tags
  properties: {
    addressSpace: {
      addressPrefixes: [
        vnetPrefix
      ]
    }
    subnets: [
      {
        name: subnetName
        properties: {
          addressPrefix: subnetPrefix
          networkSecurityGroup: {
            id: nsg.id
          }
        }
      }
    ]
  }
}

// Create network security group
resource nsg 'Microsoft.Network/networkSecurityGroups@2023-09-01' = {
  name: nsgName
  location: location
  tags: tags
  properties: {
    securityRules: [
      {
        name: 'AllowSSH'
        properties: {
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: '22'
          sourceAddressPrefix: '*'
          destinationAddressPrefix: '*'
          access: 'Allow'
          priority: 100
          direction: 'Inbound'
        }
      }
      {
        name: 'AllowIperf3'
        properties: {
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: '5201'
          sourceAddressPrefix: '*'
          destinationAddressPrefix: '*'
          access: 'Allow'
          priority: 110
          direction: 'Inbound'
        }
      }
      {
        name: 'AllowIperf3UDP'
        properties: {
          protocol: 'Udp'
          sourcePortRange: '*'
          destinationPortRange: '5201'
          sourceAddressPrefix: '*'
          destinationAddressPrefix: '*'
          access: 'Allow'
          priority: 120
          direction: 'Inbound'
        }
      }
      {
        name: 'AllowNetperf'
        properties: {
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: '12865'
          sourceAddressPrefix: '*'
          destinationAddressPrefix: '*'
          access: 'Allow'
          priority: 130
          direction: 'Inbound'
        }
      }
    ]
  }
}

// Create public IPs
resource pips 'Microsoft.Network/publicIPAddresses@2023-09-01' = [for (name, i) in pipNames: {
  name: name
  location: location
  tags: union(tags, { role: (i == 0 ? 'receiver' : 'sender') })
  sku: {
    name: 'Standard'
    tier: 'Regional'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
    publicIPAddressVersion: 'IPv4'
  }
}]

// Create network interfaces with accelerated networking
resource nics 'Microsoft.Network/networkInterfaces@2023-09-01' = [for (name, i) in nicNames: {
  name: name
  location: location
  tags: union(tags, { role: (i == 0 ? 'receiver' : 'sender') })
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          subnet: {
            id: '${vnet.id}/subnets/${subnetName}'
          }
          privateIPAllocationMethod: 'Dynamic'
          publicIPAddress: {
            id: pips[i].id
          }
        }
      }
    ]
    networkSecurityGroup: {
      id: nsg.id
    }
    enableAcceleratedNetworking: true
    enableIPForwarding: false
  }
}]

// Create VMs
resource vms 'Microsoft.Compute/virtualMachines@2023-09-01' = [for (vmName, i) in vmNames: {
  name: vmName
  location: location
  tags: union(tags, { role: (i == 0 ? 'receiver' : 'sender') })
  properties: {
    hardwareProfile: {
      vmSize: vmSize
    }
    osProfile: {
      computerName: vmName
      adminUsername: adminUsername
      linuxConfiguration: {
        disablePasswordAuthentication: true
        ssh: {
          publicKeys: [
            {
              path: '/home/${adminUsername}/.ssh/authorized_keys'
              keyData: adminPublicKey
            }
          ]
        }
      }
      customData: base64(loadTextContent('./cloud-init.sh'))
    }
    storageProfile: {
      imageReference: {
        publisher: publisher
        offer: offer
        sku: sku
        version: version
      }
      osDisk: {
        createOption: 'FromImage'
        managedDisk: {
          storageAccountType: osDiskType
        }
        deleteOption: 'Delete'
      }
    }
    networkProfile: {
      networkInterfaces: [
        {
          id: nics[i].id
          properties: {
            primary: true
          }
        }
      ]
    }
  }
}]

// Outputs
output vnetId string = vnet.id
output receiverVMName string = vmNames[0]
output senderVMName string = vmNames[1]
output receiverPublicIP string = pips[0].properties.ipAddress
output senderPublicIP string = pips[1].properties.ipAddress
output receiverPrivateIP string = nics[0].properties.ipConfigurations[0].properties.privateIPAddress
output senderPrivateIP string = nics[1].properties.ipConfigurations[0].properties.privateIPAddress
