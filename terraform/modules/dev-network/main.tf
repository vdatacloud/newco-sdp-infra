# Dev private network (infra I3c): storage and Key Vault reachable only through private endpoints; a small
# Tailscale subnet router brings the tailnet (the Mac, 192.168.1.7) into the VNet. No inbound from the internet.

terraform {
  required_version = ">= 1.9"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
  }
}

locals {
  zones = {
    blob  = "privatelink.blob.core.windows.net"
    vault = "privatelink.vaultcore.azure.net"
  }
  # Azure's resolver, reachable only from inside the VNet; dnsmasq on the router forwards tailnet queries to it.
  azure_dns = "168.63.129.16"
}

resource "azurerm_virtual_network" "this" {
  name                = var.names.vnet
  resource_group_name = var.resource_group_name
  location            = var.location
  address_space       = [var.address_space]
  tags                = var.tags
}

resource "azurerm_subnet" "pe" {
  name                              = "snet-pe"
  resource_group_name               = var.resource_group_name
  virtual_network_name              = azurerm_virtual_network.this.name
  address_prefixes                  = [var.pe_subnet]
  private_endpoint_network_policies = "Enabled"
  default_outbound_access_enabled   = false
}

resource "azurerm_subnet" "router" {
  name                            = "snet-router"
  resource_group_name             = var.resource_group_name
  virtual_network_name            = azurerm_virtual_network.this.name
  address_prefixes                = [var.router_subnet]
  default_outbound_access_enabled = false
}

# Deny everything inbound from the internet; VNet-internal traffic (tailnet via the router) stays allowed.
resource "azurerm_network_security_group" "this" {
  for_each            = { pe = azurerm_subnet.pe.id, router = azurerm_subnet.router.id }
  name                = "${var.names.nsg}-${each.key}"
  resource_group_name = var.resource_group_name
  location            = var.location
  tags                = var.tags

  security_rule {
    name                       = "deny-internet-inbound"
    priority                   = 4000
    direction                  = "Inbound"
    access                     = "Deny"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "Internet"
    destination_address_prefix = "*"
  }
}

resource "azurerm_subnet_network_security_group_association" "this" {
  for_each                  = { pe = azurerm_subnet.pe.id, router = azurerm_subnet.router.id }
  subnet_id                 = each.value
  network_security_group_id = azurerm_network_security_group.this[each.key].id
}

# Outbound for the router only (package installs, Tailscale coordination): NAT, no public IP on the VM.
resource "azurerm_public_ip" "nat" {
  name                = var.names.nat_ip
  resource_group_name = var.resource_group_name
  location            = var.location
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = var.tags
}

resource "azurerm_nat_gateway" "this" {
  name                = var.names.nat
  resource_group_name = var.resource_group_name
  location            = var.location
  sku_name            = "Standard"
  tags                = var.tags
}

resource "azurerm_nat_gateway_public_ip_association" "this" {
  nat_gateway_id       = azurerm_nat_gateway.this.id
  public_ip_address_id = azurerm_public_ip.nat.id
}

resource "azurerm_subnet_nat_gateway_association" "router" {
  subnet_id      = azurerm_subnet.router.id
  nat_gateway_id = azurerm_nat_gateway.this.id
}

resource "azurerm_private_dns_zone" "this" {
  for_each            = local.zones
  name                = each.value
  resource_group_name = var.resource_group_name
  tags                = var.tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "this" {
  for_each              = local.zones
  name                  = "${var.names.vnet}-${each.key}"
  resource_group_name   = var.resource_group_name
  private_dns_zone_name = azurerm_private_dns_zone.this[each.key].name
  virtual_network_id    = azurerm_virtual_network.this.id
  tags                  = var.tags
}

resource "azurerm_private_endpoint" "blob" {
  for_each            = var.storage_account_ids
  name                = "${var.names.pe}-${each.key}"
  resource_group_name = var.resource_group_name
  location            = var.location
  subnet_id           = azurerm_subnet.pe.id
  tags                = var.tags

  private_service_connection {
    name                           = "blob"
    private_connection_resource_id = each.value
    subresource_names              = ["blob"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "blob"
    private_dns_zone_ids = [azurerm_private_dns_zone.this["blob"].id]
  }
}

resource "azurerm_private_endpoint" "vault" {
  name                = "${var.names.pe}-kv"
  resource_group_name = var.resource_group_name
  location            = var.location
  subnet_id           = azurerm_subnet.pe.id
  tags                = var.tags

  private_service_connection {
    name                           = "vault"
    private_connection_resource_id = var.key_vault_id
    subresource_names              = ["vault"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "vault"
    private_dns_zone_ids = [azurerm_private_dns_zone.this["vault"].id]
  }
}

resource "azurerm_network_interface" "router" {
  name                  = "${var.names.router}-nic"
  resource_group_name   = var.resource_group_name
  location              = var.location
  ip_forwarding_enabled = true
  tags                  = var.tags

  ip_configuration {
    name                          = "ipconfig"
    subnet_id                     = azurerm_subnet.router.id
    private_ip_address_allocation = "Static"
    private_ip_address            = cidrhost(var.router_subnet, 4)
  }
}

resource "azurerm_linux_virtual_machine" "router" {
  name                            = var.names.router
  resource_group_name             = var.resource_group_name
  location                        = var.location
  size                            = var.router_size
  zone                            = var.router_zone
  admin_username                  = "sdpadmin"
  disable_password_authentication = true
  network_interface_ids           = [azurerm_network_interface.router.id]
  encryption_at_host_enabled      = false
  tags                            = var.tags

  admin_ssh_key {
    username   = "sdpadmin"
    public_key = var.admin_ssh_public_key
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "ubuntu-24_04-lts"
    sku       = "server"
    version   = "latest"
  }

  # The auth key lands in VM custom data (and so in local Terraform state): use a one-off, pre-approved key
  # that expires within a day, so the copy in state is useless after first boot.
  custom_data = base64encode(templatefile("${path.module}/cloud-init.yaml.tftpl", {
    auth_key  = var.tailscale_auth_key
    hostname  = var.names.router
    routes    = join(",", [var.address_space])
    listen_ip = cidrhost(var.router_subnet, 4)
    azure_dns = local.azure_dns
  }))

  lifecycle {
    # A new key must not rebuild the router; rotate by re-authenticating on the box.
    ignore_changes = [custom_data]
  }
}

# The router is billed only while running: stop it every evening; start it when work begins.
resource "azurerm_dev_test_global_vm_shutdown_schedule" "router" {
  virtual_machine_id    = azurerm_linux_virtual_machine.router.id
  location              = var.location
  enabled               = true
  daily_recurrence_time = var.router_shutdown_time
  timezone              = var.router_shutdown_timezone
  tags                  = var.tags

  notification_settings {
    enabled = false
  }
}
