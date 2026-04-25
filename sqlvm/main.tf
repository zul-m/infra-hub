locals {
  prefix              = "${var.prefix}-${formatdate("MMDD", plantimestamp())}"
  resource_group_name = local.prefix
  onprem_vm_name      = "${local.prefix}-vm"
  sql_vm_name         = "${local.prefix}-sql"
}

resource "azurerm_resource_group" "main" {
  name     = local.resource_group_name
  location = var.location
}

resource "azurerm_virtual_network" "main" {
  name                = "${local.prefix}-vnet"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  address_space       = [var.vnet_cidr]
}

resource "azurerm_subnet" "vm" {
  name                            = "VMSubnet"
  resource_group_name             = azurerm_resource_group.main.name
  virtual_network_name            = azurerm_virtual_network.main.name
  address_prefixes                = [var.vm_subnet_cidr]
  default_outbound_access_enabled = false
}

resource "azurerm_subnet" "bastion" {
  name                 = "AzureBastionSubnet"
  resource_group_name  = azurerm_resource_group.main.name
  virtual_network_name = azurerm_virtual_network.main.name
  address_prefixes     = var.bastion_subnet_cidr
}

resource "azurerm_network_security_group" "vm" {
  name                = "${local.prefix}-nsg"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
}

resource "azurerm_network_security_rule" "allow_rdp_from_bastion" {
  name                        = "AllowRDPFromBastion"
  priority                    = 100
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "3389"
  source_address_prefixes     = var.bastion_subnet_cidr
  destination_address_prefix  = "*"
  resource_group_name         = azurerm_resource_group.main.name
  network_security_group_name = azurerm_network_security_group.vm.name
}

resource "azurerm_subnet_network_security_group_association" "vm" {
  subnet_id                 = azurerm_subnet.vm.id
  network_security_group_id = azurerm_network_security_group.vm.id
}

resource "azurerm_public_ip" "bastion" {
  name                = "${local.prefix}-bastion-pip"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  allocation_method   = "Static"
  sku                 = "Standard"
}

resource "azurerm_public_ip" "nat" {
  name                = "${local.prefix}-nat-pip"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  allocation_method   = "Static"
  sku                 = "Standard"
}

resource "azurerm_nat_gateway" "vm" {
  name                = "${local.prefix}-nat"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  sku_name            = "Standard"
}

resource "azurerm_nat_gateway_public_ip_association" "vm" {
  nat_gateway_id       = azurerm_nat_gateway.vm.id
  public_ip_address_id = azurerm_public_ip.nat.id
}

resource "azurerm_subnet_nat_gateway_association" "vm" {
  subnet_id      = azurerm_subnet.vm.id
  nat_gateway_id = azurerm_nat_gateway.vm.id
}

resource "azurerm_bastion_host" "main" {
  name                = "${local.prefix}-bastion"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name

  ip_configuration {
    name                 = "${local.prefix}-bastion-ipconfig"
    subnet_id            = azurerm_subnet.bastion.id
    public_ip_address_id = azurerm_public_ip.bastion.id
  }

}

resource "azurerm_network_interface" "onprem" {
  name                = "${local.prefix}-vm-nic"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name

  ip_configuration {
    name                          = "${local.prefix}-vm-ipconfig"
    subnet_id                     = azurerm_subnet.vm.id
    private_ip_address_allocation = "Dynamic"
  }

}

resource "azurerm_network_interface" "sql" {
  name                = "${local.prefix}-sql-nic"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name

  ip_configuration {
    name                          = "${local.prefix}-sql-ipconfig"
    subnet_id                     = azurerm_subnet.vm.id
    private_ip_address_allocation = "Dynamic"
  }

}

resource "azurerm_windows_virtual_machine" "onprem" {
  name                = local.onprem_vm_name
  computer_name       = local.onprem_vm_name
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  size                = var.vm_size
  admin_username      = var.admin_username
  admin_password      = var.admin_password

  patch_mode                 = "AutomaticByOS"
  provision_vm_agent         = true
  enable_automatic_updates   = true
  network_interface_ids      = [azurerm_network_interface.onprem.id]
  allow_extension_operations = true

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "StandardSSD_LRS"
  }

  source_image_reference {
    publisher = "MicrosoftWindowsServer"
    offer     = "WindowsServer"
    sku       = "2022-datacenter-g2"
    version   = "latest"
  }

}

resource "azurerm_windows_virtual_machine" "sql" {
  name                = local.sql_vm_name
  computer_name       = local.sql_vm_name
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  size                = var.vm_size
  admin_username      = var.admin_username
  admin_password      = var.admin_password

  patch_mode                 = "AutomaticByOS"
  provision_vm_agent         = true
  enable_automatic_updates   = true
  network_interface_ids      = [azurerm_network_interface.sql.id]
  allow_extension_operations = true

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "StandardSSD_LRS"
  }

  source_image_reference {
    publisher = "MicrosoftSQLServer"
    offer     = "sql2022-ws2022"
    sku       = "sqldev-gen2"
    version   = "latest"
  }

}

resource "azurerm_mssql_virtual_machine" "sql" {
  virtual_machine_id               = azurerm_windows_virtual_machine.sql.id
  sql_license_type                 = "PAYG"
  r_services_enabled               = false
  sql_connectivity_port            = 1433
  sql_connectivity_type            = "PRIVATE"
  sql_connectivity_update_username = var.sql_auth_username
  sql_connectivity_update_password = var.sql_auth_password
}

resource "azurerm_dev_test_global_vm_shutdown_schedule" "onprem" {
  virtual_machine_id    = azurerm_windows_virtual_machine.onprem.id
  location              = azurerm_resource_group.main.location
  enabled               = true
  daily_recurrence_time = var.auto_shutdown_time
  timezone              = var.auto_shutdown_timezone

  notification_settings {
    enabled = false
  }
}

resource "azurerm_dev_test_global_vm_shutdown_schedule" "sql" {
  virtual_machine_id    = azurerm_windows_virtual_machine.sql.id
  location              = azurerm_resource_group.main.location
  enabled               = true
  daily_recurrence_time = var.auto_shutdown_time
  timezone              = var.auto_shutdown_timezone

  notification_settings {
    enabled = false
  }
}
