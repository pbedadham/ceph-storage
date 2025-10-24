
variable "aws_region" {
  default = "us-west-2"
}

variable "ami_id" {
  # Amazon Linux 2023 for us-west-2
  default = "ami-0e1d35993cb249cee"
}

variable "instance_type" {
  default = "t3.micro"
}

variable "key_name" {
  default = "my-key"
}

variable "public_key_path" {
  default = "~/.ssh/id_rsa.pub"
}