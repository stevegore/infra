# IAM grants needed by the OKE service to manage cluster resources on our
# behalf — VCN attachments, worker compute instances, block volumes (for
# PVCs / oci-bv StorageClass), and load balancers (the CCM creates the NLB
# from a Service annotation).
#
# Worker instance principals are already covered by the existing
# vault-instances dynamic group (broadened to compartment-match in the
# same commit that created caddy-acme).

resource "oci_identity_policy" "oke_service" {
  compartment_id = oci_identity_compartment.export_main.id
  name           = "oke-service-policy"
  description    = "Allow the OKE service to manage cluster-managed resources in main."

  statements = [
    "Allow service OKE to manage virtual-network-family in compartment main",
    "Allow service OKE to manage instance-family in compartment main",
    "Allow service OKE to manage load-balancers in compartment main",
    "Allow service OKE to manage volume-family in compartment main",
    "Allow service OKE to manage cluster-node-pools in compartment main",
    # fss.csi.oraclecloud.com runs the dynamic provisioner on the OKE
    # control plane. The legacy `service OKE` grant below is kept for
    # belt-and-suspenders, but the modern OKE-bundled FSS CSI driver
    # authenticates as the cluster instance principal (workload-identity
    # style), so it needs an `any-user where request.principal.type='cluster'`
    # statement. Without the cluster-principal grant, PVCs against the
    # oci-fss StorageClass stall with FileStorage 404 NotAuthorizedOrNotFound
    # on GetMountTarget — verified on the first FSS smoke test.
    "Allow service OKE to manage file-family in compartment main",
    "Allow any-user to manage file-family in compartment main where ALL {request.principal.type='cluster', request.principal.compartment.id='${var.compartment_ocid}'}",
  ]
}

# MySQL service needs all of these to provision a DB system:
#   - virtual-network-family: VNICs for the DB endpoint
#   - instance-family read: shape validation
#   - object-family manage: automatic backups to Oracle-managed storage
#   - KMS access: encryption-at-rest key handling (even with Oracle-managed keys)
#   - work-requests inspect: track its own provisioning state
# Without the full set, creation fails with the unhelpful "AuthorizationFailed"
# (TF surfaces it as "expected ACTIVE, got FAILED" with no further detail).
# See https://docs.oracle.com/en-us/iaas/mysql-database/doc/iam-policies.html
resource "oci_identity_policy" "mysql_service" {
  compartment_id = oci_identity_compartment.export_main.id
  name           = "mysql-service-policy"
  description    = "Allow the MySQL service to provision and manage DB systems in main."

  statements = [
    # `manage` (not `use`) because the service must attach VNICs to the
    # NSG we provide via nsg_ids — that requires manage-level on
    # network-security-groups, which falls under virtual-network-family.
    # With only `use`, CreateDbSystem fails with the unhelpful
    # AuthorizationFailed even though the basic VNIC create itself works.
    "Allow service mysql to manage virtual-network-family in compartment main",
    "Allow service mysql to read instance-family in compartment main",
    "Allow service mysql to manage object-family in compartment main",
    "Allow service mysql to {KEY_READ, KEY_VERSION_READ, KMS_CONFIG_READ, KMS_KEY_USE} in compartment main",
    "Allow service mysql to inspect work-requests in compartment main",
  ]
}
