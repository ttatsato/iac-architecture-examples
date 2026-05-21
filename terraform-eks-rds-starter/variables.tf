variable "region" {
  type    = string
  default = "ap-northeast-1"
}

variable "project" {
  type    = string
  default = "tf-eks-rdf-starter"
}

variable "env" {
  type    = string
  default = "dev"
  validation {
    condition     = contains(["dev", "stg", "prod"], var.env)
    error_message = "env must be one of: dev, stg, prod."
  }
}

variable "vpc_cidr" {
  type        = string
  description = "CIDR block for the VPC (e.g. 10.20.0.0/16)"

  validation {
    condition     = can(cidrnetmask(var.vpc_cidr))
    error_message = "vpc_cidr must be a valid IPv4 CIDR (e.g. 10.20.0.0/16)."
  }
}
