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
  default     = null
  nullable    = true
}

variable "vm_subnet_cidr" {
  description = "Subnet CIDR for VM"
  type        = string
  default     = null
  nullable    = true
}

variable "vm_image_publisher" {
  description = "Azure VM image publisher"
  type        = string
}

variable "vm_image_offer" {
  description = "Azure VM image offer"
  type        = string
}

variable "vm_image_sku" {
  description = "Azure VM image SKU (e.g. 2019-datacenter-gensecond, 2022-datacenter-g2, 2025-datacenter-g2, win10-22h2-pro-g2, win11-23h2-pro)"
  type        = string
}

variable "vm_image_version" {
  description = "Azure VM image version"
  type        = string
}

variable "vm_size" {
  description = "VM size"
  type        = string
}

variable "vm_admin_username" {
  description = "Local admin username for the VM"
  type        = string
}

variable "vm_admin_password" {
  description = "Local admin password for the VM"
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

variable "ansible_playbook_path" {
  description = "Path to the Ansible playbook used by Terraform local-exec"
  type        = string
  default     = "./ansible/playbooks/applications.yml"
}

variable "allowed_cidrs" {
  description = "CIDR ranges allowed inbound RDP (3389) and WinRM (5986) — typically your workstation's public IP"
  type        = list(string)
  default     = []
}

variable "sql_admin_username" {
  description = "SQL login to create with sysadmin role when mixed mode is enabled"
  type        = string
  default     = "sqladmin"
}

variable "sql_admin_password" {
  description = "Password for SQL Server sa login when mixed mode is enabled"
  type        = string
  sensitive   = true
  default     = ""
}
