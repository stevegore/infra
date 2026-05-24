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
  ]
}

# MySQL service needs permission to create VNICs in our subnet for the
# DB system endpoint. Without this, DB creation fails immediately with
# "AuthorizationFailed" (which surfaces in TF as the vague "expected ACTIVE,
# got FAILED"). See https://docs.oracle.com/en-us/iaas/mysql-database/doc/iam-policies.html
resource "oci_identity_policy" "mysql_service" {
  compartment_id = oci_identity_compartment.export_main.id
  name           = "mysql-service-policy"
  description    = "Allow the MySQL service to provision DB system VNICs in main."

  statements = [
    "Allow service MySQL to use virtual-network-family in compartment main",
  ]
}
