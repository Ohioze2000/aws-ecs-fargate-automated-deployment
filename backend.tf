terraform {
  cloud {
    organization = "DigitalTech"
    workspaces { name = "aws-automated-incident-remediation" }
  }
}
