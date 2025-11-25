output "node_ips" {
  description = "Public IPs of EC2 nodes"
  value       = aws_instance.nodes[*].public_ip
}

output "ssh_example" {
  description = "Example SSH command"
  value       = "ssh -i ~/.ssh/id_rsa ec2-user@${aws_instance.nodes[0].public_ip}"
}
