
variable "aws_region" {
  default = "us-west-2"
}

variable "ami_id" {
  # Amazon Linux 2023 for us-west-2
  default = "ami-0e1d35993cb249cee"
}

variable "instance_type" {
  default = "t2.medium"
}

variable "key_name" {
  description = "Key pair name"
  type        = string
  default     = "my-keypair"
}

variable "public_key_path" {
  description = "Path to public key file"
  type        = string
  default     = "~/.ssh/id_rsa.pub"
}

variable "private_key_path" {
  description = "Path to private key file"
  type        = string
  default     = "~/.ssh/id_rsa"
}

variable "node_count" {
  description = "Number of private nodes"
  type        = number
  default     = 3
}

variable "spot_max_price" {
  description = "Maximum spot price per hour (empty for on-demand price)"
  type        = string
  default     = "0.03" # ~70-80% discount for t3.micro
}
