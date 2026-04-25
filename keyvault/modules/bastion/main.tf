resource "azurerm_public_ip" "pip" {
  name                = "${var.name_prefix}-${var.suffix}-pip-bastion"
  location            = var.location
  resource_group_name = var.resource_group_name
  allocation_method   = "Static"
  sku                 = "Standard"
}

resource "azurerm_bastion_host" "bas" {
  name                = "${var.name_prefix}-${var.suffix}-bas"
  location            = var.location
  resource_group_name = var.resource_group_name
  sku                 = "Standard"
  ip_configuration {
    name                 = "cfg"
    subnet_id            = var.bastion_subnet_id
    public_ip_address_id = azurerm_public_ip.pip.id
  }
}
