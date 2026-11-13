terraform {
  required_version = ">= 1.10.0"
  backend "s3" {}
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.80" }
  }
}

provider "aws" { region = var.aws_region }
data "aws_caller_identity" "current" {}
data "aws_vpc" "default" { default = true }
data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}
data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["amazon"]
  filter {
    # Standard AL2023 only; the bare "al2023-ami-*" glob also matches
    # al2023-ami-minimal-*, which has a 2 GB root and no SSM agent.
    name   = "name"
    values = ["al2023-ami-20*-x86_64"]
  }
}

resource "aws_security_group" "app" {
  name_prefix = "${var.environment}-app-"
  description = "Application HTTP ingress; outbound access for SSM and image pulls"
  vpc_id      = data.aws_vpc.default.id

  dynamic "ingress" {
    for_each = var.web_allowed_cidrs
    content {
      description = "HTTP web traffic"
      from_port   = 80
      to_port     = 80
      protocol    = "tcp"
      cidr_blocks = [ingress.value]
    }
  }
  dynamic "ingress" {
    for_each = var.domain_name == "" ? [] : var.web_allowed_cidrs
    content {
      description = "HTTPS web traffic (Caddy terminates TLS when domain_name is set)"
      from_port   = 443
      to_port     = 443
      protocol    = "tcp"
      cidr_blocks = [ingress.value]
    }
  }
  dynamic "ingress" {
    for_each = var.ssh_allowed_cidrs
    content {
      description = "Restricted SSH administration"
      from_port   = 22
      to_port     = 22
      protocol    = "tcp"
      cidr_blocks = [ingress.value]
    }
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = { App = "devops-assessment", Environment = var.environment }
}

resource "aws_iam_role" "instance" {
  name = "${var.environment}-devops-instance"
  assume_role_policy = jsonencode({
    Version   = "2012-10-17",
    Statement = [{ Effect = "Allow", Principal = { Service = "ec2.amazonaws.com" }, Action = "sts:AssumeRole" }]
  })
}
resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.instance.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}
resource "aws_cloudwatch_log_group" "app" {
  name              = "/${var.environment}/devops-app"
  retention_in_days = 14
}
resource "aws_s3_bucket" "deploy_bundle" {
  bucket = "${var.environment}-devops-deploy-${data.aws_caller_identity.current.account_id}-${var.aws_region}"
  tags   = { App = "devops-assessment", Environment = var.environment }
}
resource "aws_s3_bucket_versioning" "deploy_bundle" {
  bucket = aws_s3_bucket.deploy_bundle.id
  versioning_configuration {
    status = "Enabled"
  }
}
resource "aws_s3_bucket_server_side_encryption_configuration" "deploy_bundle" {
  bucket = aws_s3_bucket.deploy_bundle.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}
resource "aws_s3_bucket_public_access_block" "deploy_bundle" {
  bucket                  = aws_s3_bucket.deploy_bundle.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}
resource "aws_s3_bucket_ownership_controls" "deploy_bundle" {
  bucket = aws_s3_bucket.deploy_bundle.id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}
resource "aws_s3_bucket_lifecycle_configuration" "deploy_bundle" {
  bucket = aws_s3_bucket.deploy_bundle.id
  rule {
    id     = "expire-release-bundles"
    status = "Enabled"
    filter {
      prefix = "releases/"
    }
    expiration {
      days = 90
    }
    noncurrent_version_expiration {
      noncurrent_days = 30
    }
  }
}
resource "aws_s3_bucket_policy" "deploy_bundle" {
  bucket = aws_s3_bucket.deploy_bundle.id
  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Effect    = "Deny",
      Principal = "*",
      Action    = "s3:*",
      Resource  = [aws_s3_bucket.deploy_bundle.arn, "${aws_s3_bucket.deploy_bundle.arn}/*"],
      Condition = { Bool = { "aws:SecureTransport" = "false" } }
    }]
  })
}
resource "aws_iam_role_policy" "logs" {
  role = aws_iam_role.instance.id
  policy = jsonencode({
    Version   = "2012-10-17",
    Statement = [{ Effect = "Allow", Action = ["logs:CreateLogStream", "logs:PutLogEvents", "logs:DescribeLogStreams"], Resource = "${aws_cloudwatch_log_group.app.arn}:*" }]
  })
}
resource "aws_iam_role_policy" "deploy_bundle_read" {
  role = aws_iam_role.instance.id
  policy = jsonencode({
    Version   = "2012-10-17",
    Statement = [{ Effect = "Allow", Action = ["s3:GetObject"], Resource = "${aws_s3_bucket.deploy_bundle.arn}/releases/*" }]
  })
}
resource "aws_iam_role_policy" "registry" {
  role = aws_iam_role.instance.id
  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      { Effect = "Allow", Action = ["ssm:GetParameter"], Resource = "arn:aws:ssm:${var.aws_region}:${data.aws_caller_identity.current.account_id}:parameter/devops/ghcr-read-token" },
      { Effect = "Allow", Action = ["kms:Decrypt"], Resource = "*", Condition = { StringEquals = { "kms:ViaService" = "ssm.${var.aws_region}.amazonaws.com" } } }
    ]
  })
}
resource "aws_iam_instance_profile" "app" {
  role = aws_iam_role.instance.name
}
resource "aws_key_pair" "ssh" {
  count      = var.ssh_public_key_path == "" ? 0 : 1
  key_name   = "${var.environment}-devops-operator"
  public_key = var.ssh_public_key_path == "" ? "" : file(var.ssh_public_key_path)
}
resource "aws_instance" "app" {
  ami                         = data.aws_ami.al2023.id
  instance_type               = var.instance_type
  subnet_id                   = data.aws_subnets.default.ids[0]
  vpc_security_group_ids      = [aws_security_group.app.id]
  iam_instance_profile        = aws_iam_instance_profile.app.name
  associate_public_ip_address = true
  key_name                    = try(aws_key_pair.ssh[0].key_name, null)
  user_data_replace_on_change = true
  # Explicit root volume: the default follows the AMI snapshot, which is too
  # small for Docker plus the CloudWatch agent, and must be encrypted.
  root_block_device {
    volume_size           = 20
    volume_type           = "gp3"
    encrypted             = true
    delete_on_termination = true
  }
  user_data = templatefile("${path.module}/user_data.sh.tftpl", {
    log_group     = aws_cloudwatch_log_group.app.name
    environment   = var.environment
    aws_region    = var.aws_region
    domain_name   = var.domain_name
    deploy_script = file("${path.module}/../scripts/deploy.sh")
  })
  tags = { Name = "${var.environment}-devops-assessment", App = "devops-assessment", Environment = var.environment }

  lifecycle {
    create_before_destroy = true
  }
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
  }
}

resource "aws_eip" "app" {
  domain = "vpc"
  tags   = { Name = "${var.environment}-devops-assessment", App = "devops-assessment", Environment = var.environment }
}
resource "aws_eip_association" "app" {
  allocation_id = aws_eip.app.id
  instance_id   = aws_instance.app.id
}

resource "aws_iam_policy" "operator_session_manager" {
  name        = "${var.environment}-devops-operator-session-manager"
  description = "Interactive SSM access to tagged devops-assessment EC2 instances. Attach to the human operator IAM role/user."
  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect    = "Allow",
        Action    = ["ssm:StartSession"],
        Resource  = "arn:aws:ec2:${var.aws_region}:${data.aws_caller_identity.current.account_id}:instance/*",
        Condition = { StringEquals = { "ssm:resourceTag/App" = "devops-assessment" } }
      },
      { Effect = "Allow", Action = ["ssm:StartSession"], Resource = "arn:aws:ssm:${var.aws_region}:${data.aws_caller_identity.current.account_id}:document/SSM-SessionManagerRunShell" },
      { Effect = "Allow", Action = ["ssm:TerminateSession", "ssm:ResumeSession"], Resource = "arn:aws:ssm:${var.aws_region}:${data.aws_caller_identity.current.account_id}:session/$${aws:userid}-*" },
      { Effect = "Allow", Action = ["ssmmessages:OpenDataChannel"], Resource = "arn:aws:ssm:${var.aws_region}:${data.aws_caller_identity.current.account_id}:session/$${aws:userid}-*" },
      { Effect = "Allow", Action = ["ssm:DescribeSessions", "ssm:GetConnectionStatus", "ssm:DescribeInstanceInformation", "ssm:DescribeInstanceProperties", "ec2:DescribeInstances"], Resource = "*" }
    ]
  })
}

resource "aws_iam_role" "github_actions" {
  name = "${var.environment}-github-actions-deploy"
  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Effect    = "Allow",
      Principal = { Federated = var.github_oidc_provider_arn },
      Action    = "sts:AssumeRoleWithWebIdentity",
      Condition = { StringEquals = {
        "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com",
        "token.actions.githubusercontent.com:sub" = var.github_oidc_subject
      } }
    }]
  })
}
resource "aws_iam_role_policy" "github_deploy" {
  role = aws_iam_role.github_actions.id
  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect   = "Allow",
        Action   = ["ssm:SendCommand"],
        Resource = "arn:aws:ssm:${var.aws_region}::document/AWS-RunShellScript"
      },
      {
        Effect    = "Allow",
        Action    = ["ssm:SendCommand"],
        Resource  = "arn:aws:ec2:${var.aws_region}:${data.aws_caller_identity.current.account_id}:instance/*",
        Condition = { StringEquals = { "ssm:resourceTag/App" = "devops-assessment" } }
      },
      {
        Effect   = "Allow",
        Action   = ["s3:PutObject"],
        Resource = "${aws_s3_bucket.deploy_bundle.arn}/releases/*"
      },
      { Effect = "Allow", Action = ["ssm:GetCommandInvocation", "ssm:DescribeInstanceInformation", "ec2:DescribeInstances", "ec2:DescribeInstanceStatus", "ec2:DescribeSecurityGroups", "ec2:DescribeRouteTables", "ec2:DescribeNetworkAcls"], Resource = "*" }
    ]
  })
}

output "instance_id" { value = aws_instance.app.id }
output "public_ip" { value = aws_eip.app.public_ip }
output "deploy_bundle_bucket" { value = aws_s3_bucket.deploy_bundle.id }
output "app_http_url" { value = "http://${aws_eip.app.public_ip}" }
output "app_https_url" { value = var.domain_name == "" ? null : "https://${var.domain_name}" }
output "ssm_session_command" { value = "aws ssm start-session --region ${var.aws_region} --target ${aws_instance.app.id}" }
output "ssh_command" { value = var.ssh_public_key_path == "" ? null : "ssh -i ${trimsuffix(var.ssh_public_key_path, ".pub")} ec2-user@${aws_instance.app.public_ip}" }
output "operator_session_manager_policy_arn" { value = aws_iam_policy.operator_session_manager.arn }
output "github_actions_role_arn" { value = aws_iam_role.github_actions.arn }
