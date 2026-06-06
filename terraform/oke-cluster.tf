# OKE Basic cluster + ARM node pool.
#
# Always-Free constraints: BASIC_CLUSTER has no control-plane fee; A1.Flex
# burns from the 4 OCPU / 24 GB always-free pool. Two nodes at 2 OCPU each =
# 4 OCPU — exactly the free tier.

variable "oke_kubernetes_version" {
  description = "OKE control-plane version. Bump deliberately; node pool image OCID below must match."
  type        = string
  default     = "v1.35.2"
}

variable "oke_node_image_ocid" {
  description = "OKE-prebuilt ARM image OCID matching var.oke_kubernetes_version. Currently: Oracle-Linux-8.10-aarch64-2026.04.30-3-OKE-1.35.2-1462. Re-query via: oci ce node-pool-options get --node-pool-option-id all --query 'data.sources[?contains(\"source-name\", `OKE-1.35.2`)]'"
  type        = string
  default     = "ocid1.image.oc1.ap-sydney-1.aaaaaaaamfls6ukb66gz775gtxjokdguhhxzgxxpbjuh3vlrkdmdglfb2z5q"
}

resource "oci_containerengine_cluster" "homelab" {
  compartment_id     = var.compartment_ocid
  vcn_id             = oci_core_vcn.export_nebula.id
  kubernetes_version = var.oke_kubernetes_version
  name               = "homelab"
  type               = "BASIC_CLUSTER"

  endpoint_config {
    subnet_id            = oci_core_subnet.oke_api_endpoint.id
    is_public_ip_enabled = true
    nsg_ids              = [oci_core_network_security_group.oke_api.id]
  }

  options {
    # NLB / LB Services land in the public subnet (CCM picks from this list).
    service_lb_subnet_ids = [oci_core_subnet.export_Public-Subnet-nebula.id]

    kubernetes_network_config {
      pods_cidr     = "10.244.0.0/16" # k8s defaults; far from VCN 10.0.0.0/16 and Tailscale 100.64.0.0/10
      services_cidr = "10.96.0.0/16"
    }

    add_ons {
      is_kubernetes_dashboard_enabled = false
      is_tiller_enabled               = false
    }

    admission_controller_options {
      is_pod_security_policy_enabled = false # PSP removed in k8s 1.25
    }
  }

  # Workers use the host VCN's CNI (flannel overlay) — only meaningful
  # alternative is OCI_VCN_IP_NATIVE which consumes more VCN IPs per pod
  # (problematic for the /16 VCN).
  cluster_pod_network_options {
    cni_type = "FLANNEL_OVERLAY"
  }
}

resource "oci_containerengine_node_pool" "homelab_arm" {
  cluster_id         = oci_containerengine_cluster.homelab.id
  compartment_id     = var.compartment_ocid
  kubernetes_version = var.oke_kubernetes_version
  name               = "homelab-arm"
  node_shape         = "VM.Standard.A1.Flex"

  node_shape_config {
    memory_in_gbs = 12
    ocpus         = 2
  }

  node_source_details {
    source_type             = "IMAGE"
    image_id                = var.oke_node_image_ocid
    boot_volume_size_in_gbs = 50
  }

  node_config_details {
    size = 2

    placement_configs {
      availability_domain = "tbGS:AP-SYDNEY-1-AD-1"
      subnet_id           = oci_core_subnet.export_Private-Subnet-nebula.id
      fault_domains       = ["FAULT-DOMAIN-1", "FAULT-DOMAIN-2"]
    }

    nsg_ids = [oci_core_network_security_group.oke_workers.id]

    node_pool_pod_network_option_details {
      cni_type = "FLANNEL_OVERLAY"
    }
  }

  # Match the cluster's CNI choice.
  initial_node_labels {
    key   = "node.kubernetes.io/lifecycle"
    value = "homelab-always-free"
  }
}

output "oke_cluster_id" {
  value       = oci_containerengine_cluster.homelab.id
  description = "Use with: oci ce cluster create-kubeconfig --cluster-id <id> --file ~/.kube/oke.config --region ap-sydney-1"
}

output "oke_cluster_endpoint" {
  value       = oci_containerengine_cluster.homelab.endpoints[0].kubernetes
  description = "Public OKE API endpoint URL"
}
