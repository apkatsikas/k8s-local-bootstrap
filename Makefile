CLUSTER_NAME          := kind-app
ENVOY_GATEWAY_VERSION := v1.7.1
CERT_MANAGER_VERSION  := v1.20.0

create-cluster:
	kind get clusters | grep -q "^$(CLUSTER_NAME)$$" || kind create cluster --name $(CLUSTER_NAME) --config kind-cluster/kind.yaml

install-envoy-gateway:
	helm upgrade --install eg \
		oci://docker.io/envoyproxy/gateway-helm \
		--version $(ENVOY_GATEWAY_VERSION) \
		--namespace envoy-gateway-system \
		--create-namespace \
		--wait

install-cert-manager:
	helm upgrade --install cert-manager \
		oci://quay.io/jetstack/charts/cert-manager \
		--version $(CERT_MANAGER_VERSION) \
		--namespace cert-manager \
		--create-namespace \
		--set crds.enabled=true \
		--wait

init: create-cluster install-envoy-gateway install-cert-manager

 # Run npm install via Docker to update package-lock.json without needing Node installed locally.
install-node-modules:
	docker run --rm \
		-v $(PWD)/src:/app \
		-w /app \
		node:24-alpine \
		npm install

build:
	docker build -t api:dev .

deploy:
	kind load docker-image api:dev --name $(CLUSTER_NAME)
	helm upgrade --install infra ./charts/infra --wait
	helm upgrade --install api ./charts/api --wait
	kubectl rollout restart deployment/api -n api
	kubectl rollout status deployment/api -n api --timeout=60s

logs:
	kubectl logs -n api -l app=api -f

status:
	kubectl get pods,svc,gateway,httproute -n api

all: init install-node-modules build deploy

delete-cluster:
	kind delete cluster --name $(CLUSTER_NAME)
