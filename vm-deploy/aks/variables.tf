variable "resource_group_name" {
  description = "AKS resource group name"
  type        = string
}

variable "location" {
  description = "Azure region for AKS"
  type        = string
}

variable "cluster_name" {
  description = "AKS cluster name"
  type        = string
}

variable "kubernetes_version" {
  description = "AKS Kubernetes version"
  type        = string
}

variable "linux_node_count" {
  description = "Linux system node pool count"
  type        = number
  default     = 1
}

variable "linux_node_vm_size" {
  description = "Linux system node pool VM size"
  type        = string
  default     = "Standard_D4s_v3"
}

variable "windows_node_count" {
  description = "Windows user node pool count"
  type        = number
  default     = 2
}

variable "windows_node_vm_size" {
  description = "Windows user node pool VM size"
  type        = string
  default     = "Standard_D4_v3"
}

variable "windows_node_pool_name" {
  description = "Windows user node pool name"
  type        = string
  default     = "win"
}

variable "windows_admin_username" {
  description = "Windows admin username for AKS"
  type        = string
}

variable "windows_admin_password" {
  description = "Windows admin password for AKS"
  type        = string
  sensitive   = true
}

variable "log_analytics_workspace_name" {
  description = "Log Analytics workspace name for AKS monitoring addon"
  type        = string
  default     = null
  nullable    = true
}

variable "ingress_release_name" {
  description = "Helm release name for ingress-nginx"
  type        = string
  default     = "nginx-ingress"
}

variable "ingress_chart_version" {
  description = "Optional chart version for ingress-nginx"
  type        = string
  default     = null
  nullable    = true
}

variable "create_registry_secret" {
  description = "Whether to create docker-registry pull secret in Kubernetes"
  type        = bool
  default     = false
}

variable "registry_secret_name" {
  description = "Kubernetes docker-registry secret name"
  type        = string
  default     = "sitecore-docker-registry"
}

variable "registry_server" {
  description = "Container registry server (for docker-registry secret)"
  type        = string
  default     = null
  nullable    = true
}

variable "registry_username" {
  description = "Container registry username (for docker-registry secret)"
  type        = string
  default     = null
  nullable    = true
}

variable "registry_password" {
  description = "Container registry password (for docker-registry secret)"
  type        = string
  sensitive   = true
  default     = null
  nullable    = true
}
