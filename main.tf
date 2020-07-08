terraform {
  required_version 	= ">= 0.12.0"
}

provider "azurerm" {
  subscription_id 	= var.subscription
  version		= ">= 2.17"
  features 		{}
}

data "azurerm_client_config" "current" {}

data "azurerm_key_vault" "akv" {
  name                  = var.akv_name
  resource_group_name	= var.akv_resource_group_name
}

data "azurerm_key_vault_secret" "pull-secret" {
  name			= "pull-secret"
  key_vault_id		= data.azurerm_key_vault.akv.id
}

resource "azurerm_resource_group" "aro_vnet_resource_group" {
  name     		= var.aro_vnet_resource_group_name
  location 		= var.aro_location

  tags			= var.tags
}

resource "azurerm_virtual_network" "aro_vnet" {
  name                	= var.aro_vnet_name
  resource_group_name 	= azurerm_resource_group.aro_vnet_resource_group.name 
  location            	= azurerm_resource_group.aro_vnet_resource_group.location
  address_space       	= [var.aro_vnet_cidr]
}

resource "azurerm_subnet" "aro_master_subnet" {
  name                 	= var.aro_master_subnet_name
  virtual_network_name 	= azurerm_virtual_network.aro_vnet.name
  resource_group_name  	= azurerm_resource_group.aro_vnet_resource_group.name 
  address_prefixes 	= [var.aro_master_subnet_cidr]

  enforce_private_link_service_network_policies = true

  service_endpoints 	= var.service_endpoints
}

resource "azurerm_subnet" "aro_worker_subnet" {
  name                 	= var.aro_worker_subnet_name
  virtual_network_name 	= azurerm_virtual_network.aro_vnet.name
  resource_group_name  	= azurerm_resource_group.aro_vnet_resource_group.name 
  address_prefixes 	= [var.aro_worker_subnet_cidr]

  service_endpoints 	= var.service_endpoints
}

resource "azurerm_role_assignment" "vnet_assignment" {
  count			= length(var.roles)
  scope			= azurerm_virtual_network.aro_vnet.id
  role_definition_name	= var.roles[count.index].role
  principal_id		= var.aro_client_object_id
}

resource "azurerm_role_assignment" "rp_assignment" {
  count			= length(var.roles)
  scope			= azurerm_virtual_network.aro_vnet.id
  role_definition_name	= var.roles[count.index].role
  principal_id		= var.aro_rp_object_id
}

resource "azurerm_template_deployment" "azure-arocluster" {
  name			= var.aro_name
  resource_group_name	= var.aro_vnet_resource_group_name

  template_body = file("${path.module}/Microsoft.AzureRedHatOpenShift.json")

  parameters 		= {
    clusterName			= var.aro_name
    clusterResourceGroupName 	= join("-", [var.aro_vnet_resource_group_name, "MANAGED"])
    location			= var.aro_location

    tags			= jsonencode(var.tags)

    apiServerVisibility		= var.aro_api_server_visibility
    ingressVisibility		= var.aro_ingress_visibility

    aadClientId			= var.aro_client_id
    aadClientSecret		= var.aro_client_secret

    clusterVnetId		= azurerm_virtual_network.aro_vnet.id
    workerSubnetId		= azurerm_subnet.aro_worker_subnet.id
    masterSubnetId		= azurerm_subnet.aro_master_subnet.id

    workerCount			= var.aro_worker_node_count
    workerVmSize		= var.aro_worker_node_size

    pullsecret			= data.azurerm_key_vault_secret.pull-secret.value
  }

  deployment_mode 	= "Incremental"

  timeouts {
    create = "90m"
  }

  depends_on		= [
    azurerm_role_assignment.vnet_assignment,
    azurerm_role_assignment.rp_assignment,
  ]
}

resource "azuread_application" "redirect-uri" {
  name			= var.aro_client_name
  reply_urls            = azurerm_template_deployment.azure-arocluster.outputs["oauthCallbackURL"]

  depends_on = [
    azurerm_template_deployment.azure-arocluster
  ]
}

resource "null_resource" "azuread-connect" {
  provisioner "local-exec" {
    command 		= <<EOC
      echo "POST-DEPLOY-CONNECT"
      export ARO_NAME=${var.aro_name}
      export ARO_RG=${var.aro_vnet_resource_group_name}
      export CLIENT_ID=${var.aro_client_id}
      export CLIENT_SECRET=${var.aro_client_secret}

      export KUBE_PASSWORD=$(az aro list-credentials -n $ARO_NAME -g $ARO_RG --query kubeadminPassword -o tsv 2> /dev/null)
      export API_SERVER=$(az aro show -n $ARO_NAME -g $ARO_RG --query apiserverProfile.url -o tsv 2> /dev/null )
      export SECRET_NAME="openid-client-secret-azuread"

      oc login $API_SERVER -u kubeadmin -p $KUBE_PASSWORD 2> /dev/null
      oc delete secret $SECRET_NAME -n openshift-config 2> /dev/null
      oc create secret generic $SECRET_NAME -n openshift-config --from-literal=clientSecret=$CLIENT_SECRET 2> /dev/null

      export TENANT_ID=${data.azurerm_client_config.current.tenant_id}
      ./azuread-connect.sh $TENANT_ID $CLIENT_ID $SECRET_NAME
    EOC
    interpreter 	= ["/bin/bash", "-c"]
  }
  
  provisioner "local-exec" {
    command 		= <<EOC
      echo "POST-DEPLOY-SYNC"
      ./azuread-sync.sh
    EOC
    interpreter 	= ["/bin/bash", "-c"]
  }
  
  provisioner "local-exec" {
    command 		= <<EOC
      echo "Access Configured"
      echo "POST-DEPLOY-CONSOLE"
      WEB_CONSOLE=$(az aro show -n ${var.aro_name} -g ${var.aro_vnet_resource_group_name} --query consoleProfile.url -o tsv)
      echo "You can accesss the Web Console following this url: $WEB_CONSOLE"
    EOC
    interpreter 	= ["/bin/bash", "-c"]
  }

  depends_on = [
    null_resource.redirect-uri
  ]
}
