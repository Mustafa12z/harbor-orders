.PHONY: up down kubeconfig init plan deploy build-push fmt validate smoke smoke-gke cleanup-k8s

ENV ?= dev
TF_DIR := terraform/environments/$(ENV)
# Match k8s/overlays/<env> namespace (dev=orders, staging=orders-staging, prod=orders-prod).
NAMESPACE ?= $(if $(filter dev,$(ENV)),orders,orders-$(ENV))
REGION ?= europe-west2
IMAGE_TAG ?= bootstrap

SERVICES := api-gateway order-service inventory-service payment-service \
	notification-service shipping-service worker scheduler dashboard-api

init:
	terraform -chdir=$(TF_DIR) init -backend-config=backend.hcl

fmt:
	terraform fmt -recursive terraform

validate: init
	terraform -chdir=$(TF_DIR) validate

plan: init
	@eval "$$(aws configure export-credentials --format env 2>/dev/null)" || true; \
	export AWS_REGION=$${AWS_REGION:-eu-west-2} AWS_DEFAULT_REGION=$${AWS_DEFAULT_REGION:-eu-west-2}; \
	terraform -chdir=$(TF_DIR) plan

# Plan-gated: writes a plan, shows it, then asks before applying that exact plan.
# CI applies the same way (see .github/workflows/infra-ci.yaml) but takes its
# approval from a GitHub Environment instead of a terminal prompt.
up: init
	@eval "$$(aws configure export-credentials --format env 2>/dev/null)" || true; \
	export AWS_REGION=$${AWS_REGION:-eu-west-2} AWS_DEFAULT_REGION=$${AWS_DEFAULT_REGION:-eu-west-2}; \
	PLAN=$$(mktemp -t tfplan.XXXXXX); \
	trap 'rm -f "$$PLAN"' EXIT; \
	terraform -chdir=$(TF_DIR) plan -out="$$PLAN" || exit 1; \
	printf '\nApply this plan to %s? [y/N] ' "$(ENV)"; \
	read -r reply; \
	case "$$reply" in \
		y|Y|yes|YES) terraform -chdir=$(TF_DIR) apply "$$PLAN" ;; \
		*) echo "Aborted; nothing applied."; exit 1 ;; \
	esac

# Delete Ingress/namespace (and orphan NEGs) while the cluster still exists, then destroy infra.
cleanup-k8s:
	ENV=$(ENV) TF_DIR=$(TF_DIR) NAMESPACE=$(NAMESPACE) FIREWALL_ONLY=$(FIREWALL_ONLY) bash scripts/cleanup-k8s.sh

down: cleanup-k8s
	@eval "$$(aws configure export-credentials --format env 2>/dev/null)" || true; \
	export AWS_REGION=$${AWS_REGION:-eu-west-2} AWS_DEFAULT_REGION=$${AWS_DEFAULT_REGION:-eu-west-2}; \
	printf 'Destroy ALL %s infrastructure? Type the environment name to confirm: ' "$(ENV)"; \
	read -r reply; \
	if [ "$$reply" != "$(ENV)" ]; then echo "Aborted; nothing destroyed."; exit 1; fi; \
	terraform -chdir=$(TF_DIR) init -input=false; \
	terraform -chdir=$(TF_DIR) destroy

kubeconfig:
	@eval $$(terraform -chdir=$(TF_DIR) output -raw get_credentials)

# Local convenience. CI: infra-ci pushes :bootstrap before Argo; app-ci pushes SHA + digests.
build-push:
	@AR_URL=$$(terraform -chdir=$(TF_DIR) output -raw artifact_registry_url); \
	REGION_HOST=$$(echo "$$AR_URL" | cut -d/ -f1); \
	gcloud auth configure-docker "$$REGION_HOST" --quiet; \
	for svc in $(SERVICES); do \
		echo "Building $$svc (linux/amd64)..."; \
		docker build --platform=linux/amd64 -t "$${AR_URL}/$${svc}:$(IMAGE_TAG)" ./services/$$svc; \
		docker push "$${AR_URL}/$${svc}:$(IMAGE_TAG)"; \
	done

# Local: build linux/amd64 images, assert arch, curl /healthz in containers
smoke:
	bash scripts/smoke-containers.sh

# Cluster: rollout Ready + /healthz via port-forward (+ Ingress if ready)
smoke-gke: kubeconfig
	NAMESPACE=$(NAMESPACE) ENV=$(ENV) bash scripts/smoke-gke.sh


# Local convenience: apply the committed overlay (no sed rendering). Prefer Argo CD
# once GitOps is bootstrapped; see docs/deploy.md and docs/promotion.md.
deploy: kubeconfig
	kubectl apply -k k8s/overlays/$(ENV)
	@echo "Ingress:"
	@kubectl -n $(NAMESPACE) get ingress orders
	@DOMAIN=$$(terraform -chdir=$(TF_DIR) output -raw domain_name 2>/dev/null || true); \
	if [ -n "$$DOMAIN" ]; then \
		echo "Domain: https://$$DOMAIN (ManagedCertificate may take 15–60m to become Active)"; \
		kubectl -n $(NAMESPACE) get managedcertificate orders-cert 2>/dev/null || true; \
	fi
