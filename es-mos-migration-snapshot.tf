# Infrastructure for the Yandex Cloud Object Storage and Managed Service for OpenSearch
#
# RU: https://cloud.yandex.ru/docs/managed-opensearch/tutorials/migration-to-opensearch
# EN: https://cloud.yandex.com/en/docs/managed-opensearch/tutorials/migration-to-opensearch

# Specify the following settings:
locals {

  folder_id   = "" # Set your cloud folder ID, same as for provider
  bucket_name = "" # Set a unique bucket name

  # Settings for the Managed Service for OpenSearch cluster:
  os_version       = "" # Set a desired version of OpenSearch. For available versions, see the documentation main page: https://cloud.yandex.com/en/docs/managed-opensearch/
  os_admin_password = "" # Set a password for the OpenSearch administrator

  # The following settings are predefined. Change them only if necessary.
  sa-name               = "s3-account"         # Name of the service account
  network_name          = "mos-network"        # Name of the network
  subnet_name           = "mos-subnet-a"       # Name of the subnet
  zone_a_v4_cidr_blocks = "10.1.0.0/16"        # CIDR block for subnet in the ru-central1-a availability zone
  security_group_name   = "mos-security-group" # Name of the security group
  os_cluster_name       = "opensearch-cluster" # Name of the OpenSearch cluster
}

# Network infrastructure for the Managed Service for OpenSearch cluster

resource "yandex_vpc_network" "network" {
  description = "Network for the Managed Service for OpenSearch cluster"
  name        = local.network_name
}

resource "yandex_vpc_subnet" "subnet-a" {
  description    = "Subnet in the ru-central1-a availability zone"
  name           = local.subnet_name
  zone           = "ru-central1-a"
  network_id     = yandex_vpc_network.network.id
  v4_cidr_blocks = [local.zone_a_v4_cidr_blocks]
}

resource "yandex_vpc_security_group" "security-group" {
  description = "Security group for the Managed Service for OpenSearch cluster"
  name        = local.security_group_name
  network_id  = yandex_vpc_network.network.id

  ingress {
    description    = "The rule allows connections to the Managed Service for OpenSearch cluster from the Internet"
    protocol       = "TCP"
    port           = 443
    v4_cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description    = "The rule allows connections to the Managed Service for OpenSearch cluster from the Internet with Dashboards"
    protocol       = "TCP"
    port           = 9200
    v4_cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description    = "The rule allows all outgoing traffic"
    protocol       = "ANY"
    v4_cidr_blocks = ["0.0.0.0/0"]
    from_port      = 0
    to_port        = 65535
  }
}

# Infrastructure for the Object Storage bucket

# Create a service account
resource "yandex_iam_service_account" "example-sa" {
  folder_id = local.folder_id
  name      = local.sa-name
}

# Grant a role to the service account. The role allows to perform any operations with buckets and objects.
resource "yandex_resourcemanager_folder_iam_binding" "s3-admin" {
  folder_id = local.folder_id
  role      = "storage.editor"

  members = [
    "serviceAccount:${yandex_iam_service_account.example-sa.id}",
  ]
}

# Create a static key for the service account
resource "yandex_iam_service_account_static_access_key" "sa-static-key" {
  service_account_id = yandex_iam_service_account.example-sa.id
}

# Create a Lockbox secret
resource "yandex_lockbox_secret" "sa-key-secret" {
  name        = "sa-key-secret"
  description = "Contains a static key pair to create an endpoint"
  folder_id   = local.folder_id
}

# Create a version of Lockbox secret with the static key pair
resource "yandex_lockbox_secret_version" "first_version" {
  secret_id = yandex_lockbox_secret.sa-key-secret.id
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

# Infrastructure for the Managed Service for OpenSearch cluster

resource "yandex_mdb_opensearch_cluster" "mos-cluster" {
  description        = "Managed Service for OpenSearch cluster"
  name               = local.os_cluster_name
  environment        = "PRODUCTION"
  network_id         = yandex_vpc_network.network.id
  security_group_ids = [yandex_vpc_security_group.security-group.id]

  config {

    version        = local.os_version
    admin_password = local.os_admin_password

    opensearch {
      node_groups {
        name             = "opensearch-group"
        assign_public_ip = true
        hosts_count      = 1
        zone_ids         = ["ru-central1-a"]
        roles            = ["DATA", "MANAGER"]
        resources {
          resource_preset_id = "s2.micro"  # 2 vCPU, 8 GB RAM
          disk_size          = 10737418240 # Bytes
          disk_type_id       = "network-ssd"
        }
      }

      plugins = ["repository-s3"]
    }

    dashboards {
      node_groups {
        name             = "dashboards-group"
        assign_public_ip = true
        hosts_count      = 1
        zone_ids         = ["ru-central1-a"]
        resources {
          resource_preset_id = "s2.micro"  # 2 vCPU, 8 GB RAM
          disk_size          = 10737418240 # Bytes
          disk_type_id       = "network-ssd"
        }
      }
    }

  }

  depends_on = [
    yandex_vpc_subnet.subnet-a
  ]
}