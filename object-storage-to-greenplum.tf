# Infrastructure for the Yandex Cloud Object StorageL, Managed Service for Greenplum®, and Data Transfer
#
# RU: https://cloud.yandex.ru/docs/data-transfer/tutorials/object-storage-to-greenplum
# EN: https://cloud.yandex.com/en/docs/data-transfer/tutorials/object-storage-to-greenplum
#
# Specify the following settings:
locals {

  folder_id   = "" # Set your cloud folder ID, same as for provider
  bucket_name = "" # Set a unique bucket name

  # Settings for the Managed Service for Greenplum® cluster:
  gp_version  = "" # Set the Greenplum® version. For available versions, see the documentation main page: https://cloud.yandex.com/en/docs/managed-greenplum/.
  gp_password = "" # Set a password for the Greenplum® admin user

  # You should set up endpoints using the GUI to obtain their IDs
  source_endpoint_id = "" # Set the source endpoint ID
  target_endpoint_id = "" # Set the target endpoint ID
  transfer_enabled   = 0  # Set to 1 to enable the transfer

  # The following settings are predefined. Change them only if necessary.
  network_name          = "mgp-network"        # Name of the network
  subnet_name           = "mgp-subnet-a"       # Name of the subnet
  zone_a_v4_cidr_blocks = "10.1.0.0/16"        # CIDR block for the subnet
  sa-name               = "storage-editor"     # Name of the service account
  security_group_name   = "mgp-security-group" # Name of the security group
  mgp_cluster_name      = "mgp-cluster"        # Name of the Greenplum® cluster
  gp_username           = "user1"              # Name of the Greenplum® admin user
  target_endpoint_name  = "mgp-target"         # Name of the target endpoint for the Greenplum® cluster
  transfer_name         = "s3-mgp-transfer"    # Name of the transfer from the Object Storage bucket to the Managed Service for Greenplum® cluster
}

# Network infrastructure for the Managed Service for Greenplum® cluster

resource "yandex_vpc_network" "network" {
  description = "Network for the Managed Service for Greenplum® cluster"
  name        = local.network_name
}

resource "yandex_vpc_subnet" "subnet-a" {
  description    = "Subnet in the ru-central1-a availability zone"
  name           = local.subnet_name
  zone           = "ru-central1-a"
  network_id     = yandex_vpc_network.network.id
  v4_cidr_blocks = [local.zone_a_v4_cidr_blocks]
}

resource "yandex_vpc_security_group" "security_group" {
  description = "Security group for the Managed Service for Greenplum® cluster"
  name        = local.security_group_name
  network_id  = yandex_vpc_network.network.id

  ingress {
    description    = "Allows all incoming traffic"
    protocol       = "ANY"
    from_port      = 0
    to_port        = 65535
    v4_cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description    = "Allows all outgoing traffic"
    protocol       = "ANY"
    from_port      = 0
    to_port        = 65535
    v4_cidr_blocks = ["0.0.0.0/0"]
  }
}

# Infrastructure for the Object Storage bucket

# Create a service account
resource "yandex_iam_service_account" "example-sa" {
  folder_id = local.folder_id
  name      = local.sa-name
}

# Create a static key for the service account
resource "yandex_iam_service_account_static_access_key" "sa-static-key" {
  service_account_id = yandex_iam_service_account.example-sa.id
}

# Grant a role to the service account. The role allows to perform any operations with buckets and objects.
resource "yandex_resourcemanager_folder_iam_binding" "s3-admin" {
  folder_id = local.folder_id
  role      = "storage.editor"

  members = [
    "serviceAccount:${yandex_iam_service_account.example-sa.id}",
  ]
}

# Create a Lockbox secret
resource "yandex_lockbox_secret" "sa_key_secret" {
  name        = "sa_key_secret"
  description = "Contains a static key pair to create an endpoint"
  folder_id   = local.folder_id
}

# Create a version of Lockbox secret with the static key pair
resource "yandex_lockbox_secret_version" "first_version" {
  secret_id = yandex_lockbox_secret.sa_key_secret.id
  entries {
    key        = "access_key"
    text_value = yandex_iam_service_account_static_access_key.sa-static-key.access_key
  }
  entries {
    key        = "secret_key"
    text_value = yandex_iam_service_account_static_access_key.sa-static-key.secret_key
  }
}

# Create the Yandex Object Storage bucket
resource "yandex_storage_bucket" "example-bucket" {
  bucket     = local.bucket_name
  access_key = yandex_iam_service_account_static_access_key.sa-static-key.access_key
  secret_key = yandex_iam_service_account_static_access_key.sa-static-key.secret_key
}

# Infrastructure for the Managed Service for Greenplum® cluster

resource "yandex_mdb_greenplum_cluster" "mgp-cluster" {
  description        = "Managed Service for Greenplum® cluster"
  name               = local.mgp_cluster_name
  environment        = "PRODUCTION"
  version            = local.gp_version
  network_id         = yandex_vpc_network.network.id
  zone               = "ru-central1-a"
  subnet_id          = yandex_vpc_subnet.subnet-a.id
  assign_public_ip   = true
  master_host_count  = 2
  segment_host_count = 2
  segment_in_host    = 1
  master_subcluster {
    resources {
      resource_preset_id = "s2.medium" # 8 vCPU, 32 GB RAM
      disk_size          = 100         # GB
      disk_type_id       = "local-ssd"
    }
  }
  segment_subcluster {
    resources {
      resource_preset_id = "s2.medium" # 8 vCPU, 32 GB RAM
      disk_size          = 100         # GB
      disk_type_id       = "local-ssd"
    }
  }

  user_name     = local.gp_username
  user_password = local.gp_password

  security_group_ids = [yandex_vpc_security_group.security_group.id]
}

# Data Transfer infrastructure

resource "yandex_datatransfer_transfer" "objstorage-gp-transfer" {
  count       = local.transfer_enabled
  description = "Transfer from the Object Storage bucket to the Managed Service for Greenplum®"
  name        = "transfer-from-objstorage-to-greenplum"
  source_id   = local.source_endpoint_id
  target_id   = local.target_endpoint_id
  type        = "SNAPSHOT_AND_INCREMENT" # Copy all data from the source cluster and start replication
}