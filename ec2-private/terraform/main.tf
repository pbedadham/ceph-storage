# Terraform main.tf with Spot Instances, SSH key authentication, and extra disks
# ----------------------------------------------------

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

data "aws_availability_zones" "available" {}

resource "aws_vpc" "main" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags = { Name = "demo-vpc" }
}

resource "aws_internet_gateway" "gw" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "demo-igw" }
}

resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.1.0/24"
  map_public_ip_on_launch = true
  availability_zone       = data.aws_availability_zones.available.names[0]
  tags = { Name = "public-subnet" }
}

resource "aws_subnet" "private" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.2.0/24"
  map_public_ip_on_launch = false
  availability_zone       = data.aws_availability_zones.available.names[0]
  tags = { Name = "private-subnet" }
}

resource "aws_eip" "nat" {
  domain = "vpc"
  depends_on = [aws_internet_gateway.gw]
  tags = { Name = "nat-eip" }
}

resource "aws_nat_gateway" "nat" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public.id
  depends_on    = [aws_internet_gateway.gw]
  tags = { Name = "nat-gateway" }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.gw.id
  }
  tags = { Name = "public-rt" }
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.nat.id
  }
  tags = { Name = "private-rt" }
}

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

resource "aws_security_group" "private_sg" {
  name   = "private-sg"
  vpc_id = aws_vpc.main.id

  ingress {
    description     = "Allow SSH from bastion"
    from_port       = 22
    to_port         = 22
    protocol        = "tcp"
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

resource "aws_security_group_rule" "private_to_private" {
  type                     = "ingress"
  from_port                = 0
  to_port                  = 0
  protocol                 = "-1"
  security_group_id        = aws_security_group.private_sg.id
  source_security_group_id = aws_security_group.private_sg.id
}

# -------------------------------
# Key Pair
# -------------------------------

resource "aws_key_pair" "my_key" {
  key_name   = var.key_name
  public_key = file(var.public_key_path)
}

# -------------------------------
# EBS Volumes for Private Nodes
# -------------------------------

resource "aws_ebs_volume" "node_extra_disk" {
  count             = var.node_count
  availability_zone = data.aws_availability_zones.available.names[0]
  size              = 10
  type              = "gp3"

  tags = {
    Name = "extra-disk-server${count.index + 1}"
  }
}

resource "aws_volume_attachment" "node_extra_disk_attach" {
  count       = var.node_count
  device_name = "/dev/sdh"
  volume_id   = aws_ebs_volume.node_extra_disk[count.index].id
  instance_id = aws_instance.nodes[count.index].id

  # Wait for instance to be running before attaching volume
  depends_on = [aws_instance.nodes]
}

# -------------------------------
# Local variables for host configuration
# -------------------------------

locals {
  # Correct format: IP address first, followed by hostname
  host_entries = [
    for i, node in aws_instance.nodes : "${node.private_ip} server${i + 1}"
  ]
  
  etc_hosts_content = join("\n", concat([
    "127.0.0.1 localhost localhost.localdomain localhost4 localhost4.localdomain4",
    "::1 localhost localhost.localdomain localhost6 localhost6.localdomain6",
    "# Added by Terraform - Private nodes"
  ], local.host_entries))
}

# -------------------------------
# Bastion Host (Spot Instance)
# -------------------------------

resource "aws_instance" "bastion" {
  ami                         = var.ami_id
  instance_type               = var.instance_type
  subnet_id                   = aws_subnet.public.id
  key_name                    = aws_key_pair.my_key.key_name
  vpc_security_group_ids      = [aws_security_group.bastion_sg.id]
  associate_public_ip_address = true
  
  # Spot instance configuration
  instance_market_options {
    market_type = "spot"
    
    spot_options {
      max_price = var.spot_max_price
      instance_interruption_behavior = "terminate"
    }
  }
  
  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "required"
  }

  tags = {
    Name = "bastion-host"
    Role = "bastion"
  }

  # Copy private key to bastion for SSH forwarding
  provisioner "file" {
    source      = var.private_key_path
    destination = "/home/ec2-user/.ssh/id_rsa"
    
    connection {
      type        = "ssh"
      user        = "ec2-user"
      private_key = file(var.private_key_path)
      host        = self.public_ip
    }
  }

  # Setup root SSH access on bastion
  provisioner "remote-exec" {
    connection {
      type        = "ssh"
      user        = "ec2-user"
      private_key = file(var.private_key_path)
      host        = self.public_ip
    }

    inline = [
      # Setup root SSH access
      "sudo mkdir -p /root/.ssh",
      "sudo chmod 700 /root/.ssh",
      "sudo cp /home/ec2-user/.ssh/authorized_keys /root/.ssh/authorized_keys",
      "sudo chmod 600 /root/.ssh/authorized_keys",
      "sudo sed -i 's/^#*PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config",
      "sudo sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config",
      "sudo chmod 600 /home/ec2-user/.ssh/id_rsa",
      
      # Set bastion hostname
      "sudo hostnamectl set-hostname bastion",
      "echo 'bastion' | sudo tee /etc/hostname",
      
      "sudo systemctl restart sshd",
      "echo 'Bastion host initial setup completed'"
    ]
  }

  lifecycle {
    ignore_changes = [instance_market_options]
  }
}

# -------------------------------
# Private Nodes (Spot Instances)
# -------------------------------

resource "aws_instance" "nodes" {
  count                  = var.node_count
  ami                    = var.ami_id
  instance_type          = var.instance_type
  subnet_id              = aws_subnet.private.id
  key_name               = aws_key_pair.my_key.key_name
  vpc_security_group_ids = [aws_security_group.private_sg.id]

  # Spot instance configuration
  instance_market_options {
    market_type = "spot"
    
    spot_options {
      max_price = var.spot_max_price
      instance_interruption_behavior = "terminate"
    }
  }
  
  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "required"
  }

  tags = {
    Name = "private-node-${count.index + 1}"
    Role = "node"
  }

  # Setup root SSH access and hostnames on private nodes
  provisioner "remote-exec" {
    connection {
      type        = "ssh"
      user        = "ec2-user"
      private_key = file(var.private_key_path)
      host        = self.private_ip
      bastion_host = aws_instance.bastion.public_ip
      bastion_user = "ec2-user"
      bastion_private_key = file(var.private_key_path)
    }

    inline = [
      # Setup root SSH access
      "sudo mkdir -p /root/.ssh",
      "sudo chmod 700 /root/.ssh",
      "sudo cp /home/ec2-user/.ssh/authorized_keys /root/.ssh/authorized_keys",
      "sudo chmod 600 /root/.ssh/authorized_keys",
      "sudo sed -i 's/^#*PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config",
      "sudo sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config",
      
      # Set individual hostname for each node
      "sudo hostnamectl set-hostname server${count.index + 1}",
      "echo 'server${count.index + 1}' | sudo tee /etc/hostname",
      
      "sudo systemctl restart sshd",
      "echo 'Private node ${count.index + 1} setup completed with hostname server${count.index + 1}'"
    ]
  }

  depends_on = [aws_instance.bastion]
  
  lifecycle {
    ignore_changes = [instance_market_options]
  }
}

# -------------------------------
# Update /etc/hosts on all instances
# -------------------------------

# Null resource to update /etc/hosts on bastion after all nodes are created
resource "null_resource" "update_bastion_hosts" {
  depends_on = [aws_instance.bastion, aws_instance.nodes]

  triggers = {
    nodes_ips = join(",", aws_instance.nodes[*].private_ip)
  }

  connection {
    type        = "ssh"
    user        = "ec2-user"
    private_key = file(var.private_key_path)
    host        = aws_instance.bastion.public_ip
  }

  provisioner "file" {
    content     = local.etc_hosts_content
    destination = "/tmp/hosts_new"
  }

  provisioner "remote-exec" {
    inline = [
      "echo 'Updating /etc/hosts on bastion with all private nodes...'",
      "sudo cp /etc/hosts /etc/hosts.backup",
      "sudo cp /tmp/hosts_new /etc/hosts",
      "sudo rm -f /tmp/hosts_new",
      "echo 'Bastion /etc/hosts updated successfully'"
    ]
  }
}

# Null resource to update /etc/hosts on all private nodes
resource "null_resource" "update_nodes_hosts" {
  count = var.node_count
  depends_on = [aws_instance.nodes]

  triggers = {
    nodes_ips = join(",", aws_instance.nodes[*].private_ip)
  }

  connection {
    type        = "ssh"
    user        = "ec2-user"
    private_key = file(var.private_key_path)
    host        = aws_instance.nodes[count.index].private_ip
    bastion_host = aws_instance.bastion.public_ip
    bastion_user = "ec2-user"
    bastion_private_key = file(var.private_key_path)
  }

  provisioner "file" {
    content     = local.etc_hosts_content
    destination = "/tmp/hosts_new"
  }

  provisioner "remote-exec" {
    inline = [
      "echo 'Updating /etc/hosts on server${count.index + 1} with all private nodes...'",
      "sudo cp /etc/hosts /etc/hosts.backup",
      "sudo cp /tmp/hosts_new /etc/hosts",
      "sudo rm -f /tmp/hosts_new",
      "echo 'Server${count.index + 1} /etc/hosts updated successfully'"
    ]
  }
}

# -------------------------------
# Configure SSH key authentication between all servers
# -------------------------------

# Copy the same SSH private key to all private nodes for root-to-root communication
resource "null_resource" "copy_ssh_keys_to_nodes" {
  count = var.node_count
  depends_on = [aws_instance.nodes]

  triggers = {
    nodes_ips = join(",", aws_instance.nodes[*].private_ip)
  }

  connection {
    type        = "ssh"
    user        = "ec2-user"
    private_key = file(var.private_key_path)
    host        = aws_instance.nodes[count.index].private_ip
    bastion_host = aws_instance.bastion.public_ip
    bastion_user = "ec2-user"
    bastion_private_key = file(var.private_key_path)
  }

  provisioner "file" {
    source      = var.private_key_path
    destination = "/home/ec2-user/.ssh/id_rsa"
  }

  provisioner "remote-exec" {
    inline = [
      "sudo cp /home/ec2-user/.ssh/id_rsa /root/.ssh/id_rsa",
      "sudo chmod 600 /root/.ssh/id_rsa",
      "sudo chmod 600 /home/ec2-user/.ssh/id_rsa",
      "echo 'SSH keys configured on server${count.index + 1}'"
    ]
  }
}

# Copy the same SSH private key to bastion root for bastion-to-nodes communication
resource "null_resource" "copy_ssh_keys_to_bastion_root" {
  depends_on = [aws_instance.bastion]

  triggers = {
    bastion_ip = aws_instance.bastion.private_ip
  }

  connection {
    type        = "ssh"
    user        = "ec2-user"
    private_key = file(var.private_key_path)
    host        = aws_instance.bastion.public_ip
  }

  provisioner "file" {
    source      = var.private_key_path
    destination = "/home/ec2-user/.ssh/id_rsa"
  }

  provisioner "remote-exec" {
    inline = [
      "sudo cp /home/ec2-user/.ssh/id_rsa /root/.ssh/id_rsa",
      "sudo chmod 600 /root/.ssh/id_rsa",
      "sudo chmod 600 /home/ec2-user/.ssh/id_rsa",
      "echo 'SSH keys configured on bastion root'"
    ]
  }
}

# -------------------------------
# Format and mount extra disks on private nodes
# -------------------------------

resource "null_resource" "setup_extra_disks" {
  count = var.node_count
  depends_on = [aws_volume_attachment.node_extra_disk_attach]

  triggers = {
    volume_attachment = join(",", aws_volume_attachment.node_extra_disk_attach[*].id)
  }

  connection {
    type        = "ssh"
    user        = "ec2-user"
    private_key = file(var.private_key_path)
    host        = aws_instance.nodes[count.index].private_ip
    bastion_host = aws_instance.bastion.public_ip
    bastion_user = "ec2-user"
    bastion_private_key = file(var.private_key_path)
  }

  provisioner "remote-exec" {
    inline = [
      "echo 'Setting up extra disk on server${count.index + 1}...'",
      # Check if disk exists and is not already formatted
      "if [ -b /dev/sdh ]; then",
      "  echo 'Disk /dev/sdh found, checking if formatted...'",
      "  # Check if disk has a filesystem",
      "  if ! sudo blkid /dev/sdh; then",
      "    echo 'Formatting disk as ext4...'",
      "    sudo mkfs -t ext4 /dev/sdh",
      "  else",
      "    echo 'Disk already has a filesystem, skipping format'",
      "  fi",
      "  # Create mount point",
      "  sudo mkdir -p /mnt/extra",
      "  # Mount the disk",
      "  sudo mount /dev/sdh /mnt/extra",
      "  # Add to fstab for automatic mounting on boot",
      "  echo '/dev/sdh /mnt/extra ext4 defaults,nofail 0 2' | sudo tee -a /etc/fstab",
      "  # Change ownership to ec2-user for easy access",
      "  sudo chown ec2-user:ec2-user /mnt/extra",
      "  echo 'Extra disk mounted at /mnt/extra on server${count.index + 1}'",
      "  # Show disk info",
      "  df -h /mnt/extra",
      "else",
      "  echo 'ERROR: Disk /dev/sdh not found!'",
      "  echo 'Available disks:'",
      "  lsblk",
      "fi"
    ]
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

output "ebs_volume_ids" {
  value = aws_ebs_volume.node_extra_disk[*].id
}

output "host_mapping" {
  value = <<EOT

Hostname to IP Mapping:
-----------------------
bastion: ${aws_instance.bastion.public_ip} (public) / ${aws_instance.bastion.private_ip} (private)

${join("\n", [for i, node in aws_instance.nodes : "server${i + 1}: ${node.private_ip}"])}

/etc/hosts configuration:
-------------------------
${local.etc_hosts_content}
EOT
}

output "disk_information" {
  value = <<EOT

Extra Disk Information:
-----------------------
Each private node (server1, server2, server3) has an additional 10GB EBS volume:
- Volume Type: gp3 (General Purpose SSD)
- Mount Point: /mnt/extra
- Filesystem: ext4
- Device: /dev/sdh

Volume IDs:
${join("\n", [for i, vol in aws_ebs_volume.node_extra_disk : "server${i + 1}: ${vol.id}"])}

To check disks from bastion:
  ssh root@server1 "df -h /mnt/extra"
  ssh root@server2 "df -h /mnt/extra"  
  ssh root@server3 "df -h /mnt/extra"
EOT
}

output "ssh_connection_instructions" {
  value = <<EOT

SSH Connection Instructions:

1. Connect to bastion host:
   ssh -i ${var.private_key_path} ec2-user@${aws_instance.bastion.public_ip}

2. From bastion as root, connect to private nodes without password:
   sudo su -
   ssh root@server1
   ssh root@server2
   ssh root@server3

3. Test connectivity between private nodes:
   ssh root@server1 "ssh root@server2 hostname"
   ssh root@server1 "ssh root@server3 hostname"

4. Check extra disks:
   ssh root@server1 "df -h /mnt/extra"
   ssh root@server2 "lsblk"

Passwordless SSH is configured between all servers as root!
Each private node has a 10GB extra disk mounted at /mnt/extra
EOT
}

output "verification_commands" {
  value = <<EOT

Verification Commands:

1. Test passwordless SSH from bastion to nodes:
   ssh -i ${var.private_key_path} ec2-user@${aws_instance.bastion.public_ip}
   sudo su -
   ssh root@server1 hostname
   ssh root@server2 hostname
   ssh root@server3 hostname

2. Check extra disks on all nodes:
   for server in server1 server2 server3; do echo "=== $$server ==="; ssh root@$$server "df -h /mnt/extra && lsblk"; done

3. Test disk functionality:
   ssh root@server1 "echo 'Hello from server1' > /mnt/extra/test.txt"
   ssh root@server2 "cat /mnt/extra/test.txt"

4. Check /etc/hosts on any node:
   ssh -i ${var.private_key_path} -o ProxyCommand="ssh -i ${var.private_key_path} -W %h:%p ec2-user@${aws_instance.bastion.public_ip}" root@server1 "cat /etc/hosts"
EOT
}

output "passwordless_ssh_info" {
  value = <<EOT

✅ Passwordless SSH Configuration:

- All servers (bastion, server1, server2, server3) have the same SSH key
- Root user on all servers can SSH to any other server without password
- Use: ssh root@server1, ssh root@server2, etc.
- Hostname resolution works via /etc/hosts

✅ Extra Disk Configuration:

- Each private node has an additional 10GB EBS volume (gp3)
- Mounted at /mnt/extra with ext4 filesystem
- Automatically mounted on boot via /etc/fstab
- Accessible by ec2-user for easy use

Test commands from bastion:
  sudo su -
  ssh root@server1 "df -h /mnt/extra"
  ssh root@server2 "lsblk"
  ssh root@server3 "mount | grep extra"
EOT
}