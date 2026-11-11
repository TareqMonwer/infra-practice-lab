variable "aws_region" {
  type = string
  default = "us-east-1"
}
variable "environment" {
  type = string
  validation {
    condition = contains(["staging", "production"], var.environment)
    error_message = "environment must be staging or production"
  }
}
variable "instance_type" {
  type = string
  default = "t3.micro"
}
variable "allowed_cidrs" {
  type = list(string)
  description = "Restrict HTTP ingress to trusted CIDRs"
}
variable "image" {
  type = string
  description = "Immutable GHCR image tag"
}
