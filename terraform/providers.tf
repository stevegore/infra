# OCI provider — authentication source order:
#   - Local CLI runs: reads ~/.oci/config DEFAULT profile (API key auth)
#   - ORM jobs: ORM injects instance-principal / resource-principal creds
#
# No explicit auth block: the provider's default precedence handles both cases.
provider "oci" {
  region = var.region
}
