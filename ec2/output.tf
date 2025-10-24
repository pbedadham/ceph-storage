output "bastion_ssh_command" {
  value = "ssh -A ec2-user@${aws_instance.bastion.public_ip}"
}

output "private_ssh_example" {
  value = "ssh ec2-user@${aws_instance.nodes[0].private_ip}  # (from bastion)"
}

output "private_node_ips" {
  value = aws_instance.nodes[*].private_ip
}

output "nat_gateway_public_ip" {
  value = aws_eip.nat.public_ip
}