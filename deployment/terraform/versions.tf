terraform {
  required_version = ">= 1.6"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }

  # Remote state (recommended once you work in a team). Create the bucket first, then uncomment.
  # backend "s3" {
  #   bucket       = "my-tf-state-bucket"
  #   key          = "scalable-webapp/terraform.tfstate"
  #   region       = "eu-west-3"
  #   use_lockfile = true
  #   encrypt      = true
  # }
}

provider "aws" {
  region = var.region
  default_tags {
    tags = local.tags
  }
}

# CloudFront certificates and Route 53 health-check alarms must live in us-east-1.
provider "aws" {
  alias  = "us_east_1"
  region = "us-east-1"
  default_tags {
    tags = local.tags
  }
}
