variable "tenancy_ocid" {
  description = "OCID of the OCI tenancy"
  type        = string
}

variable "compartment_ocid" {
  description = "OCID of the main compartment that holds most homelab resources"
  type        = string
}

variable "region" {
  description = "OCI region"
  type        = string
  default     = "ap-sydney-1"
}
