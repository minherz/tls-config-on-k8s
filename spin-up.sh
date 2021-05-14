#!/usr/bin/env bash
# Copyright 2021 Google LLC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#      https://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

PROJECT=$(gcloud config get-value project)
BASE_DIR=${BASE_DIR:="${PWD}"}
WORK_DIR=${1:-"${BASE_DIR}/workdir"}
SERVICE_MESH=${2:-"asm"}
ROOT_DOMAIN=${3:-"acme.com"}

# normalize SERVICE_MESH parameter
if [ -z "$SERVICE_MESH" ]; then
    SERVICE_MESH="asm"
elif [ "$SERVICE_MESH" != "istio" ]; then
    SERVICE_MESH="asm"
fi

# validate require that gcloud SDK has project id set up
if [ -z "$PROJECT" ]; then
    echo "Please setup demo project id using 'gcloud config set project PROJECT_ID' command"
    exit 1
fi

if [ ! command -v kpt &> /dev/null ]; then
    echo "To run Anthos Service Mesh you have to install kpt (see https://github.com/GoogleContainerTools/kpt)"
    exit 1
fi
if [ ! command -v jq &> /dev/null ]; then
    echo "To run Anthos Service Mesh you have to install jq"
    exit 1
fi

# prepare work directory
mkdir -p $WORK_DIR
rm -rf $WORK_DIR/*

echo "🛠 Installing client tools..."

mkdir -p $WORK_DIR/bin
PATH=$PATH:$WORK_DIR/bin

## Install kubectx
curl -sLO https://raw.githubusercontent.com/ahmetb/kubectx/master/kubectx
chmod +x kubectx
mv kubectx $WORK_DIR/bin

# Install Kops
curl -sLO https://github.com/kubernetes/kops/releases/download/$(curl -s https://api.github.com/repos/kubernetes/kops/releases/latest | grep tag_name | cut -d '"' -f 4)/kops-linux-amd64
chmod +x kops-linux-amd64
mv kops-linux-amd64 $WORK_DIR/bin/kops

echo "🔆 Enabling GCP APIs..."
gcloud services enable --quiet \
container.googleapis.com \
compute.googleapis.com \
stackdriver.googleapis.com \
iamcredentials.googleapis.com \
gkeconnect.googleapis.com \
gkehub.googleapis.com \
dns.googleapis.com

echo "☸️  Preparing Kubernetes cluster..."
CLUSTER_NAME="microservice-demo"
CLUSTER_ZONE="us-central1-a"

# delete cluster
ZONE="unknown"
while [ -n "$ZONE" ]; do
    ZONE="$(gcloud container clusters list \
            --filter="name:$CLUSTER_NAME" \
            --project $PROJECT \
            --format='value(zone)' 2> /dev/null)"
    if [ -n "$ZONE" ]; then
        gcloud container clusters delete $CLUSTER_NAME \
            --project $PROJECT --zone $ZONE --quiet
    fi
done

WORKLOAD_PARAM=()
if [ "$SERVICE_MESH" = "asm" ]; then
    WORKLOAD_PARAM+=(--workload-pool=$PROJECT.svc.id.goog)
fi

gcloud container clusters create $CLUSTER_NAME --zone $CLUSTER_ZONE --project $PROJECT \
    --machine-type=e2-standard-4 --num-nodes=4 \
    --enable-stackdriver-kubernetes \
    --subnetwork=default \
    --no-enable-autoupgrade \
    --no-enable-autorepair \
    --tags=microservice-demo "${WORKLOAD_PARAM[@]}"

gcloud container clusters get-credentials ${CLUSTER_NAME} --zone ${CLUSTER_ZONE}
kubectx ${CLUSTER_NAME}=gke_${PROJECT}_${CLUSTER_ZONE}_${CLUSTER_NAME}
KUBECONFIG= kubectl config view --minify --flatten --context=$CLUSTER_NAME > $WORK_DIR/$CLUSTER_NAME.context

# change into working directory
pushd $WORK_DIR

# install service mesh: Istio or ASM
SM_VERSION="1.9"
echo "🕸 Installing service mesh on the cluster..."
echo ""
if [ "$SERVICE_MESH" = "asm" ]; then
    echo "⟁  Downloading and configuring Anthos Service Mesh $SM_VERSION"
    curl https://storage.googleapis.com/csm-artifacts/asm/install_asm_1.9 \
    > install_asm
    curl https://storage.googleapis.com/csm-artifacts/asm/install_asm_1.9.sha256 \
    > install_asm.sha256
    sha256sum -c --ignore-missing install_asm.sha256
    chmod +x install_asm
    ./install_asm --project_id $PROJECT --cluster_name $CLUSTER_NAME \
    --cluster_location $CLUSTER_ZONE --enable_all -o envoy-access-log \
    -D asm_install --mode install
else
    echo "⛵  Downloading and configuring Istio $SM_VERSION"
    ISTIO_VERSION="$(curl -sL https://github.com/istio/istio/releases | \
                  grep -o "releases/$SM_VERSION.[0-9]*/" | sort --version-sort | \
                  tail -1 | awk -F'/' '{ print $2}')"
    curl -L https://git.io/getLatestIstio | ISTIO_VERSION=$ISTIO_VERSION sh -
    kubectl create namespace istio-system
    kubectl create secret generic cacerts -n istio-system \
        --from-file=./istio-${ISTIO_VERSION}/samples/certs/ca-cert.pem \
        --from-file=./istio-${ISTIO_VERSION}/samples/certs/ca-key.pem \
        --from-file=./istio-${ISTIO_VERSION}/samples/certs/root-cert.pem \
        --from-file=./istio-${ISTIO_VERSION}/samples/certs/cert-chain.pem
    kubectl create clusterrolebinding cluster-admin-binding \
        --clusterrole=cluster-admin \
        --user=$(gcloud config get-value core/account)
    ./istio-${ISTIO_VERSION}/bin/istioctl install -y
fi

echo "❴…❵ Create demo namespace"
kubectl create ns demo
if [ "$SERVICE_MESH" = "asm" ]; then
    ASM_REVISION="$(kubectl get pod -n istio-system -l app=istiod \
                    -o jsonpath='{.items[0].metadata.labels.istio\.io/rev}')"
    kubectl label ns demo istio-injection- istio.io/rev=$ASM_REVISION --overwrite
else
    kubectl label namespace demo istio-injection=enabled
fi

cat <<EOF | kubectl apply -f -
apiVersion: "security.istio.io/v1beta1"
kind: "PeerAuthentication"
metadata:
  name: demo
  namespace: istio-system
spec:
  mtls:
    mode: STRICT
EOF

echo "🛍️  Download and install Online Boutique microservices demo"
git clone https://github.com/GoogleCloudPlatform/microservices-demo.git
kubectl apply -n demo -f microservices-demo/release/kubernetes-manifests.yaml
kubectl apply -n demo -f microservices-demo/release/istio-manifests.yaml 

echo "  Configure TLS ingress..."
DEMO_DOMAIN="demo.$ROOT_DOMAIN"
APP_DOMAIN="botique.$DEMO_DOMAIN"

# create CA keys
openssl req -x509 -sha256 -nodes -days 365 -newkey rsa:2048 \
    -subj "/O=Botique Inc./CN=$DEMO_DOMAIN" \
    -keyout $DEMO_DOMAIN.key \
    -out $DEMO_DOMAIN.crt
# create domain keys
openssl req -out $APP_DOMAIN.csr \
    -newkey rsa:2048 -nodes \
    -keyout $APP_DOMAIN.key \
    -subj "/CN=$APP_DOMAIN/O=Boutique Org"
openssl x509 -req -days 365 -set_serial 0 \
    -CA $DEMO_DOMAIN.crt -CAkey $DEMO_DOMAIN.key \
    -in $APP_DOMAIN.csr \
    -out $APP_DOMAIN.crt
# store certificate as K8S secret
kubectl create -n istio-system secret tls demo-credential \
    --key=$APP_DOMAIN.key \
    --cert=$APP_DOMAIN.crt

# `kubectl patch` does not work with customer resource; following manifests are taken from
# microservices-demo/release/istio-manifests.yaml
# apply TLS frontend ingress gateway to setup TLS
cat <<EOF | kubectl apply -f -
apiVersion: networking.istio.io/v1alpha3
kind: Gateway
metadata:
  name: frontend-gateway
  namespace: demo
spec:
  selector:
    istio: ingressgateway
  servers:
  - port:
      number: 443
      name: https
      protocol: HTTPS
    tls:
      mode: SIMPLE
      credentialName: demo-credential
    hosts:
    - "$APP_DOMAIN"
EOF

# patch frontend virtual service to setup host
cat <<EOF | kubectl apply -f - 
apiVersion: networking.istio.io/v1alpha3
kind: VirtualService
metadata:
  name: frontend-ingress
  namespace: demo
spec:
  hosts:
  - "$APP_DOMAIN"
  gateways:
  - frontend-gateway
  http:
  - route:
    - destination:
        host: frontend
        port:
          number: 80
EOF

# restore original path
popd > /dev/null

echo "Take care to resolve $APP_DOMAIN to $(kubectl -n istio-system get service istio-ingressgateway -o jsonpath='{.status.loadBalancer.ingress[0].ip}')"