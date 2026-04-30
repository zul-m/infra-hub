data "http" "my_ip" {
  url = "https://api.ipify.org?format=json"
}

locals {
  date_suffix         = formatdate("MMDD", plantimestamp())
  resource_prefix     = "${var.prefix}-${local.date_suffix}"
  resource_group_name = "${var.prefix}-${var.env}-${local.date_suffix}"
  my_ip               = jsondecode(data.http.my_ip.response_body).ip
  allowed_cidrs       = concat(["${local.my_ip}/32"], var.allowed_cidrs)
  vnet_cidr           = coalesce(var.vnet_cidr, "10.20.0.0/16")
  vm_subnet_cidr      = coalesce(var.vm_subnet_cidr, cidrsubnet(local.vnet_cidr, 8, 1))
}

resource "azurerm_resource_group" "main" {
  name     = local.resource_group_name
  location = var.location
}

resource "azurerm_virtual_network" "main" {
  name                = "${local.resource_prefix}-vnet"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  address_space       = [local.vnet_cidr]
}

resource "azurerm_subnet" "vm" {
  name                 = "vm-subnet"
  resource_group_name  = azurerm_resource_group.main.name
  virtual_network_name = azurerm_virtual_network.main.name
  address_prefixes     = [local.vm_subnet_cidr]
}

resource "azurerm_network_security_group" "vm" {
  name                = "${local.resource_prefix}-nsg"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
}

resource "azurerm_network_security_rule" "allow_rdp" {
  name                        = "AllowRDP"
  priority                    = 100
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "3389"
  source_address_prefixes     = local.allowed_cidrs
  destination_address_prefix  = "*"
  resource_group_name         = azurerm_resource_group.main.name
  network_security_group_name = azurerm_network_security_group.vm.name
}

resource "azurerm_network_security_rule" "allow_winrm" {
  name                        = "AllowWinRM"
  priority                    = 110
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "5986"
  source_address_prefixes     = local.allowed_cidrs
  destination_address_prefix  = "*"
  resource_group_name         = azurerm_resource_group.main.name
  network_security_group_name = azurerm_network_security_group.vm.name
}

resource "azurerm_subnet_network_security_group_association" "vm" {
  subnet_id                 = azurerm_subnet.vm.id
  network_security_group_id = azurerm_network_security_group.vm.id
}

resource "azurerm_public_ip" "vm" {
  name                = "${local.resource_prefix}-vm-pip"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  allocation_method   = "Static"
  sku                 = "Standard"
}



resource "azurerm_network_interface" "vm" {
  name                = "${local.resource_prefix}-vm-nic"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name

  ip_configuration {
    name                          = "${local.resource_prefix}-vm-ipconfig"
    subnet_id                     = azurerm_subnet.vm.id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.vm.id
  }
}

resource "azurerm_windows_virtual_machine" "vm" {
  name                = "${local.resource_prefix}-vm"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  size                = var.vm_size
  admin_username      = var.vm_admin_username
  admin_password      = var.vm_admin_password

  patch_mode                 = "AutomaticByOS"
  provision_vm_agent         = true
  enable_automatic_updates   = true
  network_interface_ids      = [azurerm_network_interface.vm.id]
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

resource "azurerm_virtual_machine_extension" "winrm_https" {
  name                 = "WinRM"
  virtual_machine_id   = azurerm_windows_virtual_machine.vm.id
  publisher            = "Microsoft.Compute"
  type                 = "CustomScriptExtension"
  type_handler_version = "1.10"

  protected_settings = jsonencode({
    commandToExecute = "powershell -ExecutionPolicy Unrestricted -Command \"$cert = New-SelfSignedCertificate -DnsName $env:COMPUTERNAME -CertStoreLocation Cert:\\LocalMachine\\My; New-Item -Path WSMan:\\LocalHost\\Listener -Transport HTTPS -Address * -CertificateThumbPrint $cert.Thumbprint -Force; netsh advfirewall firewall add rule name='WinRM HTTPS' dir=in action=allow protocol=TCP localport=5986 | Out-Null\""
  })
}

resource "azurerm_dev_test_global_vm_shutdown_schedule" "vm" {
  virtual_machine_id    = azurerm_windows_virtual_machine.vm.id
  location              = azurerm_resource_group.main.location
  enabled               = true
  daily_recurrence_time = var.auto_shutdown_time
  timezone              = var.auto_shutdown_timezone

  notification_settings {
    enabled = false
  }
}

resource "terraform_data" "install_applications" {
  input = {
    vm_name   = azurerm_windows_virtual_machine.vm.name
    target_ip = azurerm_public_ip.vm.ip_address
  }

  triggers_replace = [
    azurerm_windows_virtual_machine.vm.id,
    azurerm_public_ip.vm.ip_address,
  ]

  provisioner "local-exec" {
    command = <<-EOT
      $user = $env:ANSIBLE_WIN_USER
      $pass = $env:ANSIBLE_WIN_PASSWORD
      $sqlUser = $env:SQL_ADMIN_USERNAME
      $sqlPass = $env:SQL_ADMIN_PASSWORD
      Write-Host "[install_applications] Preparing WSL path..."
      $cwd = (Get-Location).Path
      $cwdForWsl = $cwd -replace '\\', '/'
      $wslpath = (wsl wslpath -a "$cwdForWsl").Trim()
      if (-not $wslpath) {
        throw "Failed to convert working directory to a WSL path"
      }
      $env:ANSIBLE_STDOUT_CALLBACK = "default"
      $env:ANSIBLE_CALLBACK_RESULT_FORMAT = "yaml"
      $env:ANSIBLE_DISPLAY_FAILED_STDERR = "true"
      Write-Host ""
      Write-Host "============================================================"
      Write-Host "[install_applications] Ansible provisioning started"
      Write-Host "============================================================"
      Write-Host "[install_applications] Installing Ansible collections..."
      Write-Host "[install_applications] Running playbook against ${self.input.target_ip}..."
      wsl bash -lc "cd '$wslpath' && ansible-galaxy collection install -r ansible/requirements.yml && ansible-playbook '${var.ansible_playbook_path}' -i '${self.input.target_ip},' -e 'ansible_connection=winrm ansible_port=5986 ansible_winrm_transport=ntlm ansible_winrm_server_cert_validation=ignore ansible_user=$user ansible_password=$pass sql_admin_username=$sqlUser sql_admin_password=$sqlPass'"
      Write-Host "============================================================"
      Write-Host "[install_applications] Completed."
    EOT

    environment = {
      ANSIBLE_WIN_USER     = var.vm_admin_username
      ANSIBLE_WIN_PASSWORD = nonsensitive(var.vm_admin_password)
      SQL_ADMIN_USERNAME   = var.sql_admin_username
      SQL_ADMIN_PASSWORD   = nonsensitive(var.sql_admin_password)
    }

    interpreter = ["PowerShell", "-NoProfile", "-NonInteractive", "-Command"]
  }

  depends_on = [
    azurerm_network_security_rule.allow_winrm,
    azurerm_virtual_machine_extension.winrm_https,
  ]
}
