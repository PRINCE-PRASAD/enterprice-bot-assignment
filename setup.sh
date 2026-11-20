#!/usr/bin/env bash
# Create or reuse the kind cluster, install ingress-nginx, and deploy the demo chart.
# Safe to run more than once.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLUSTER_NAME="demo"
NAMESPACE="demo"
RELEASE="demo"
IMAGE_REPOSITORY="demo-service"
IMAGE_TAG="1.0.0"
IMAGE="${IMAGE_REPOSITORY}:${IMAGE_TAG}"
CTX="kind-${CLUSTER_NAME}"
# Pinned provider manifest for kind. Includes hostPort 80/443 and the ingress-ready node selector.
INGRESS_MANIFEST="https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.12.1/deploy/static/provider/kind/deploy.yaml"

log() {
  printf '==> %s\n' "$*"
}

need() {
  if ! command -v "$1" >/dev/null 2>&1; then
    printf 'missing required command: %s\n' "$1" >&2
    exit 1
  fi
}

need docker
need kind
need kubectl
need helm

if kind get clusters | grep -qx "${CLUSTER_NAME}"; then
  log "Reusing kind cluster ${CLUSTER_NAME}"
else
  log "Creating kind cluster ${CLUSTER_NAME}"
  cat <<'EOF' | kind create cluster --name "${CLUSTER_NAME}" --config=-
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
  - role: control-plane
    kubeadmConfigPatches:
      - |
        kind: InitConfiguration
        nodeRegistration:
          kubeletExtraArgs:
            node-labels: "ingress-ready=true"
    extraPortMappings:
      - containerPort: 80
        hostPort: 80
        protocol: TCP
      - containerPort: 443
        hostPort: 443
        protocol: TCP
EOF
fi

kubectl config use-context "${CTX}" >/dev/null

log "Installing ingress-nginx"
applied=0
for _ in 1 2 3 4 5 6; do
  if kubectl --context "${CTX}" apply -f "${INGRESS_MANIFEST}"; then
    applied=1
    break
  fi
  log "ingress-nginx apply failed; retrying"
  sleep 5
done
if [[ "${applied}" -ne 1 ]]; then
  printf 'failed to apply ingress-nginx\n' >&2
  exit 1
fi

log "Waiting for ingress-nginx"
kubectl --context "${CTX}" -n ingress-nginx rollout status deployment/ingress-nginx-controller --timeout=300s
# Admission jobs are already Complete on a second run; wait is a no-op then.
kubectl --context "${CTX}" -n ingress-nginx wait --for=condition=complete job/ingress-nginx-admission-create --timeout=180s
kubectl --context "${CTX}" -n ingress-nginx wait --for=condition=complete job/ingress-nginx-admission-patch --timeout=180s

log "Building ${IMAGE}"
docker build -t "${IMAGE}" "${ROOT}/service"
log "Loading ${IMAGE} into kind"
kind load docker-image "${IMAGE}" --name "${CLUSTER_NAME}"

log "Installing Helm release ${RELEASE} into namespace ${NAMESPACE}"
helm upgrade --install "${RELEASE}" "${ROOT}/chart" \
  --kube-context "${CTX}" \
  --namespace "${NAMESPACE}" \
  --create-namespace \
  --set "image.repository=${IMAGE_REPOSITORY}" \
  --set "image.tag=${IMAGE_TAG}" \
  --set image.pullPolicy=IfNotPresent \
  --wait \
  --timeout 5m

log "Done. Release ${RELEASE} is in namespace ${NAMESPACE} on context ${CTX}."
