locals {
  workspace_name = var.log_analytics_workspace_name != null && length(trimspace(var.log_analytics_workspace_name)) > 0 ? trimspace(var.log_analytics_workspace_name) : "${var.cluster_name}-law"
  ingress_values = {
    controller = {
      replicaCount = 2
      nodeSelector = {
        "kubernetes.io/os" = "linux"
      }
      service = {
        externalTrafficPolicy = "Local"
      }
      admissionWebhooks = {
        patch = {
          nodeSelector = {
            "kubernetes.io/os" = "linux"
          }
        }
      }
    }
    defaultBackend = {
      nodeSelector = {
        "kubernetes.io/os" = "linux"
      }
    }
  }

  kube_host     = try(azurerm_kubernetes_cluster.aks.kube_admin_config[0].host, azurerm_kubernetes_cluster.aks.kube_config[0].host)
  kube_username = try(azurerm_kubernetes_cluster.aks.kube_admin_config[0].username, azurerm_kubernetes_cluster.aks.kube_config[0].username)
  kube_password = try(azurerm_kubernetes_cluster.aks.kube_admin_config[0].password, azurerm_kubernetes_cluster.aks.kube_config[0].password)
  kube_client_certificate = try(
    base64decode(azurerm_kubernetes_cluster.aks.kube_admin_config[0].client_certificate),
    base64decode(azurerm_kubernetes_cluster.aks.kube_config[0].client_certificate)
  )
  kube_client_key = try(
    base64decode(azurerm_kubernetes_cluster.aks.kube_admin_config[0].client_key),
    base64decode(azurerm_kubernetes_cluster.aks.kube_config[0].client_key)
  )
  kube_cluster_ca_certificate = try(
    base64decode(azurerm_kubernetes_cluster.aks.kube_admin_config[0].cluster_ca_certificate),
    base64decode(azurerm_kubernetes_cluster.aks.kube_config[0].cluster_ca_certificate)
  )
}

provider "kubernetes" {
  host                   = local.kube_host
  username               = local.kube_username
  password               = local.kube_password
  client_certificate     = local.kube_client_certificate
  client_key             = local.kube_client_key
  cluster_ca_certificate = local.kube_cluster_ca_certificate
}

provider "helm" {
  kubernetes {
    host                   = local.kube_host
    username               = local.kube_username
    password               = local.kube_password
    client_certificate     = local.kube_client_certificate
    client_key             = local.kube_client_key
    cluster_ca_certificate = local.kube_cluster_ca_certificate
  }
}

resource "azurerm_resource_group" "aks" {
  name     = var.resource_group_name
  location = var.location
}

resource "azurerm_log_analytics_workspace" "aks" {
  name                = local.workspace_name
  location            = azurerm_resource_group.aks.location
  resource_group_name = azurerm_resource_group.aks.name
  sku                 = "PerGB2018"
  retention_in_days   = 30
}

resource "azurerm_kubernetes_cluster" "aks" {
  name                = var.cluster_name
  location            = azurerm_resource_group.aks.location
  resource_group_name = azurerm_resource_group.aks.name
  dns_prefix          = var.cluster_name
  kubernetes_version  = var.kubernetes_version
  sku_tier            = var.aks_sku_tier

  default_node_pool {
    name                 = "system"
    vm_size              = var.linux_node_vm_size
    node_count           = var.linux_node_count
    type                 = "VirtualMachineScaleSets"
    orchestrator_version = var.kubernetes_version
    os_disk_size_gb      = 128
  }

  windows_profile {
    admin_username = var.windows_admin_username
    admin_password = var.windows_admin_password
  }

  identity {
    type = "SystemAssigned"
  }

  network_profile {
    network_plugin    = "azure"
    load_balancer_sku = "standard"
  }

  oms_agent {
    log_analytics_workspace_id = azurerm_log_analytics_workspace.aks.id
  }
}

resource "azurerm_kubernetes_cluster_node_pool" "windows" {
  count                 = var.windows_node_count > 0 ? 1 : 0
  name                  = var.windows_node_pool_name
  kubernetes_cluster_id = azurerm_kubernetes_cluster.aks.id
  vm_size               = var.windows_node_vm_size
  node_count            = var.windows_node_count
  orchestrator_version  = var.kubernetes_version
  os_type               = "Windows"
  os_sku                = "Windows2022"
  mode                  = "User"
}

resource "helm_release" "ingress_nginx" {
  name       = var.ingress_release_name
  repository = "https://kubernetes.github.io/ingress-nginx"
  chart      = "ingress-nginx"
  version    = var.ingress_chart_version

  values = [yamlencode(local.ingress_values)]

  depends_on = [
    azurerm_kubernetes_cluster.aks,
    azurerm_kubernetes_cluster_node_pool.windows,
  ]
}

resource "kubernetes_secret" "registry" {
  count = var.create_registry_secret ? 1 : 0

  metadata {
    name = var.registry_secret_name
  }

  type = "kubernetes.io/dockerconfigjson"

  data = {
    ".dockerconfigjson" = jsonencode({
      auths = {
        (var.registry_server) = {
          username = var.registry_username
          password = var.registry_password
          auth     = base64encode("${var.registry_username}:${var.registry_password}")
        }
      }
    })
  }

  depends_on = [
    azurerm_kubernetes_cluster.aks,
    azurerm_kubernetes_cluster_node_pool.windows,
  ]
}
