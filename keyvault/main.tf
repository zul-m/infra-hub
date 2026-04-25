resource "random_string" "suffix" {
  length  = 5
  special = false
  upper   = false
}

resource "azurerm_resource_group" "rg" {
  name     = "${local.name_prefix}-${random_string.suffix.result}"
  location = var.location
}

module "network" {
  source              = "./modules/network"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  name_prefix         = local.name_prefix
  suffix              = random_string.suffix.result
  vnet_cidr           = var.vnet_cidr
  subnet_bastion_cidr = var.subnet_bastion_cidr
  subnet_vm_cidr      = var.subnet_vm_cidr
}

module "bastion" {
  source              = "./modules/bastion"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  name_prefix         = local.name_prefix
  suffix              = random_string.suffix.result
  bastion_subnet_id   = module.network.bastion_subnet_id
}

module "keyvault" {
  source                  = "./modules/keyvault"
  resource_group_name     = azurerm_resource_group.rg.name
  location                = azurerm_resource_group.rg.location
  name_prefix             = local.name_prefix
  suffix                  = random_string.suffix.result
  admin_username          = var.admin_username
  admin_password          = var.admin_password
  generate_admin_password = var.generate_admin_password
}

module "vm" {
  source                  = "./modules/vm"
  resource_group_name     = azurerm_resource_group.rg.name
  location                = azurerm_resource_group.rg.location
  name_prefix             = local.name_prefix
  suffix                  = random_string.suffix.result
  subnet_id               = module.network.vm_subnet_id
  bastion_subnet_cidr     = var.subnet_bastion_cidr
  vm_size                 = var.vm_size
  instance_count          = var.vm_instance_count
  os_disk_size_gb         = var.os_disk_size_gb
  data_disk_size_gb       = var.data_disk_size_gb
  admin_username          = var.admin_username
  admin_password          = module.keyvault.admin_password
  generate_admin_password = false
}
