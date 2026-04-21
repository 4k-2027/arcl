terraform {
  required_version = ">= 1.1.0"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.0"
    }
  }
}

provider "azurerm" {
  features {}
}

# --- Variables ---

variable "location" {
  default = "swedencentral"
}

variable "vmss_instances" {
  default = 2
}

variable "vm_size" {
  default = "Standard_B2s"
}

variable "admin_username" {
  default = "adminuser"
}

variable "db_host" {
  description = "IP du master PostgreSQL (OpenStack)"
}

variable "db_user" {
  default = "todo"
}

variable "db_password" {
  sensitive = true
}

variable "db_name" {
  default = "todos"
}

# --- Resource group & réseau ---

resource "azurerm_resource_group" "todo" {
  name     = "todo-app"
  location = var.location
}

resource "azurerm_virtual_network" "todo" {
  name                = "todo-vnet"
  resource_group_name = azurerm_resource_group.todo.name
  location            = var.location
  address_space       = ["10.2.0.0/16"]
}

resource "azurerm_subnet" "app" {
  name                 = "app-subnet"
  resource_group_name  = azurerm_resource_group.todo.name
  virtual_network_name = azurerm_virtual_network.todo.name
  address_prefixes     = ["10.2.1.0/24"]
}

resource "azurerm_network_security_group" "app" {
  name                = "todo-app-nsg"
  resource_group_name = azurerm_resource_group.todo.name
  location            = var.location

  security_rule {
    name                       = "allow-http"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "80"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }
}

# --- Load Balancer public ---

resource "azurerm_public_ip" "lb" {
  name                = "todo-lb-pip"
  resource_group_name = azurerm_resource_group.todo.name
  location            = var.location
  allocation_method   = "Static"
  sku                 = "Standard"
}

resource "azurerm_lb" "todo" {
  name                = "todo-lb"
  resource_group_name = azurerm_resource_group.todo.name
  location            = var.location
  sku                 = "Standard"

  frontend_ip_configuration {
    name                 = "public"
    public_ip_address_id = azurerm_public_ip.lb.id
  }
}

resource "azurerm_lb_backend_address_pool" "todo" {
  loadbalancer_id = azurerm_lb.todo.id
  name            = "app-pool"
}

resource "azurerm_lb_probe" "http" {
  loadbalancer_id = azurerm_lb.todo.id
  name            = "http-probe"
  protocol        = "Http"
  port            = 80
  request_path    = "/"
  interval_in_seconds = 5
  number_of_probes    = 2
}

resource "azurerm_lb_rule" "http" {
  loadbalancer_id                = azurerm_lb.todo.id
  name                           = "http"
  protocol                       = "Tcp"
  frontend_port                  = 80
  backend_port                   = 80
  frontend_ip_configuration_name = "public"
  backend_address_pool_ids       = [azurerm_lb_backend_address_pool.todo.id]
  probe_id                       = azurerm_lb_probe.http.id
}

# --- Cloud-init ---

locals {
  app_cloud_init = base64encode(templatefile("${path.module}/../cloud-init/app-vm.sh.tpl", {
    db_host      = var.db_host
    db_user      = var.db_user
    db_password  = var.db_password
    db_name      = var.db_name
    app_source   = file("${path.module}/../../back/main.py")
    front_source = file("${path.module}/../../front/index.html")
  }))
}

# --- VMSS ---

resource "azurerm_linux_virtual_machine_scale_set" "app" {
  name                = "todo-vmss"
  resource_group_name = azurerm_resource_group.todo.name
  location            = var.location
  sku                 = var.vm_size
  instances           = var.vmss_instances
  admin_username      = var.admin_username
  upgrade_mode        = "Automatic"

  admin_ssh_key {
    username   = var.admin_username
    public_key = file(pathexpand("~/.ssh/id_rsa.pub"))
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "0001-com-ubuntu-server-jammy"
    sku       = "22_04-lts-gen2"
    version   = "latest"
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
  }

  network_interface {
    name    = "nic"
    primary = true

    ip_configuration {
      name                                   = "internal"
      primary                                = true
      subnet_id                              = azurerm_subnet.app.id
      load_balancer_backend_address_pool_ids = [azurerm_lb_backend_address_pool.todo.id]
    }
  }

  custom_data = local.app_cloud_init

  automatic_instance_repair {
    enabled      = true
    grace_period = "PT10M"
  }
}

# --- Outputs ---

output "app_public_ip" {
  value = azurerm_public_ip.lb.ip_address
}
