# versions.tf — terraform + provider version constraints for this
# throwaway verification fixture (a root module, unlike ../.. which
# has no provider block by design).

terraform {
  required_version = ">= 1.9"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

provider "aws" {
  region = var.region
}
