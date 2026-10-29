#!/usr/bin/env bash
set -Eeuo pipefail

# Optional local deployment helper. The recommended path is the GitHub Actions
# workflow, which creates ECR through Terraform and publishes commit-SHA tags.
# This helper assumes the Terraform-managed ECR repository and ECS service exist.
REGION="${AWS_REGION:-us-east-1}"
IMAGE_TAG="${IMAGE_TAG:-git-$(git rev-parse HEAD)}"

command -v docker >/dev/null || { echo "ERROR: Docker is required." >&2; exit 1; }
command -v aws >/dev/null || { echo "ERROR: AWS CLI is required." >&2; exit 1; }
command -v terraform >/dev/null || { echo "ERROR: Terraform CLI is required." >&2; exit 1; }

echo "Reading Terraform outputs..."
REPO_URL="$(terraform output -raw ecr_repository_url)"
CLUSTER_NAME="$(terraform output -raw ecs_cluster_name)"
SERVICE_NAME="$(terraform output -raw ecs_service_name)"

if [[ -z "$REPO_URL" || -z "$CLUSTER_NAME" || -z "$SERVICE_NAME" ]]; then
  echo "ERROR: Required Terraform outputs are empty." >&2
  exit 1
fi

REPOSITORY_NAME="${REPO_URL##*/}"
ACCOUNT_REGISTRY="${REPO_URL%%/*}"

echo "Checking Terraform-managed ECR repository..."
aws ecr describe-repositories --region "$REGION" --repository-names "$REPOSITORY_NAME" >/dev/null

echo "Authenticating Docker to ECR..."
aws ecr get-login-password --region "$REGION" |
  docker login --username AWS --password-stdin "$ACCOUNT_REGISTRY"

echo "Building actual website from the repository root (Dockerfile copies ./app)..."
docker build --pull --platform linux/amd64 -t "$REPO_URL:$IMAGE_TAG" .
echo "Pushing immutable image tag $IMAGE_TAG..."
docker push "$REPO_URL:$IMAGE_TAG"

echo "Updating Terraform task definition to use the new immutable image tag..."
export TF_VAR_image_tag="$IMAGE_TAG"
terraform apply -auto-approve

echo "Waiting for ECS service stability..."
aws ecs wait services-stable --region "$REGION" --cluster "$CLUSTER_NAME" --services "$SERVICE_NAME"

echo "Deployment completed. Application URL: $(terraform output -raw application_url)"
