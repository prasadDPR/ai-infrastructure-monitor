provider "aws" {
  region = "eu-west-2"
}

module "vpc" {
  source   = "../../modules/vpc"
  vpc_cidr = "10.0.0.0/16"
}

module "eks" {
  source             = "../../modules/eks"
  cluster_name       = "healthcare-monitor"
  private_subnet_ids = module.vpc.private_subnet_ids
}

module "lambda" {
  source      = "../../modules/lambda"
  alert_email = "dprasad28062001@gmail.com"
}

output "lambda_function_url" {
  value = module.lambda.lambda_function_url
}