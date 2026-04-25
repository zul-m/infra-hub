resource "random_password" "admin" {
  count   = var.generate_admin_password && var.admin_password == null ? 1 : 0
  length  = 24
  special = true
}

locals {
  password = var.admin_password != null ? var.admin_password : random_password.admin[0].result
}

resource "azurerm_network_interface" "nic" {
  name                = "${var.name_prefix}-${var.suffix}-nic"
  location            = var.location
  resource_group_name = var.resource_group_name
  ip_configuration {
    name                          = "ipcfg"
    subnet_id                     = var.subnet_id
    private_ip_address_allocation = "Dynamic"
  }
}

resource "azurerm_windows_virtual_machine" "vm" {
  name                  = "${var.name_prefix}-${var.suffix}-vm"
  location              = var.location
  resource_group_name   = var.resource_group_name
  size                  = var.vm_size
  admin_username        = var.admin_username
  admin_password        = local.password
  network_interface_ids = [azurerm_network_interface.nic.id]
  computer_name         = substr("${var.name_prefix}${var.instance_number}", 0, 15)
  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Premium_LRS"
    disk_size_gb         = var.os_disk_size_gb
  }
  source_image_reference {
    publisher = "MicrosoftWindowsServer"
    offer     = "WindowsServer"
    sku       = "2019-Datacenter"
    version   = "latest"
  }
}
