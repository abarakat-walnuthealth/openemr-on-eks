# VPC Configuration - Simplified for Auto Mode
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "6.0.1"

  name = "${var.cluster_name}-vpc"
  cidr = var.vpc_cidr

  azs             = slice(data.aws_availability_zones.available.names, 0, 3)
  private_subnets = var.private_subnets
  public_subnets  = var.public_subnets

  enable_nat_gateway   = true
  enable_vpn_gateway   = false
  enable_dns_hostnames = true
  enable_dns_support   = true

  # Use BCBSMA-whitelisted Elastic IPs for NAT Gateways
  # Primary: 54.84.201.131 (eipalloc-0f3ddbcc5a9cd6e43) - whitelisted by BCBSMA
  # Additional IPs for 3 NAT gateways - request BCBSMA to whitelist:
  # - 174.129.195.105 (eipalloc-02cedae3424465ea2)
  # - 18.208.4.130 (eipalloc-0a5b6152c32fe4240)
  reuse_nat_ips       = true  # Required: Don't create new EIPs
  external_nat_ip_ids = [
    "eipalloc-0f3ddbcc5a9cd6e43",  # 54.84.201.131 (BCBSMA whitelisted)
    "eipalloc-02cedae3424465ea2",  # 174.129.195.105 (request BCBSMA whitelist)
    "eipalloc-0a5b6152c32fe4240"   # 18.208.4.130 (request BCBSMA whitelist)
  ]

  # Enable VPC Flow Logs for regulatory compliance
  enable_flow_log                      = true
  create_flow_log_cloudwatch_iam_role  = true
  create_flow_log_cloudwatch_log_group = true

  # Auto Mode will handle tagging automatically
  public_subnet_tags = {
    "kubernetes.io/role/elb" = 1
  }

  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = 1
  }
}
