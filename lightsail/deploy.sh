#!/usr/bin/env bash
# Deploy Sparks AI Brain to AWS Lightsail Container Service.
#
# Run from AWS CloudShell (has docker + aws cli) or any machine with both.
# Required env vars: GEMINI_API_KEY, SERVICE_API_KEY
#
#   export GEMINI_API_KEY=your_real_key
#   export SERVICE_API_KEY=your_real_key
#   bash lightsail/deploy.sh
set -euo pipefail

SERVICE_NAME="${SERVICE_NAME:-spx-ai-brain}"
REGION="${AWS_REGION:-us-east-1}"
POWER="${POWER:-micro}"   # micro = 1 GB RAM / 0.25 vCPU, $10/mo
SCALE="${SCALE:-1}"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

: "${GEMINI_API_KEY:?Set GEMINI_API_KEY before running}"
: "${SERVICE_API_KEY:?Set SERVICE_API_KEY before running}"

# 1. Install lightsailctl if missing (needed by push-container-image)
if ! command -v lightsailctl >/dev/null 2>&1; then
  echo "Installing lightsailctl..."
  curl -sSL "https://s3.us-west-2.amazonaws.com/lightsailctl/latest/linux-amd64/lightsailctl" -o "$HOME/lightsailctl"
  chmod +x "$HOME/lightsailctl"
  sudo mv "$HOME/lightsailctl" /usr/local/bin/lightsailctl 2>/dev/null || {
    mkdir -p "$HOME/bin" && mv "$HOME/lightsailctl" "$HOME/bin/lightsailctl" && export PATH="$HOME/bin:$PATH"
  }
fi

# 2. Create the container service if it doesn't exist yet
if ! aws lightsail get-container-services --service-name "$SERVICE_NAME" --region "$REGION" >/dev/null 2>&1; then
  echo "Creating Lightsail container service '$SERVICE_NAME' ($POWER, scale $SCALE)..."
  aws lightsail create-container-service \
    --service-name "$SERVICE_NAME" --power "$POWER" --scale "$SCALE" --region "$REGION"
  echo "Waiting for service to become READY..."
  until aws lightsail get-container-services --service-name "$SERVICE_NAME" --region "$REGION" \
        --query 'containerServices[0].state' --output text | grep -q READY; do
    sleep 15; echo "  ...still provisioning"
  done
fi

# 3. Build and push the image
echo "Building image..."
docker build -t "$SERVICE_NAME:latest" "$REPO_ROOT"

echo "Pushing image to Lightsail..."
PUSH_OUTPUT=$(aws lightsail push-container-image \
  --service-name "$SERVICE_NAME" --label app --image "$SERVICE_NAME:latest" --region "$REGION")
echo "$PUSH_OUTPUT"
IMAGE_REF=$(echo "$PUSH_OUTPUT" | grep -o '":[^"]*"' | tr -d '":' | head -1)
[ -n "$IMAGE_REF" ] || { echo "Could not parse pushed image ref"; exit 1; }
echo "Pushed as :$IMAGE_REF"

# 4. Render containers.json with real values (never committed)
CONTAINERS_JSON=$(mktemp)
trap 'rm -f "$CONTAINERS_JSON"' EXIT
sed -e "s|__IMAGE__|:$IMAGE_REF|" \
    -e "s|__GEMINI_API_KEY__|$GEMINI_API_KEY|" \
    -e "s|__SERVICE_API_KEY__|$SERVICE_API_KEY|" \
    "$REPO_ROOT/lightsail/containers.template.json" > "$CONTAINERS_JSON"

# 5. Deploy
echo "Creating deployment..."
aws lightsail create-container-service-deployment \
  --service-name "$SERVICE_NAME" --region "$REGION" \
  --containers "file://$CONTAINERS_JSON" \
  --public-endpoint "file://$REPO_ROOT/lightsail/public-endpoint.json"

echo "Waiting for deployment to go ACTIVE..."
until STATE=$(aws lightsail get-container-services --service-name "$SERVICE_NAME" --region "$REGION" \
      --query 'containerServices[0].state' --output text) && [ "$STATE" = "RUNNING" ]; do
  echo "  state: $STATE"
  [ "$STATE" = "DISABLED" ] && { echo "Deployment failed — check: aws lightsail get-container-log --service-name $SERVICE_NAME --container-name app"; exit 1; }
  sleep 15
done

URL=$(aws lightsail get-container-services --service-name "$SERVICE_NAME" --region "$REGION" \
      --query 'containerServices[0].url' --output text)
echo ""
echo "✅ Deployed: $URL"
echo "   Health:  ${URL}health"
