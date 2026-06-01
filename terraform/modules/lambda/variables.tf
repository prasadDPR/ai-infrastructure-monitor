variable "alert_email" {
  description = "Email address to receive alert notifications"
  type        = string
}

variable "private_subnet_ids" {
  description = "Private subnet IDs for Lambda VPC config"
  type        = list(string)
}

variable "vpc_id" {
  description = "VPC ID for Lambda security group"
  type        = string
}