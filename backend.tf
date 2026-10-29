terraform {
  required_version = "1.17.1"

  cloud {
    
    organization = "DigitalTech"

    workspaces {
      name = "aws-ecs-fargate-automated-deployment"
    }
  }
}