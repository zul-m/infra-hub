output "resource_group_name" {
  value = azurerm_resource_group.main.name
}

output "vnet_name" {
  value = azurerm_virtual_network.main.name
}

output "vm_private_ip" {
  value = azurerm_network_interface.vm.private_ip_address
}

output "vm_public_ip" {
  value = azurerm_public_ip.vm.ip_address
}

output "rdp_target" {
  value = "${azurerm_public_ip.vm.ip_address}:3389"
}

output "vm_name" {
  value = azurerm_windows_virtual_machine.vm.name
}
