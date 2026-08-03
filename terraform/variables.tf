variable "tenancy_ocid" {
  description = "OCID of the OCI tenancy"
  type        = string
  default     = "ocid1.tenancy.oc1..aaaaaaaa3t6wd5cb4rcwtko3xeovprpnvf4iixks5ytomyftvulepxxnyt5q"
}

variable "compartment_ocid" {
  description = "OCID of the main compartment that holds most homelab resources"
  type        = string
  default     = "ocid1.compartment.oc1..aaaaaaaays62ka24mqjmg7ej5khoswujbqjhwwlvalkjbfm7lz5pkmqugwba"
}

variable "region" {
  description = "OCI region"
  type        = string
  default     = "ap-sydney-1"
}

# Deliberately has no default. This is a residential, dynamic address and it is
# not committed — it lives in terraform/terraform.tfvars (gitignored) locally and
# in the ORM stack variables for applies run there. Without a default, a missing
# value fails the plan instead of silently rewriting the SSH and kubectl ingress
# rules to something wrong.
variable "home_ip_cidr" {
  description = "Home public IP in CIDR form, e.g. 203.0.113.4/32. Sourced from terraform.tfvars or the ORM stack variable of the same name."
  type        = string

  validation {
    condition     = can(cidrhost(var.home_ip_cidr, 0))
    error_message = "home_ip_cidr must be valid CIDR notation, e.g. 203.0.113.4/32."
  }
}
