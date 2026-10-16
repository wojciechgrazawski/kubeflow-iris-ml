SHELL := /bin/bash

# All local Python commands run through this project virtual environment.
VENV ?= .venv
VENV_PYTHON := $(VENV)/bin/python
VENV_PIP := $(VENV_PYTHON) -m pip
PYTHON ?= python3

KFP_VERSION ?= 2.17.0
KSERVE_VERSION ?= v0.20.0
KSERVE_INSTALL_URL := https://github.com/kserve/kserve/releases/download/$(KSERVE_VERSION)/kserve-standard-mode-full-install-with-manifests.sh

# Monitoring stack. Pin the chart version so installs are reproducible.
MONITORING_CHART_VERSION ?= 92.7.0
MONITORING_RELEASE ?= monitoring
MONITORING_NAMESPACE ?= monitoring
MONITORING_CHART ?= prometheus-community/kube-prometheus-stack
MONITORING_HELM_VALUES ?= monitoring/helm/values-orbstack.yaml
MONITORING_WAIT_TIMEOUT ?= 600s
MONITORING_BUILD_DIR := .build/monitoring
MONITORING_KUSTOMIZE_DIR ?= monitoring/kustomize
MONITORING_GRAFANA_LOCAL_PORT ?= 3000
MONITORING_PROMETHEUS_LOCAL_PORT ?= 9090

KFP_BUILD_DIR := .build/kubeflow
KFP_REGISTRY := ghcr.io/kubeflow
# Deployments that must be healthy (install fails if they are not).
# Everything else in the namespace is waited on best-effort: a warning is printed but the install continues.
KFP_CORE_DEPLOYMENTS := mysql seaweedfs metadata-grpc-deployment ml-pipeline workflow-controller
KFP_WAIT_TIMEOUT ?= 900s
KFP_OPTIONAL_TIMEOUT ?= 30s
# Not needed on a local cluster (proxy-agent is the GCP inverse proxy and runs 0 replicas here).
KFP_SKIP_DEPLOYMENTS := proxy-agent
KFP_IMAGES := kfp-api-server kfp-cache-deployer kfp-cache-server kfp-metadata-envoy \
              kfp-metadata-writer kfp-persistence-agent kfp-scheduled-workflow-controller \
              kfp-frontend kfp-viewer-crd-controller kfp-visualization-server \
              kfp-inverse-proxy-agent

# Custom Python predictor image. Keep this tag in sync with
# image: in k8s/iris-inferenceservice.yaml.
PREDICTOR_IMAGE ?= iris-custom-predictor:0.1
PREDICTOR_DOCKERFILE ?= serving/Dockerfile

.PHONY: help venv install compile test test-fast test-kserve test-pipeline test-integration test-all clean-python check-cluster \
        install-kubeflow install-kserve install-all \
        check-kfp-images verify-kubeflow uninstall-kubeflow reinstall-kubeflow \
        run-pipeline pipeline-logs pipeline-status \
        build-predictor deploy-kserve kserve-status kserve-logs \
        kserve-port-forward kserve-predict \
        kubeflow-ui clean-status clean-ml \
        check-monitoring-tools monitoring-repo render-monitoring install-monitoring apply-monitoring-config \
        verify-monitoring monitoring-status monitoring-grafana monitoring-grafana-password \
        monitoring-prometheus uninstall-monitoring \
        monitoring-install monitoring-uninstall

# --------------------------------------------------
# Python environment and tests
# --------------------------------------------------

help:
	@echo "Python: make venv | make install | make clean-python"
	@echo "Tests:  make test | make test-kserve | make test-pipeline | make test-integration | make test-all"
	@echo "KFP:    make compile | make run-pipeline | make pipeline-status | make pipeline-logs"
	@echo "KServe: make build-predictor | make deploy-kserve | make kserve-status | make kserve-port-forward | make kserve-predict"
	@echo "Cluster: make check-cluster | make install-kubeflow | make install-kserve | make install-all | make clean-status"
	@echo "Monitoring: make render-monitoring | make install-monitoring | make apply-monitoring-config | make verify-monitoring | make monitoring-status"
	@echo "           make monitoring-grafana | make monitoring-grafana-password | make monitoring-prometheus | make uninstall-monitoring"

# Create .venv only when it does not already exist. No activation is needed:
# every Python target calls $(VENV_PYTHON) directly.
venv:
	@if [ ! -x "$(VENV_PYTHON)" ]; then \
		echo "Creating Python virtual environment at $(VENV)..."; \
		$(PYTHON) -m venv "$(VENV)"; \
	else \
		echo "Using existing Python virtual environment: $(VENV)"; \
	fi

# Install the development/test dependencies into the project's virtual environment.
install: venv
	$(VENV_PYTHON) -m pip install --upgrade pip
	$(VENV_PIP) install -r requirements-dev.txt

compile: install
	$(VENV_PYTHON) -m pipeline.compile

# `make test` is deliberately safe for local development: no live KServe endpoint required.
test: test-fast

test-fast: install
	$(VENV_PYTHON) -m pytest -v -m "not integration"

test-kserve: install
	$(VENV_PYTHON) -m pytest -v tests/test_kserve.py

test-pipeline: install
	$(VENV_PYTHON) -m pytest -v tests/test_pipeline.py

# Requires a deployed/reachable KServe endpoint and any required test configuration.
test-integration: install
	$(VENV_PYTHON) -m pytest -v -m integration tests/integration/test_kserve_live.py

# Includes live integration tests; requires the integration environment to be ready.
test-all: install
	$(VENV_PYTHON) -m pytest -v

# Remove only local Python environment and common test/lint caches.
clean-python:
	rm -rf "$(VENV)" .pytest_cache .mypy_cache .ruff_cache

# --------------------------------------------------
# Installation
# --------------------------------------------------

check-cluster:
	kubectl cluster-info
	kubectl get nodes

# The upstream env/dev overlay references ghcr.io/kubeflow/kfp-*:master images
# regardless of ?ref=, so we generate a kustomization that pins every kfp-*
# image to KFP_VERSION.
install-kubeflow: check-cluster
	@echo "Installing Kubeflow Pipelines $(KFP_VERSION) (images pinned to $(KFP_VERSION))..."
	kubectl apply -k "github.com/kubeflow/pipelines/manifests/kustomize/cluster-scoped-resources?ref=$(KFP_VERSION)"
	kubectl wait --for=condition=established --timeout=120s crd/applications.app.k8s.io
	@mkdir -p $(KFP_BUILD_DIR)
	@{ \
		echo "apiVersion: kustomize.config.k8s.io/v1beta1"; \
		echo "kind: Kustomization"; \
		echo "resources:"; \
		echo "  - github.com/kubeflow/pipelines/manifests/kustomize/env/dev?ref=$(KFP_VERSION)"; \
		echo "images:"; \
		for img in $(KFP_IMAGES); do \
			echo "  - name: ghcr.io/kubeflow/$$img"; \
			echo "    newTag: $(KFP_VERSION)"; \
		done; \
		echo "patches:"; \
		echo "  - target:"; \
		echo "      kind: Deployment"; \
		echo "      name: ml-pipeline"; \
		echo "    patch: |-"; \
		echo "      apiVersion: apps/v1"; \
		echo "      kind: Deployment"; \
		echo "      metadata:"; \
		echo "        name: ml-pipeline"; \
		echo "      spec:"; \
		echo "        template:"; \
		echo "          spec:"; \
		echo "            containers:"; \
		echo "              - name: ml-pipeline-api-server"; \
		echo "                env:"; \
		echo "                  - name: V2_DRIVER_IMAGE"; \
		echo "                    value: $(KFP_REGISTRY)/kfp-driver:$(KFP_VERSION)"; \
		echo "                  - name: V2_LAUNCHER_IMAGE"; \
		echo "                    value: $(KFP_REGISTRY)/kfp-launcher:$(KFP_VERSION)"; \
	} > $(KFP_BUILD_DIR)/kustomization.yaml
	kubectl apply -k $(KFP_BUILD_DIR)
	@echo "Waiting for core Kubeflow Pipelines deployments ($(KFP_CORE_DEPLOYMENTS))..."
	@for d in $(KFP_CORE_DEPLOYMENTS); do \
		kubectl wait --for=condition=Available deployment/$$d -n kubeflow --timeout=$(KFP_WAIT_TIMEOUT) || { \
			echo "ERROR: core deployment $$d is not available." >&2; \
			kubectl get pods -n kubeflow; exit 1; }; \
	done
	@echo "Checking remaining deployments (best-effort, $(KFP_OPTIONAL_TIMEOUT) each)..."
	@for d in $$(kubectl get deploy -n kubeflow -o name | sed 's|.*/||'); do \
		case " $(KFP_CORE_DEPLOYMENTS) $(KFP_SKIP_DEPLOYMENTS) " in *" $$d "*) continue;; esac; \
		echo "  waiting: $$d ..."; \
		if kubectl wait --for=condition=Available deployment/$$d -n kubeflow --timeout=$(KFP_OPTIONAL_TIMEOUT) >/dev/null 2>&1; then \
			echo "  OK:      $$d"; \
		else \
			echo "  WARNING: $$d is not available yet (non-critical, continuing)"; \
		fi; \
	done
	@$(MAKE) --no-print-directory verify-kubeflow
	@echo "Kubeflow Pipelines core is ready."

check-kfp-images:
	@kubectl get deploy -n kubeflow -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.template.spec.containers[*].image}{"\n"}{end}'
	@echo ""
	@echo "Any remaining :master references (including env vars):"
	@kubectl get deploy -n kubeflow -o yaml | grep -n ':master' || echo "none"

# Fails if the API server would launch driver/launcher images from another version.
verify-kubeflow:
	@DRV="$$(kubectl get deploy ml-pipeline -n kubeflow -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="V2_DRIVER_IMAGE")].value}')"; \
	LCH="$$(kubectl get deploy ml-pipeline -n kubeflow -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="V2_LAUNCHER_IMAGE")].value}')"; \
	API="$$(kubectl get deploy ml-pipeline -n kubeflow -o jsonpath='{.spec.template.spec.containers[0].image}')"; \
	echo "  api-server: $$API"; echo "  driver:     $$DRV"; echo "  launcher:   $$LCH"; \
	for img in "$$API" "$$DRV" "$$LCH"; do \
		case "$$img" in *":$(KFP_VERSION)") ;; *) \
			echo "ERROR: $$img is not pinned to $(KFP_VERSION). Pipeline runs would fail." >&2; exit 1;; esac; \
	done; \
	echo "  OK: api-server, driver and launcher are all $(KFP_VERSION)"

# Removes Kubeflow Pipelines completely (namespace + cluster-scoped resources). Does NOT touch KServe.
# Use FORCE=1 to skip the confirmation prompt.
uninstall-kubeflow:
	@echo "WARNING: deletes the kubeflow namespace (including SeaweedFS/MySQL data) and KFP cluster-scoped resources."
	@echo "Current context: $$(kubectl config current-context)"
	@if [ "$(FORCE)" != "1" ]; then \
		read -r -p "Type yes to continue: " confirm; \
		if [ "$$confirm" != "yes" ]; then echo "Cancelled."; exit 1; fi; \
	fi
	-kubectl delete namespace kubeflow --ignore-not-found=true --wait=true
	-kubectl delete -k "github.com/kubeflow/pipelines/manifests/kustomize/cluster-scoped-resources?ref=$(KFP_VERSION)" --ignore-not-found=true
	@rm -rf $(KFP_BUILD_DIR)
	@echo "Kubeflow Pipelines removed."

# Clean reinstall of Kubeflow Pipelines only.
reinstall-kubeflow: uninstall-kubeflow install-kubeflow

install-kserve: check-cluster
	@echo "Installing KServe $(KSERVE_VERSION) in standard mode..."
	curl -fsSL "$(KSERVE_INSTALL_URL)" | bash
	@echo "Waiting for KServe controller (best-effort)..."
	@kubectl wait --for=condition=Available deployment --all -n kserve --timeout=600s \
		|| echo "WARNING: some KServe deployments are not available yet. Check with: make kserve-status"

install-all: install-kubeflow install-kserve
	@echo "Kubeflow Pipelines and KServe installation steps completed."

# --------------------------------------------------
# Kubeflow Pipelines
# --------------------------------------------------

run-pipeline: compile
	docker build -f automation/Dockerfile -t iris-pipeline-runner:local .
	kubectl delete job iris-pipeline-submit -n kubeflow --ignore-not-found=true
	kubectl apply -f k8s/pipeline-submit-job.yaml
	kubectl wait --for=condition=complete job/iris-pipeline-submit -n kubeflow --timeout=3900s || (kubectl logs -n kubeflow job/iris-pipeline-submit; exit 1)
	kubectl logs -n kubeflow job/iris-pipeline-submit

pipeline-logs:
	kubectl logs -n kubeflow job/iris-pipeline-submit

pipeline-status:
	kubectl get jobs,pods -n kubeflow -l app=iris-pipeline-submit

kubeflow-ui:
	kubectl port-forward -n kubeflow svc/ml-pipeline-ui 8080:80

# --------------------------------------------------
# KServe: custom Iris predictor
# --------------------------------------------------

# Build the custom Python predictor image. The cluster must be able to access it.
build-predictor:
	docker build \
		-f $(PREDICTOR_DOCKERFILE) \
		-t $(PREDICTOR_IMAGE) \
		.

# The custom predictor downloads its model from SeaweedFS itself using the
# AWS_* environment variables in the InferenceService. No KServe storage
# initializer Secret or configure-kserve-storage target is needed.
deploy-kserve: build-predictor
	kubectl apply -f k8s/iris-inferenceservice.yaml
	kubectl wait --for=condition=Ready \
		inferenceservice/iris-classifier \
		-n kubeflow \
		--timeout=600s

kserve-status:
	-kubectl get inferenceservice,pods,svc -n kubeflow
	-kubectl get deployments,pods -n kserve
	-kubectl get crd | grep 'serving.kserve.io' || true

kserve-logs:
	kubectl logs -n kubeflow -l serving.kserve.io/inferenceservice=iris-classifier --all-containers=true --tail=100

kserve-port-forward:
	kubectl port-forward -n kubeflow svc/iris-classifier-predictor 8082:80

kserve-predict:
	curl -sS -X POST http://localhost:8082/v1/models/iris-classifier:predict \
		-H 'Content-Type: application/json' \
		-d '{"instances":[[5.1,3.5,1.4,0.2],[6.7,3.0,5.2,2.3]]}'


# --------------------------------------------------
# Local observability: Prometheus + Grafana
# --------------------------------------------------

# Use the same explicit Makefile-driven lifecycle as Kubeflow and KServe.
# Review `kubectl config current-context` before installation; connectivity
# checks alone cannot prove that the selected cluster is your local OrbStack.
check-monitoring-tools:
	@command -v helm >/dev/null || { echo "ERROR: Helm is required. Install Helm 3+ first." >&2; exit 1; }
	@test -f "$(MONITORING_HELM_VALUES)" || { echo "ERROR: Helm values file not found: $(MONITORING_HELM_VALUES)" >&2; exit 1; }
	@echo "Monitoring chart: $(MONITORING_CHART) version $(MONITORING_CHART_VERSION)"

monitoring-repo: check-monitoring-tools
	helm repo add prometheus-community https://prometheus-community.github.io/helm-charts --force-update
	helm repo update

# Render the pinned chart to a local file for review; this does not change the cluster.
render-monitoring: monitoring-repo
	@mkdir -p "$(MONITORING_BUILD_DIR)"
	helm template $(MONITORING_RELEASE) $(MONITORING_CHART) \
		--version $(MONITORING_CHART_VERSION) \
		--namespace $(MONITORING_NAMESPACE) \
		--values $(MONITORING_HELM_VALUES) \
		> "$(MONITORING_BUILD_DIR)/helm-rendered.yaml"
	@echo "Rendered manifests: $(MONITORING_BUILD_DIR)/helm-rendered.yaml"

# Installs/upgrades only the upstream monitoring stack. Project-owned
# ServiceMonitor and PrometheusRule resources will be managed separately via Kustomize.
install-monitoring: check-cluster check-monitoring-tools monitoring-repo
	@echo "Installing kube-prometheus-stack $(MONITORING_CHART_VERSION) into namespace $(MONITORING_NAMESPACE)..."
	helm upgrade --install $(MONITORING_RELEASE) $(MONITORING_CHART) \
		--version $(MONITORING_CHART_VERSION) \
		--namespace $(MONITORING_NAMESPACE) \
		--create-namespace \
		--values $(MONITORING_HELM_VALUES) \
		--wait --timeout $(MONITORING_WAIT_TIMEOUT)
	@$(MAKE) --no-print-directory -f "$(firstword $(MAKEFILE_LIST))" verify-monitoring
	@$(MAKE) --no-print-directory -f "$(firstword $(MAKEFILE_LIST))" apply-monitoring-config

# Apply project-owned ServiceMonitor and Grafana dashboard resources.
# Run this again after editing files under monitoring/kustomize.
apply-monitoring-config: check-cluster
	@test -d "$(MONITORING_KUSTOMIZE_DIR)" || { \
		echo "ERROR: Monitoring Kustomize directory not found: $(MONITORING_KUSTOMIZE_DIR)" >&2; \
		exit 1; \
	}
	@kubectl get namespace $(MONITORING_NAMESPACE) >/dev/null
	@echo "Applying project monitoring resources from $(MONITORING_KUSTOMIZE_DIR)..."
	kubectl apply -k "$(MONITORING_KUSTOMIZE_DIR)"

verify-monitoring:
	@echo "Helm release:"
	helm status $(MONITORING_RELEASE) --namespace $(MONITORING_NAMESPACE)
	@echo "Monitoring workloads:"
	kubectl get deployments,statefulsets,pods,services -n $(MONITORING_NAMESPACE)
	@echo "Waiting for monitoring pods to become Ready..."
	kubectl wait --for=condition=Ready pod \
		-l app.kubernetes.io/instance=$(MONITORING_RELEASE) \
		-n $(MONITORING_NAMESPACE) --timeout=$(MONITORING_WAIT_TIMEOUT)

monitoring-status:
	kubectl get deployments,statefulsets,pods,svc -n $(MONITORING_NAMESPACE)
	kubectl get events -n $(MONITORING_NAMESPACE) --sort-by=.lastTimestamp

monitoring-grafana:
	kubectl port-forward -n $(MONITORING_NAMESPACE) \
		svc/$(MONITORING_RELEASE)-grafana $(MONITORING_GRAFANA_LOCAL_PORT):80

# Python base64 decoding works on both macOS and Linux (BSD/GNU base64 flags differ).
monitoring-grafana-password:
	@kubectl get secret $(MONITORING_RELEASE)-grafana -n $(MONITORING_NAMESPACE) \
		-o jsonpath='{.data.admin-password}' | $(PYTHON) -c 'import base64,sys; print(base64.b64decode(sys.stdin.read()).decode())'

monitoring-prometheus:
	kubectl port-forward -n $(MONITORING_NAMESPACE) \
		svc/$(MONITORING_RELEASE)-kube-prometheus-prometheus $(MONITORING_PROMETHEUS_LOCAL_PORT):9090

uninstall-monitoring:
	@echo "WARNING: this removes the $(MONITORING_RELEASE) Helm release and deletes namespace $(MONITORING_NAMESPACE), including all resources and any monitoring data stored there."
	@echo "Current context: $$(kubectl config current-context)"
	@read -r -p "Type yes to continue: " confirm; \
	if [ "$$confirm" != "yes" ]; then echo "Cancelled."; exit 1; fi
	-helm uninstall $(MONITORING_RELEASE) --namespace $(MONITORING_NAMESPACE)
	kubectl delete namespace $(MONITORING_NAMESPACE) --ignore-not-found=true --wait=true

# Backward-compatible aliases for the earlier target names.
monitoring-install: install-monitoring
monitoring-uninstall: uninstall-monitoring

# --------------------------------------------------
# Inspect installed resources
# --------------------------------------------------

clean-status:
	@echo "Kubernetes context:"
	kubectl config current-context
	@echo ""
	@echo "Kubeflow namespace:"
	-kubectl get all -n kubeflow
	@echo ""
	@echo "KServe namespace:"
	-kubectl get all -n kserve
	@echo ""
	@echo "Monitoring namespace:"
	-kubectl get all -n $(MONITORING_NAMESPACE)
	@echo ""
	@echo "KServe webhooks:"
	-kubectl get validatingwebhookconfigurations,mutatingwebhookconfigurations -o name | grep 'serving.kserve.io' || true
	@echo ""
	@echo "Kubeflow/KServe CRDs:"
	-kubectl get crd -o name | grep -E 'applications.app.k8s.io|argoproj.io|kubeflow\.org|serving.kserve.io' || true

# --------------------------------------------------
# Full ML stack cleanup
# WARNING: intended for a dedicated disposable development cluster
# --------------------------------------------------

clean-ml:
	@bash -c '\
		set -eu; \
		echo "WARNING: Removes Iris ML resources, KServe admission webhooks, and the entire kserve and kubeflow namespaces."; \
		echo "This deletes ALL namespaced resources in kubeflow, including any SeaweedFS data stored on PVCs."; \
		echo "Current context: $$(kubectl config current-context)"; \
		read -r -p "Type yes to continue: " confirm; \
		if [ "$$confirm" != "yes" ]; then echo "Cleanup cancelled."; exit 1; fi; \
		echo "1/4: Removing Iris InferenceService if its CRD exists..."; \
		if kubectl get crd inferenceservices.serving.kserve.io >/dev/null 2>&1; then \
			kubectl delete -f k8s/iris-inferenceservice.yaml -n kubeflow --ignore-not-found=true || true; \
		else echo "InferenceService CRD is absent; skipping custom resource deletion."; fi; \
		echo "2/4: Removing remaining project resources where possible..."; \
		kubectl delete job iris-pipeline-submit -n kubeflow --ignore-not-found=true || true; \
		echo "3/4: Removing KServe admission webhooks..."; \
		for name in clusterservingruntime.serving.kserve.io inferencegraph.serving.kserve.io inferenceservice.serving.kserve.io servingruntime.serving.kserve.io trainedmodel.serving.kserve.io; do \
			kubectl delete validatingwebhookconfiguration "$$name" --ignore-not-found=true || true; \
		done; \
		kubectl delete mutatingwebhookconfiguration inferenceservice.serving.kserve.io --ignore-not-found=true || true; \
		echo "4/4: Removing kserve and kubeflow namespaces..."; \
		kubectl delete namespace kserve --ignore-not-found=true --wait=true || true; \
		kubectl delete namespace kubeflow --ignore-not-found=true --wait=true; \
		echo "Cleanup commands completed. Inspect remaining resources with: make clean-status"; \
	'