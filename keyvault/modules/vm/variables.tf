variable "resource_group_name" { type = string }
variable "location" { type = string }
variable "name_prefix" { type = string }
variable "suffix" { type = string }
variable "subnet_id" { type = string }
variable "bastion_subnet_cidr" { type = string }
variable "vm_size" { type = string }
variable "instance_count" { type = number }
variable "instance_number" {
  type    = number
  default = 1
}
variable "os_disk_size_gb" { type = number }
variable "data_disk_size_gb" { type = number }
variable "admin_username" { type = string }
variable "admin_password" {
  type      = string
  default   = null
  sensitive = true
}
variable "generate_admin_password" {
  type    = bool
  default = true
}
