# MySQL HeatWave Free — single-instance managed MySQL for Vaultwarden.
#
# Free-tier constraints: shape MySQL.Free is the only allowed shape, 50 GB
# data, single instance (no HA), one automatic backup. Free tier limits one
# instance per tenancy.
#
# Workers reach this DB at <hostname_label>.<private-subnet-dns-label>.<vcn-dns-label>.oraclevcn.com:3306
# — i.e. `heatwave.sub02040931039.nebula.oraclevcn.com:3306` resolved from
# inside the VCN. Vaultwarden picks this up via DATABASE_URL stashed in Vault.

variable "mysql_admin_username" {
  description = "Admin user for the MySQL HeatWave Free DB system."
  type        = string
  default     = "admin"
}

# Random password lives in TF state (sensitive but readable to anyone with
# state access). Push to Vault post-apply via `scripts/publish-mysql-creds.sh`.
resource "random_password" "mysql_admin" {
  length           = 32
  special          = true
  override_special = "!@#$%^&*()-_=+[]{}<>?"
}

# ---- Dedicated NSG for the DB ------------------------------------------
resource "oci_core_network_security_group" "mysql" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.export_nebula.id
  display_name   = "mysql-heatwave"
}

resource "oci_core_network_security_group_security_rule" "mysql_from_workers_3306" {
  network_security_group_id = oci_core_network_security_group.mysql.id
  direction                 = "INGRESS"
  protocol                  = "6"
  source                    = oci_core_network_security_group.oke_workers.id
  source_type               = "NETWORK_SECURITY_GROUP"
  description               = "Classic MySQL protocol from OKE workers"
  tcp_options {
    destination_port_range {
      min = 3306
      max = 3306
    }
  }
}

resource "oci_core_network_security_group_security_rule" "mysql_from_workers_33060" {
  network_security_group_id = oci_core_network_security_group.mysql.id
  direction                 = "INGRESS"
  protocol                  = "6"
  source                    = oci_core_network_security_group.oke_workers.id
  source_type               = "NETWORK_SECURITY_GROUP"
  description               = "MySQL X Protocol from OKE workers (used by some clients)"
  tcp_options {
    destination_port_range {
      min = 33060
      max = 33060
    }
  }
}

resource "oci_core_network_security_group_security_rule" "mysql_egress" {
  network_security_group_id = oci_core_network_security_group.mysql.id
  direction                 = "EGRESS"
  protocol                  = "all"
  destination               = "0.0.0.0/0"
  destination_type          = "CIDR_BLOCK"
  description               = "DNS, NTP, OCI backup endpoints (via service GW)"
}

# ---- DB system ----------------------------------------------------------
resource "oci_mysql_mysql_db_system" "heatwave" {
  compartment_id      = var.compartment_ocid
  availability_domain = "tbGS:AP-SYDNEY-1-AD-1"
  subnet_id           = oci_core_subnet.export_Private-Subnet-nebula.id
  shape_name          = "MySQL.Free"
  display_name        = "heatwave"
  hostname_label      = "heatwave"

  admin_username = var.mysql_admin_username
  admin_password = random_password.mysql_admin.result

  # 50 GB is the free-tier cap; OCI rejects values above on this shape.
  data_storage_size_in_gb = 50
  is_highly_available     = false

  # nsg_ids INTENTIONALLY OMITTED: attaching any NSG at create time triggers
  # an undocumented "AuthorizationFailed" failure from the MySQL service even
  # with the OCI-documented `manage virtual-network-family` grant. Access
  # control is handled via security list rules on Private Subnet-nebula
  # (3306 + 33060 from 10.0.1.0/24) which is functionally equivalent because
  # the subnet only holds OKE workers + this DB. The standalone mysql-heatwave
  # NSG resource is kept for now in case OCI fixes this (or we want to attach
  # via update post-create); remove if it's still gathering dust at next pass.

  # backup_policy intentionally omitted — OCI rejects it at create time
  # for MySQL.Free DB systems ("Cannot specify backup policy with
  # 'CreateDbSystem' operation for an Always Free DB system"). Free tier
  # gets one automatic daily backup, retention not user-configurable.

  # Explicit dependency on the service policy: without this, TF can call
  # CreateDbSystem in parallel with the policy create/update and the auth
  # check on MySQL's side hits the old (insufficient) grants. Mentioning
  # the policy resource in depends_on forces a happens-before ordering.
  depends_on = [oci_identity_policy.mysql_service]

  # Don't taint on minor MySQL version bumps from OCI; the service does
  # rolling minor upgrades inside the major version we picked.
  lifecycle {
    ignore_changes = [mysql_version]
  }
}

output "mysql_endpoint_hostname" {
  value       = oci_mysql_mysql_db_system.heatwave.endpoints[0].hostname
  description = "DNS name for connecting from inside the VCN (OKE workers)"
}

output "mysql_endpoint_ip" {
  value       = oci_mysql_mysql_db_system.heatwave.endpoints[0].ip_address
  description = "Private IP for the DB endpoint"
}

output "mysql_admin_username" {
  value = var.mysql_admin_username
}

output "mysql_admin_password" {
  value     = random_password.mysql_admin.result
  sensitive = true
  description = "Pull via: terraform output -raw mysql_admin_password (state must be activated locally first)"
}
