variable "subscription_id" {
  type = string
}
variable "tenant_id" {
  type = string
}
variable "location" {
  type    = string
  default = "southeastasia"
}
variable "project" {
  type    = string
  default = "sitecore-aks"
}

variable "vnet_cidr" {
  type    = string
  default = "10.50.0.0/16"
}
variable "subnet_bastion_cidr" {
  type    = string
  default = "10.50.0.0/26"
}
variable "subnet_vm_cidr" {
  type    = string
  default = "10.50.1.0/24"
}

variable "vm_size" {
  type    = string
  default = "Standard_D8s_v5"
}
variable "vm_instance_count" {
  type    = number
  default = 1
}
variable "os_disk_size_gb" {
  type    = number
  default = 256
}
variable "data_disk_size_gb" {
  type    = number
  default = 256
}

variable "admin_username" {
  type    = string
  default = "azureuser"
}
variable "admin_password" {
  type      = string
  sensitive = true
  default   = null
}
variable "generate_admin_password" {
  type    = bool
  default = true
}
