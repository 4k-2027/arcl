terraform {
  required_version = ">= 1.1.0"
  required_providers {
    openstack = {
      source  = "terraform-provider-openstack/openstack"
      version = "~> 1.54"
    }
  }
}

provider "openstack" {
  # Auth via env vars : OS_AUTH_URL, OS_USERNAME, OS_PASSWORD, OS_PROJECT_NAME, OS_REGION_NAME
}

# --- Variables ---

variable "image_name" {
  default = "Ubuntu-22.04"
}

variable "flavor_name" {
  default = "m1.small"
}

variable "keypair_name" {
  description = "Nom de la keypair OpenStack existante"
}

variable "external_network" {
  default = "public"
}

variable "db_user" {
  default = "todo"
}

variable "db_password" {
  sensitive = true
}

variable "replication_password" {
  sensitive = true
}

# --- Réseau ---

resource "openstack_networking_network_v2" "db" {
  name = "todo-db-net"
}

resource "openstack_networking_subnet_v2" "db" {
  name            = "todo-db-subnet"
  network_id      = openstack_networking_network_v2.db.id
  cidr            = "192.168.100.0/24"
  ip_version      = 4
  dns_nameservers = ["8.8.8.8"]
}

resource "openstack_networking_router_v2" "db" {
  name                = "todo-db-router"
  external_network_id = data.openstack_networking_network_v2.external.id
}

resource "openstack_networking_router_interface_v2" "db" {
  router_id = openstack_networking_router_v2.db.id
  subnet_id = openstack_networking_subnet_v2.db.id
}

data "openstack_networking_network_v2" "external" {
  name = var.external_network
}

# --- Security group ---

resource "openstack_networking_secgroup_v2" "db" {
  name = "todo-db-sg"
}

resource "openstack_networking_secgroup_rule_v2" "postgres" {
  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = "tcp"
  port_range_min    = 5432
  port_range_max    = 5432
  remote_ip_prefix  = "0.0.0.0/0"
  security_group_id = openstack_networking_secgroup_v2.db.id
}

resource "openstack_networking_secgroup_rule_v2" "patroni_api" {
  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = "tcp"
  port_range_min    = 8008
  port_range_max    = 8008
  remote_ip_prefix  = "0.0.0.0/0"
  security_group_id = openstack_networking_secgroup_v2.db.id
}

resource "openstack_networking_secgroup_rule_v2" "etcd" {
  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = "tcp"
  port_range_min    = 2379
  port_range_max    = 2380
  remote_ip_prefix  = "0.0.0.0/0"
  security_group_id = openstack_networking_secgroup_v2.db.id
}

resource "openstack_networking_secgroup_rule_v2" "ssh" {
  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = "tcp"
  port_range_min    = 22
  port_range_max    = 22
  remote_ip_prefix  = "0.0.0.0/0"
  security_group_id = openstack_networking_secgroup_v2.db.id
}

# --- Ports (IPs fixes) ---

resource "openstack_networking_port_v2" "master" {
  name               = "todo-db-master-port"
  network_id         = openstack_networking_network_v2.db.id
  security_group_ids = [openstack_networking_secgroup_v2.db.id]

  fixed_ip {
    subnet_id  = openstack_networking_subnet_v2.db.id
    ip_address = "192.168.100.10"
  }
}

resource "openstack_networking_port_v2" "replica" {
  name               = "todo-db-replica-port"
  network_id         = openstack_networking_network_v2.db.id
  security_group_ids = [openstack_networking_secgroup_v2.db.id]

  fixed_ip {
    subnet_id  = openstack_networking_subnet_v2.db.id
    ip_address = "192.168.100.11"
  }
}

# --- Instances ---

data "openstack_images_image_v2" "ubuntu" {
  name        = var.image_name
  most_recent = true
}

data "openstack_compute_flavor_v2" "db" {
  name = var.flavor_name
}

resource "openstack_compute_instance_v2" "db_master" {
  name      = "todo-db-master"
  image_id  = data.openstack_images_image_v2.ubuntu.id
  flavor_id = data.openstack_compute_flavor_v2.db.id
  key_pair  = var.keypair_name

  network {
    port = openstack_networking_port_v2.master.id
  }

  user_data = templatefile("${path.module}/../cloud-init/db-master.sh.tpl", {
    master_ip            = "192.168.100.10"
    db_user              = var.db_user
    db_password          = var.db_password
    db_name              = "todos"
    replication_password = var.replication_password
  })
}

resource "openstack_compute_instance_v2" "db_replica" {
  name      = "todo-db-replica"
  image_id  = data.openstack_images_image_v2.ubuntu.id
  flavor_id = data.openstack_compute_flavor_v2.db.id
  key_pair  = var.keypair_name

  network {
    port = openstack_networking_port_v2.replica.id
  }

  user_data = templatefile("${path.module}/../cloud-init/db-replica.sh.tpl", {
    master_ip            = "192.168.100.10"
    replica_ip           = "192.168.100.11"
    db_password          = var.db_password
    replication_password = var.replication_password
  })

  depends_on = [openstack_compute_instance_v2.db_master]
}

# --- Outputs ---

output "db_master_ip" {
  value = "192.168.100.10"
}

output "db_replica_ip" {
  value = "192.168.100.11"
}
