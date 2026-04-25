resource "random_password" "admin" {
  count   = var.generate_admin_password ? 1 : 0
  length  = 24
  special = true
}

resource "azurerm_key_vault" "kv" {
  name                        = "${var.name_prefix}-${var.suffix}-kv"
  location                    = var.location
  resource_group_name         = var.resource_group_name
  enabled_for_disk_encryption = true
  tenant_id                   = data.azurerm_client_config.current.tenant_id
  soft_delete_retention_days  = 7
  purge_protection_enabled    = false
  rbac_authorization_enabled  = true

  sku_name = "standard"
}

resource "azurerm_role_assignment" "kv_secrets_officer" {
  scope                = azurerm_key_vault.kv.id
  role_definition_name = "Key Vault Secrets Officer"
  principal_id         = data.azurerm_client_config.current.object_id
}

resource "time_sleep" "wait_for_rbac_propagation" {
  depends_on = [azurerm_role_assignment.kv_secrets_officer]

  create_duration = "300s"
}

data "azurerm_client_config" "current" {}

resource "azurerm_key_vault_secret" "admin_password" {
  count        = var.generate_admin_password ? 1 : 0
  name         = "${var.name_prefix}-${var.suffix}-vm-password"
  value        = random_password.admin[0].result
  key_vault_id = azurerm_key_vault.kv.id

  depends_on = [time_sleep.wait_for_rbac_propagation]
}

resource "azurerm_key_vault_secret" "provided_admin_password" {
  count        = !var.generate_admin_password && var.admin_password != null ? 1 : 0
  name         = "${var.name_prefix}-${var.suffix}-vm-password"
  value        = var.admin_password
  key_vault_id = azurerm_key_vault.kv.id

  depends_on = [time_sleep.wait_for_rbac_propagation]
}

resource "azurerm_key_vault_secret" "admin_username" {
  count        = var.admin_username != null ? 1 : 0
  name         = "${var.name_prefix}-${var.suffix}-vm-username"
  value        = var.admin_username
  key_vault_id = azurerm_key_vault.kv.id

  depends_on = [time_sleep.wait_for_rbac_propagation]
}


