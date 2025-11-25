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
# Networking setup
# -------------------------------

data "aws_availability_zones" "available" {}

resource "aws_vpc" "main" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = { Name = "ssh-demo-vpc" }
}

resource "aws_internet_gateway" "gw" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "ssh-demo-igw" }
}

resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.1.0/24"
  map_public_ip_on_launch = true
  availability_zone       = data.aws_availability_zones.available.names[0]

  tags = { Name = "public-subnet" }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.gw.id
  }

  tags = { Name = "public-rt" }
}

resource "aws_route_table_association" "public_assoc" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

# -------------------------------
# Security Group
# -------------------------------

resource "aws_security_group" "ssh_sg" {
  name   = "ssh-access"
  vpc_id = aws_vpc.main.id

  ingress {
    description = "Allow SSH from anywhere (demo)"
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

  tags = { Name = "ssh-sg" }
}

# -------------------------------
# Key Pair
# -------------------------------

resource "aws_key_pair" "local_key" {
  key_name   = var.key_name
  public_key = file(var.public_key_path)
}

# -------------------------------
# EC2 Instances (3 nodes)
# -------------------------------

resource "aws_instance" "nodes" {
  count                       = 3
  ami                         = var.ami_id
  instance_type               = var.instance_type
  subnet_id                   = aws_subnet.public.id
  vpc_security_group_ids      = [aws_security_group.ssh_sg.id]
  associate_public_ip_address = true
  key_name                    = aws_key_pair.local_key.key_name

  # user_data for passwordless SSH setup
  user_data = <<-EOF
    #!/bin/bash
    set -eux

    USER=ec2-user
    HOME_DIR=/home/$USER

    # Generate host key for inter-node communication
    mkdir -p $HOME_DIR/.ssh
    chown $USER:$USER $HOME_DIR/.ssh
    chmod 700 $HOME_DIR/.ssh

    # Copy provided authorized_keys (from your local key)
    cp /home/$USER/.ssh/authorized_keys $HOME_DIR/.ssh/authorized_keys

    # Generate new key for internal node-to-node access
    sudo -u $USER ssh-keygen -t rsa -b 2048 -f $HOME_DIR/.ssh/id_rsa -q -N ""
    cat $HOME_DIR/.ssh/id_rsa.pub >> $HOME_DIR/.ssh/authorized_keys

    # Simplify SSH config
    echo "Host *" > $HOME_DIR/.ssh/config
    echo "    StrictHostKeyChecking no" >> $HOME_DIR/.ssh/config
    echo "    UserKnownHostsFile=/dev/null" >> $HOME_DIR/.ssh/config
    chmod 600 $HOME_DIR/.ssh/config
    chown -R $USER:$USER $HOME_DIR/.ssh
  EOF

  tags = {
    Name = "node-${count.index + 1}"
  }
}

# -------------------------------
# Distribute internal SSH keys to all nodes
# -------------------------------

resource "null_resource" "distribute_keys" {
  depends_on = [aws_instance.nodes]
  count      = 3

  connection {
    type        = "ssh"
    user        = "ec2-user"
    private_key = file(var.private_key_path)
    host        = aws_instance.nodes[count.index].public_ip
  }

  provisioner "remote-exec" {
    inline = [
      "mkdir -p ~/.ssh/shared",
      "for ip in ${join(" ", aws_instance.nodes[*].public_ip)}; do ssh -o StrictHostKeyChecking=no ec2-user@$ip 'cat ~/.ssh/id_rsa.pub' >> ~/.ssh/shared/all.pub; done",
      "cat ~/.ssh/shared/all.pub >> ~/.ssh/authorized_keys"
    ]
  }
}