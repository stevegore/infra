# Network Load Balancer plumbing — RESERVED public IP for the OKE-side
# Caddy NLB.
#
# Why a fresh reserved IP (not the ampere one)? Per
# architecture-proposal.md §3 the IP currently on ampere's VNIC
# (publicip20230914115348) is EPHEMERAL — OCI does not support
# in-place ephemeral-to-reserved promotion, and an ephemeral IP on a
# VNIC can't be detached and re-attached to an NLB. So we provision a
# brand-new RESERVED public IP here. The CCM picks it up via the
# `service.beta.kubernetes.io/oci-load-balancer-reserved-ip`
# annotation on the Caddy Service (apps/caddy/values.yaml).
#
# Cutover: drop Cloudflare TTL to 60s 24h ahead, then update the A
# records (`stevegore.au` + wildcard) to this address. External clients
# never see the IP change because Cloudflare proxy is on.
resource "oci_core_public_ip" "caddy_nlb" {
  compartment_id = var.compartment_ocid
  display_name   = "caddy-nlb-reserved"
  # RESERVED = persists independently of any VNIC/LB attachment, so the
  # IP survives NLB recreation. lifetime = "EPHEMERAL" would tie it to a
  # single VNIC and disappear on detach.
  lifetime = "RESERVED"

  # The NLB controller binds this reserved IP to the LB's private endpoint
  # at runtime. private_ip_id is owned by the CCM; let it manage that field.
  lifecycle {
    ignore_changes = [private_ip_id]
  }
}

output "caddy_nlb_reserved_ip_ocid" {
  value       = oci_core_public_ip.caddy_nlb.id
  description = "Use this as the value of the service.beta.kubernetes.io/oci-load-balancer-reserved-ip annotation in apps-oke/caddy/values.yaml."
}

output "caddy_nlb_reserved_ip_address" {
  value       = oci_core_public_ip.caddy_nlb.ip_address
  description = "Point Cloudflare DNS at this address (after dropping TTL)."
}
