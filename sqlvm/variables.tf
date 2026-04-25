variable "prefix" {
  description = "Prefix for all resource names"
  type        = string
  default     = "mumu"
}

variable "location" {
  description = "Azure region"
  type        = string
}

variable "tenant_id" {
  description = "Azure Entra tenant ID"
  type        = string
}

variable "subscription_id" {
  description = "Azure subscription ID"
  type        = string
}

variable "vnet_cidr" {
  description = "VNet CIDR block"
  type        = string
}

variable "vm_subnet_cidr" {
  description = "Subnet CIDR for VMs"
  type        = string
}

variable "bastion_subnet_cidr" {
  description = "Subnet CIDR for Azure Bastion (must be /26 or larger)"
  type        = list(string)
}

variable "vm_size" {
  description = "VM size for both VMs"
  type        = string
}

variable "admin_username" {
  description = "Local admin username for both VMs"
  type        = string
}

variable "admin_password" {
  description = "Local admin password for both VMs"
  type        = string
  sensitive   = true
}

variable "sql_auth_username" {
  description = "SQL authentication login to configure"
  type        = string
}

variable "sql_auth_password" {
  description = "SQL authentication password"
  type        = string
  sensitive   = true
}

variable "auto_shutdown_time" {
  description = "Auto shutdown time in HHMM format"
  type        = string
}

variable "auto_shutdown_timezone" {
  description = "Auto shutdown timezone"
  type        = string
}
