terraform {
  backend "s3" {
    bucket         = "rjnoord-finops-tfstate" # must match bootstrap output
    key            = "envs/dev/terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "finops-tf-lock"
    encrypt        = true
  }
}
