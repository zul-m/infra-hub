output "resource_group_name" {
  value = azurerm_resource_group.main.name
}

output "vnet_name" {
  value = azurerm_virtual_network.main.name
}

output "onprem_vm_private_ip" {
  value = azurerm_network_interface.onprem.private_ip_address
}

output "sql_vm_private_ip" {
  value = azurerm_network_interface.sql.private_ip_address
}

output "bastion_host_name" {
  value = azurerm_bastion_host.main.name
}

output "nat_gateway_public_ip" {
  value = azurerm_public_ip.nat.ip_address
}

output "rdp_target" {
  value = "${azurerm_network_interface.onprem.private_ip_address}:3389"
}

output "sql_server_target" {
  value = "${azurerm_network_interface.sql.private_ip_address},1433"
}
