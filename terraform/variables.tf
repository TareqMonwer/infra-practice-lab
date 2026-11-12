variable "aws_region" {
  type    = string
  default = "us-east-1"
}
variable "environment" {
  type = string
  validation {
    condition     = contains(["staging", "production"], var.environment)
    error_message = "environment must be staging or production"
  }
}
variable "instance_type" {
  type    = string
  default = "t3.micro"
}
variable "web_allowed_cidrs" {
  type        = list(string)
  description = "Public web ingress CIDRs. Use 0.0.0.0/0 for a public site."
  default     = ["0.0.0.0/0"]
  validation {
    condition     = length(var.web_allowed_cidrs) > 0 && alltrue([for cidr in var.web_allowed_cidrs : can(cidrhost(cidr, 0))])
    error_message = "web_allowed_cidrs must contain at least one valid IPv4 CIDR."
  }
}
variable "ssh_allowed_cidrs" {
  type        = list(string)
  description = "Optional SSH sources. Keep restricted to trusted public IPs; SSM is preferred."
  default     = []
  validation {
    condition     = alltrue([for cidr in var.ssh_allowed_cidrs : can(cidrhost(cidr, 0)) && cidr != "0.0.0.0/0"])
    error_message = "SSH sources must be valid IPv4 CIDRs and cannot be 0.0.0.0/0."
  }
}
variable "ssh_public_key_path" {
  type        = string
  description = "Optional path to an SSH public key; leave empty to use SSM only."
  default     = ""
}
variable "domain_name" {
  type        = string
  description = "Optional DNS name for Caddy-managed HTTPS. Point its A record at the Terraform public_ip output."
  default     = ""
}
variable "image" {
  type        = string
  description = "Immutable GHCR image tag built by GitHub Actions."
}
variable "github_oidc_provider_arn" {
  type        = string
  description = "ARN output by terraform/bootstrap."
}
variable "github_oidc_subject" {
  type        = string
  description = "Exact GitHub OIDC subject for this repository's main branch."
}

variable "ghcr_username" {
  type        = string
  description = "GitHub username that owns the read:packages token stored in SSM."
}
