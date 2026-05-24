# OKE network plumbing — endpoint subnet + NSGs for the control plane and
# workers. The worker subnet itself is the existing Private Subnet-nebula
# (in core.tf), which already has 0.0.0.0/0 → NAT + service-CIDR → service
# gateway routes; nothing to add there.

# ---- API endpoint subnet ------------------------------------------------
# Tiny /28 — only the kube-apiserver VNIC lives here. Public-routable so
# kubectl from pico/Mac can reach the apiserver; NSG below restricts access
# to the home IP plus the worker NSG.
resource "oci_core_subnet" "oke_api_endpoint" {
  compartment_id      = var.compartment_ocid
  vcn_id              = oci_core_vcn.export_nebula.id
  cidr_block          = "10.0.2.0/28"
  display_name        = "oke-api-endpoint"
  dns_label           = "okeapi"
  route_table_id      = oci_core_default_route_table.export_Default-Route-Table-for-nebula.id
  security_list_ids   = [oci_core_vcn.export_nebula.default_security_list_id]
  dhcp_options_id     = oci_core_default_dhcp_options.export_Default-DHCP-Options-for-nebula.id
  prohibit_internet_ingress    = false
  prohibit_public_ip_on_vnic   = false
}

# ---- API endpoint NSG ---------------------------------------------------
resource "oci_core_network_security_group" "oke_api" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.export_nebula.id
  display_name   = "oke-api-endpoint"
}

# Kubectl from home — TCP 6443 (apiserver) from home IP.
resource "oci_core_network_security_group_security_rule" "oke_api_kubectl_home" {
  network_security_group_id = oci_core_network_security_group.oke_api.id
  direction                 = "INGRESS"
  protocol                  = "6"
  source                    = "159.196.97.38/32"
  source_type               = "CIDR_BLOCK"
  description               = "kubectl from home (matches existing SSH allow rule)"
  tcp_options {
    destination_port_range {
      min = 6443
      max = 6443
    }
  }
}

# Workers → apiserver on 6443
resource "oci_core_network_security_group_security_rule" "oke_api_from_workers_6443" {
  network_security_group_id = oci_core_network_security_group.oke_api.id
  direction                 = "INGRESS"
  protocol                  = "6"
  source                    = oci_core_network_security_group.oke_workers.id
  source_type               = "NETWORK_SECURITY_GROUP"
  description               = "Worker kubelet/proxy traffic to apiserver"
  tcp_options {
    destination_port_range {
      min = 6443
      max = 6443
    }
  }
}

# Workers → control-plane on 12250 (OKE-specific control channel)
resource "oci_core_network_security_group_security_rule" "oke_api_from_workers_12250" {
  network_security_group_id = oci_core_network_security_group.oke_api.id
  direction                 = "INGRESS"
  protocol                  = "6"
  source                    = oci_core_network_security_group.oke_workers.id
  source_type               = "NETWORK_SECURITY_GROUP"
  description               = "OKE control channel from workers"
  tcp_options {
    destination_port_range {
      min = 12250
      max = 12250
    }
  }
}

# Path MTU discovery
resource "oci_core_network_security_group_security_rule" "oke_api_pmtu" {
  network_security_group_id = oci_core_network_security_group.oke_api.id
  direction                 = "INGRESS"
  protocol                  = "1" # ICMP
  source                    = "10.0.0.0/16"
  source_type               = "CIDR_BLOCK"
  description               = "Path MTU discovery from VCN"
  icmp_options {
    type = 3
    code = 4
  }
}

# Apiserver → workers (kubelet)
resource "oci_core_network_security_group_security_rule" "oke_api_to_workers_kubelet" {
  network_security_group_id = oci_core_network_security_group.oke_api.id
  direction                 = "EGRESS"
  protocol                  = "6"
  destination               = oci_core_network_security_group.oke_workers.id
  destination_type          = "NETWORK_SECURITY_GROUP"
  description               = "Apiserver → kubelet on workers"
  tcp_options {
    destination_port_range {
      min = 10250
      max = 10250
    }
  }
}

# Apiserver → workers — everything else (broad TCP)
resource "oci_core_network_security_group_security_rule" "oke_api_to_workers_all_tcp" {
  network_security_group_id = oci_core_network_security_group.oke_api.id
  direction                 = "EGRESS"
  protocol                  = "6"
  destination               = oci_core_network_security_group.oke_workers.id
  destination_type          = "NETWORK_SECURITY_GROUP"
  description               = "Apiserver → workers, all TCP (webhooks, proxies, etc.)"
}

resource "oci_core_network_security_group_security_rule" "oke_api_to_workers_icmp" {
  network_security_group_id = oci_core_network_security_group.oke_api.id
  direction                 = "EGRESS"
  protocol                  = "1"
  destination               = oci_core_network_security_group.oke_workers.id
  destination_type          = "NETWORK_SECURITY_GROUP"
  description               = "Path MTU discovery to workers"
  icmp_options {
    type = 3
    code = 4
  }
}

# ---- Worker NSG ---------------------------------------------------------
resource "oci_core_network_security_group" "oke_workers" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.export_nebula.id
  display_name   = "oke-workers"
}

# Worker-to-worker TCP (k8s overlay, CNI, etc.)
resource "oci_core_network_security_group_security_rule" "oke_workers_self_tcp" {
  network_security_group_id = oci_core_network_security_group.oke_workers.id
  direction                 = "INGRESS"
  protocol                  = "6"
  source                    = oci_core_network_security_group.oke_workers.id
  source_type               = "NETWORK_SECURITY_GROUP"
  description               = "Worker-to-worker TCP"
}

# Worker-to-worker UDP (flannel VXLAN, kube-dns)
resource "oci_core_network_security_group_security_rule" "oke_workers_self_udp" {
  network_security_group_id = oci_core_network_security_group.oke_workers.id
  direction                 = "INGRESS"
  protocol                  = "17"
  source                    = oci_core_network_security_group.oke_workers.id
  source_type               = "NETWORK_SECURITY_GROUP"
  description               = "Worker-to-worker UDP (flannel VXLAN)"
}

resource "oci_core_network_security_group_security_rule" "oke_workers_self_icmp" {
  network_security_group_id = oci_core_network_security_group.oke_workers.id
  direction                 = "INGRESS"
  protocol                  = "1"
  source                    = oci_core_network_security_group.oke_workers.id
  source_type               = "NETWORK_SECURITY_GROUP"
  description               = "Worker-to-worker ICMP"
}

# Apiserver → workers (kubelet, etc.) — match the egress rule on api NSG
resource "oci_core_network_security_group_security_rule" "oke_workers_from_api_kubelet" {
  network_security_group_id = oci_core_network_security_group.oke_workers.id
  direction                 = "INGRESS"
  protocol                  = "6"
  source                    = oci_core_network_security_group.oke_api.id
  source_type               = "NETWORK_SECURITY_GROUP"
  description               = "Kubelet from apiserver"
  tcp_options {
    destination_port_range {
      min = 10250
      max = 10250
    }
  }
}

resource "oci_core_network_security_group_security_rule" "oke_workers_from_api_all_tcp" {
  network_security_group_id = oci_core_network_security_group.oke_workers.id
  direction                 = "INGRESS"
  protocol                  = "6"
  source                    = oci_core_network_security_group.oke_api.id
  source_type               = "NETWORK_SECURITY_GROUP"
  description               = "Apiserver → workers, all TCP"
}

resource "oci_core_network_security_group_security_rule" "oke_workers_from_api_icmp" {
  network_security_group_id = oci_core_network_security_group.oke_workers.id
  direction                 = "INGRESS"
  protocol                  = "1"
  source                    = oci_core_network_security_group.oke_api.id
  source_type               = "NETWORK_SECURITY_GROUP"
  description               = "Path MTU from apiserver"
  icmp_options {
    type = 3
    code = 4
  }
}

# NLB → workers on NodePort range. The CCM provisions the NLB in the public
# subnet (10.0.0.0/24); it backends to ephemeral NodePorts (30000-32767).
resource "oci_core_network_security_group_security_rule" "oke_workers_from_nlb_nodeport" {
  network_security_group_id = oci_core_network_security_group.oke_workers.id
  direction                 = "INGRESS"
  protocol                  = "6"
  source                    = "10.0.0.0/24"
  source_type               = "CIDR_BLOCK"
  description               = "NLB-to-worker NodePort range"
  tcp_options {
    destination_port_range {
      min = 30000
      max = 32767
    }
  }
}

# Health-check ICMP from VCN
resource "oci_core_network_security_group_security_rule" "oke_workers_pmtu_vcn" {
  network_security_group_id = oci_core_network_security_group.oke_workers.id
  direction                 = "INGRESS"
  protocol                  = "1"
  source                    = "10.0.0.0/16"
  source_type               = "CIDR_BLOCK"
  description               = "Path MTU discovery from VCN"
  icmp_options {
    type = 3
    code = 4
  }
}

# All egress — workers need to pull images (OCIR via service GW, internet
# via NAT for non-OCI images), reach KMS, Object Storage, control plane.
resource "oci_core_network_security_group_security_rule" "oke_workers_egress_all" {
  network_security_group_id = oci_core_network_security_group.oke_workers.id
  direction                 = "EGRESS"
  protocol                  = "all"
  destination               = "0.0.0.0/0"
  destination_type          = "CIDR_BLOCK"
  description               = "All outbound (NAT + service GW handle routing)"
}
