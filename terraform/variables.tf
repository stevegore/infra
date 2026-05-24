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
