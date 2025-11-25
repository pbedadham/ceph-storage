variable "aws_region" {
  default = "us-west-2"
}

variable "ami_id" {
  # Amazon Linux 2023 AMI (change for your region)
  default = "ami-0e1d35993cb249cee"
}

variable "instance_type" {
  #default = "t2.medium"
  default = "t3.micro"
}

variable "key_name" {
  description = "Key name to create in AWS"
  default     = "local-ssh-key"
}

variable "public_key_path" {
  description = "Local SSH public key path"
  default     = "~/.ssh/id_rsa.pub"
}

variable "private_key_path" {
  description = "Local SSH private key path (for provisioners)"
  default     = "~/.ssh/id_rsa"
}
