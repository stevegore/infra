# OCI File Storage (FSS) — Mount Target + NSG for the OKE cluster.
#
# Provides AD-durable RWX storage for OKE pods via the bundled
# fss.csi.oraclecloud.com CSI driver. The Mount Target lives in the worker
# Private subnet so workers reach it over the VCN; each PVC against the
# `oci-fss` StorageClass dynamically provisions its own File System sharing
# this Mount Target.
#
# Files System resources themselves are NOT declared here — they're created
# on-demand by the CSI driver. Worker instance principals (vault-instances
# dynamic group) carry the `manage file-family` grant added in identity.tf.

# ---- Mount Target NSG --------------------------------------------------
# Mount Targets are pure NFS responders; only ingress rules are needed.
# Worker NSG egress is already wide-open (0.0.0.0/0 in oke-networking.tf),
# so no worker-side rule change is required.
resource "oci_core_network_security_group" "fss_mount_target" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.export_nebula.id
  display_name   = "fss-mount-target"
}

# NFSv3 control + data ports from worker NSG.
#   111         rpcbind (portmapper)
#   2048-2050   nfsd / mountd / lockd / statd
resource "oci_core_network_security_group_security_rule" "fss_workers_tcp_111" {
  network_security_group_id = oci_core_network_security_group.fss_mount_target.id
  direction                 = "INGRESS"
  protocol                  = "6"
  source                    = oci_core_network_security_group.oke_workers.id
  source_type               = "NETWORK_SECURITY_GROUP"
  description               = "NFS rpcbind (TCP) from OKE workers"
  tcp_options {
    destination_port_range {
      min = 111
      max = 111
    }
  }
}

resource "oci_core_network_security_group_security_rule" "fss_workers_udp_111" {
  network_security_group_id = oci_core_network_security_group.fss_mount_target.id
  direction                 = "INGRESS"
  protocol                  = "17"
  source                    = oci_core_network_security_group.oke_workers.id
  source_type               = "NETWORK_SECURITY_GROUP"
  description               = "NFS rpcbind (UDP) from OKE workers"
  udp_options {
    destination_port_range {
      min = 111
      max = 111
    }
  }
}

resource "oci_core_network_security_group_security_rule" "fss_workers_tcp_2048_2050" {
  network_security_group_id = oci_core_network_security_group.fss_mount_target.id
  direction                 = "INGRESS"
  protocol                  = "6"
  source                    = oci_core_network_security_group.oke_workers.id
  source_type               = "NETWORK_SECURITY_GROUP"
  description               = "NFS nfsd/mountd/lockd (TCP) from OKE workers"
  tcp_options {
    destination_port_range {
      min = 2048
      max = 2050
    }
  }
}

resource "oci_core_network_security_group_security_rule" "fss_workers_udp_2048_2050" {
  network_security_group_id = oci_core_network_security_group.fss_mount_target.id
  direction                 = "INGRESS"
  protocol                  = "17"
  source                    = oci_core_network_security_group.oke_workers.id
  source_type               = "NETWORK_SECURITY_GROUP"
  description               = "NFS nfsd/mountd/lockd (UDP) from OKE workers"
  udp_options {
    destination_port_range {
      min = 2048
      max = 2050
    }
  }
}

# ---- Mount Target ------------------------------------------------------
# AD-scoped. Must match the OKE node pool AD (tbGS:AP-SYDNEY-1-AD-1, see
# oke-cluster.tf placement_configs) or workers can't mount over the VCN.
# Consumes one private IP in Private-Subnet-nebula (10.0.1.0/24).
resource "oci_file_storage_mount_target" "homelab" {
  availability_domain = "tbGS:AP-SYDNEY-1-AD-1"
  compartment_id      = var.compartment_ocid
  subnet_id           = oci_core_subnet.export_Private-Subnet-nebula.id
  display_name        = "homelab-fss"
  nsg_ids             = [oci_core_network_security_group.fss_mount_target.id]
}

output "fss_mount_target_ocid" {
  value       = oci_file_storage_mount_target.homelab.id
  description = "Plug into apps/oci-fss/values.yaml as mountTargetOcid for the StorageClass."
}

output "fss_mount_target_private_ip" {
  value       = oci_file_storage_mount_target.homelab.private_ip_ids
  description = "Private IP OCIDs of the Mount Target VNICs (resolve via `oci network private-ip get`)."
}
