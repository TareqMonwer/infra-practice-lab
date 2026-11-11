terraform {
  required_version = ">= 1.7.0"
  backend "s3" {
    bucket       = "REPLACE_WITH_STATE_BUCKET"
    key          = "devops-assessment/terraform.tfstate"
    region       = "us-east-1"
    use_lockfile = true
  }
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.80" }
  }
}
provider "aws" { region = var.aws_region }
data "aws_vpc" "default" { default = true }
data "aws_subnets" "default" {
  filter {
    name = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}
data "aws_ami" "al2023" {
  most_recent = true
  owners = ["amazon"]
  filter {
    name = "name"
    values = ["al2023-ami-*-x86_64"]
  }
}
resource "aws_security_group" "app" {
  name_prefix = "${var.environment}-app-"
  vpc_id = data.aws_vpc.default.id
  ingress {
    from_port = 80
    to_port = 80
    protocol = "tcp"
    cidr_blocks = var.allowed_cidrs
  }
  egress {
    from_port = 0
    to_port = 0
    protocol = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}
resource "aws_iam_role" "instance" {
  name = "${var.environment}-devops-instance"
  assume_role_policy = jsonencode({Version="2012-10-17",Statement=[{Effect="Allow",Principal={Service="ec2.amazonaws.com"},Action="sts:AssumeRole"}]})
}
resource "aws_iam_role_policy_attachment" "ssm" {
  role = aws_iam_role.instance.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}
resource "aws_iam_role_policy" "logs" {
  role = aws_iam_role.instance.id
  policy = jsonencode({Version="2012-10-17",Statement=[{Effect="Allow",Action=["logs:CreateLogStream","logs:PutLogEvents"],Resource="${aws_cloudwatch_log_group.app.arn}:*"}]})
}
resource "aws_iam_role_policy" "registry" {
  role = aws_iam_role.instance.id
  policy = jsonencode({Version="2012-10-17",Statement=[
    {Effect="Allow",Action=["ssm:GetParameter"],Resource="arn:aws:ssm:${var.aws_region}:*:parameter/devops/ghcr-read-token"},
    {Effect="Allow",Action=["kms:Decrypt"],Resource="*"}
  ]})
}
resource "aws_iam_instance_profile" "app" {
  role = aws_iam_role.instance.name
}
resource "aws_cloudwatch_log_group" "app" {
  name = "/${var.environment}/devops-app"
  retention_in_days = 14
}
resource "aws_instance" "app" {
  ami = data.aws_ami.al2023.id
  instance_type = var.instance_type
  subnet_id = data.aws_subnets.default.ids[0]
  vpc_security_group_ids = [aws_security_group.app.id]
  iam_instance_profile = aws_iam_instance_profile.app.name
  associate_public_ip_address = true
  user_data = templatefile("${path.module}/user_data.sh.tftpl", { log_group = aws_cloudwatch_log_group.app.name, image = var.image, environment = var.environment, aws_region = var.aws_region })
  tags = { Name = "${var.environment}-devops-assessment" }
}
output "instance_id" { value = aws_instance.app.id }
output "public_ip" { value = aws_instance.app.public_ip }
