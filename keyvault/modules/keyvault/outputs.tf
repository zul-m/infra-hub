output "admin_password" {
  value     = var.generate_admin_password ? random_password.admin[0].result : var.admin_password
  sensitive = true
}

output "key_vault_id" {
  value = azurerm_key_vault.kv.id
}

output "key_vault_name" {
  value = azurerm_key_vault.kv.name
}

output "admin_password_secret_id" {
  value = var.generate_admin_password ? azurerm_key_vault_secret.admin_password[0].id : azurerm_key_vault_secret.provided_admin_password[0].id
}

output "admin_username_secret_id" {
  value = azurerm_key_vault_secret.admin_username[0].id
}


