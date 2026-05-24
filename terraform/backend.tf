# Remote state backend — OCI Object Storage via the S3-compat endpoint.
#
# Both local CLI (`terraform plan` for fast iteration) and OCI Resource Manager
# point at the same bucket + key, so plans see identical state. Apply only via
# ORM jobs — that's the convention, not a technical lock. Bucket versioning is
# enabled, so a bad state push can always be rolled back.
#
# Credentials: AWS_ACCESS_KEY_ID + AWS_SECRET_ACCESS_KEY env vars. Sourced
# from Vault by `scripts/tf-env.sh` for local use; injected by ORM in jobs.
terraform {
  backend "s3" {
    bucket = "infra-tfstate"
    key    = "homelab/main.tfstate"
    region = "ap-sydney-1"

    # OCI S3-compatibility endpoint. Namespace `sdajdczqv0qo` is the tenancy's
    # Object Storage namespace (oci os ns get).
    endpoint = "https://sdajdczqv0qo.compat.objectstorage.ap-sydney-1.oraclecloud.com"

    # OCI's S3 surface doesn't speak STS / IMDS / region validation the way
    # AWS does, so disable the AWS-only preflight checks.
    skip_region_validation      = true
    skip_credentials_validation = true
    skip_metadata_api_check     = true
    force_path_style            = true
  }
}
