terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
  required_version = ">= 1.5.0"
}

provider "aws" {
  region = var.aws_region
}

# -------------------------------
# Networking
# -------------------------------

# Availability zones
data "aws_availability_zones" "available" {}

# Create VPC
resource "aws_vpc" "main" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags = { Name = "demo-vpc" }
}

# Internet Gateway
resource "aws_internet_gateway" "gw" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "demo-igw" }
}

# Public Subnet (for bastion + NAT gateway)
resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.1.0/24"
  map_public_ip_on_launch = true
  availability_zone       = data.aws_availability_zones.available.names[0]
  tags = { Name = "public-subnet" }
}

# Private Subnet (for app/compute nodes)
resource "aws_subnet" "private" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.2.0/24"
  map_public_ip_on_launch = false
  availability_zone       = data.aws_availability_zones.available.names[0]
  tags = { Name = "private-subnet" }
}

# Elastic IP for NAT Gateway
resource "aws_eip" "nat" {
  domain = "vpc"
  depends_on = [aws_internet_gateway.gw]
  tags = { Name = "nat-eip" }
}

# NAT Gateway (for private subnet egress)
resource "aws_nat_gateway" "nat" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public.id
  depends_on    = [aws_internet_gateway.gw]
  tags = { Name = "nat-gateway" }
}

# Public Route Table (Internet Gateway)
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.gw.id
  }

  tags = { Name = "public-rt" }
}

# Private Route Table (NAT Gateway)
resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.nat.id
  }

  tags = { Name = "private-rt" }
}

# Route Table Associations
resource "aws_route_table_association" "public_assoc" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "private_assoc" {
  subnet_id      = aws_subnet.private.id
  route_table_id = aws_route_table.private.id
}

# -------------------------------
# Security Groups
# -------------------------------

# Bastion SG: Allow SSH from anywhere (for demo)
resource "aws_security_group" "bastion_sg" {
  name   = "bastion-sg"
  vpc_id = aws_vpc.main.id

  ingress {
    description = "Allow SSH from Internet"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "bastion-sg" }
}

# Private EC2 SG: Allow SSH only from Bastion
resource "aws_security_group" "private_sg" {
  name   = "private-sg"
  vpc_id = aws_vpc.main.id

  ingress {
    description = "Allow SSH from bastion"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    security_groups = [aws_security_group.bastion_sg.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "private-sg" }
}

# -------------------------------
# Key Pair
# -------------------------------

resource "aws_key_pair" "my_key" {
  key_name   = var.key_name
  public_key = file(var.public_key_path)
}

# -------------------------------
# Bastion Host (Public Subnet)
# -------------------------------

resource "aws_instance" "bastion" {
  ami                    = var.ami_id
  instance_type          = var.instance_type
  subnet_id              = aws_subnet.public.id
  key_name               = aws_key_pair.my_key.key_name
  vpc_security_group_ids = [aws_security_group.bastion_sg.id]
  associate_public_ip_address = true

  tags = {
    Name = "bastion-host"
    Role = "bastion"
  }
}

# -------------------------------
# Private EC2 Instances (Private Subnet)
# -------------------------------

resource "aws_instance" "nodes" {
  count                       = 3
  ami                         = var.ami_id
  instance_type               = var.instance_type
  subnet_id                   = aws_subnet.private.id
  key_name                    = aws_key_pair.my_key.key_name
  vpc_security_group_ids      = [aws_security_group.private_sg.id]
  associate_public_ip_address = false

  tags = {
    Name = "private-node-${count.index + 1}"
    Role = "app"
  }
}

# -------------------------------
# Outputs
# -------------------------------

output "bastion_public_ip" {
  value = aws_instance.bastion.public_ip
}

output "private_ips" {
  value = aws_instance.nodes[*].private_ip
}

output "nat_gateway_ip" {
  value = aws_eip.nat.public_ip
}