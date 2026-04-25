variable "resource_group_name" { type = string }
variable "location" { type = string }
variable "name_prefix" { type = string }
variable "suffix" { type = string }
variable "admin_password" {
  type      = string
  default   = null
  sensitive = true
}
variable "admin_username" {
  type = string
}
variable "generate_admin_password" {
  type    = bool
  default = true
}


