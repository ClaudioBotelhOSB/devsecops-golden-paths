# ==============================================================================
# Makefile - Local development entrypoint.
# Owner: platform engineering
#
# Scope clarification (read this first):
#   This Makefile covers the LOCAL development loop. It is NOT a byte-for-byte
#   mirror of the CI pipeline - many CI-only concerns (keyless Cosign, SLSA
#   attestation, Trivy image scan against pushed digests, SonarQube delta
#   scans, preview environment provision, E2E gates, DORA emission, signed
#   plan apply) require GitHub OIDC + GHCR + cluster access and only run from
#   Actions. Targets below marked `(CI-only)` in their help string are the
#   ones that do NOT run locally; they document the real CI command for
#   reference.
#
#   Divergence rules:
#     1. Anything developer-facing (lint, vet, test, build, sync, precommit)
#        must behave identically in both places.
#     2. Anything platform-security-facing (sign, attest, verify, scan) is
#        authoritative in CI only.
# ==============================================================================

SHELL            := bash
.SHELLFLAGS      := -eu -o pipefail -c
.ONESHELL:
.DEFAULT_GOAL    := help

GO               ?= go
GOFLAGS          := -buildvcs=false
GOBIN            := $(CURDIR)/bin
GO_PKGS          := ./...
GO_BUILD_FLAGS   := -trimpath -ldflags="-s -w"
COVER_OUT        := coverage.out

# All platform context is derived from the environment. Nothing is
# hardcoded to the template author. Override any of these on the CLI,
# from your shell profile, or via a local `.env`.
REPO_OWNER       ?= $(shell git config --get remote.origin.url 2>/dev/null | sed -E 's|.*[:/]([^/]+)/[^/]+\.git$$|\1|' | tr '[:upper:]' '[:lower:]')
REPO_NAME        ?= $(shell git config --get remote.origin.url 2>/dev/null | sed -E 's|.*/([^/]+)\.git$$|\1|' | tr '[:upper:]' '[:lower:]')
PLATFORM_OWNER   ?= $(REPO_OWNER)
GO_MODULE        ?= $(shell awk '/^module / {print $$2; exit}' go.mod 2>/dev/null)
PREVIEW_BASE_DOMAIN ?= preview.example.internal
IMAGE_REGISTRY   ?= ghcr.io/$(REPO_OWNER)/$(REPO_NAME)
API_NAME         ?= api
REAPER_NAME      ?= ttl-reaper
BUILD_SHA        := $(shell git rev-parse --short HEAD 2>/dev/null || echo dev)

# ----------------------------------------------------------------------------
# Help
# ----------------------------------------------------------------------------
.PHONY: help
help: ## Show this help
	@awk 'BEGIN {FS = ":.*##"; printf "\nUsage: make \033[36m<target>\033[0m\n\nTargets:\n"} /^[a-zA-Z_0-9-]+:.*?##/ { printf "  \033[36m%-22s\033[0m %s\n", $$1, $$2 }' $(MAKEFILE_LIST)

# ----------------------------------------------------------------------------
# Dependencies / lockfile
# ----------------------------------------------------------------------------
.PHONY: sync
sync: ## Regenerate go.sum and download modules
	$(GO) mod tidy
	$(GO) mod download

.PHONY: verify
verify: ## Verify module checksums match go.sum
	$(GO) mod verify

# ----------------------------------------------------------------------------
# Lint / format / vet
# ----------------------------------------------------------------------------
.PHONY: fmt
fmt: ## gofmt + goimports (local-prefix auto-derived from go.mod)
	gofmt -s -w .
	@command -v goimports >/dev/null && goimports -w -local "$(GO_MODULE)" . || true

.PHONY: lint
lint: ## golangci-lint (fast + full)
	golangci-lint run --timeout=5m $(GO_PKGS)

.PHONY: vet
vet: ## go vet
	$(GO) vet $(GO_PKGS)

# ----------------------------------------------------------------------------
# Test
# ----------------------------------------------------------------------------
.PHONY: test
test: ## Unit tests with race + coverage
	$(GO) test -race -count=1 -timeout=10m -covermode=atomic -coverprofile=$(COVER_OUT) $(GO_PKGS)

.PHONY: test-short
test-short: ## Short tests (pre-commit speed)
	$(GO) test -short -race -timeout=2m $(GO_PKGS)

.PHONY: coverage
coverage: test ## Render HTML coverage report
	$(GO) tool cover -html=$(COVER_OUT) -o coverage.html

# ----------------------------------------------------------------------------
# Build
# ----------------------------------------------------------------------------
.PHONY: build
build: ## Build all cmd/ binaries into ./bin
	mkdir -p $(GOBIN)
	for d in cmd/*/; do
		name=$$(basename $$d)
		echo "building $$name"
		$(GO) build $(GO_BUILD_FLAGS) -o $(GOBIN)/$$name ./$$d
	done

.PHONY: build-api
build-api: ## Build only the primary API binary
	mkdir -p $(GOBIN)
	$(GO) build $(GO_BUILD_FLAGS) -o $(GOBIN)/$(API_NAME) ./cmd/$(API_NAME)

.PHONY: build-reaper
build-reaper: ## Build only the TTL reaper
	mkdir -p $(GOBIN)
	$(GO) build $(GO_BUILD_FLAGS) -o $(GOBIN)/$(REAPER_NAME) ./cmd/$(REAPER_NAME)

# ----------------------------------------------------------------------------
# Docker / SBOM / sign (local smoke test of the CI chain)
# Pass CMD=<subdir> to target a specific cmd/ entry, e.g.:
#   make image CMD=api
#   make image CMD=ttl-reaper
# ----------------------------------------------------------------------------
CMD ?= $(API_NAME)

.PHONY: image
image: ## Build OCI image for ./cmd/$(CMD)
	docker build \
	  --build-arg BUILD_SHA=$(BUILD_SHA) \
	  --build-arg BUILD_USER=$(PLATFORM_OWNER) \
	  --build-arg CMD=$(CMD) \
	  -t $(IMAGE_REGISTRY)/$(CMD):$(BUILD_SHA) \
	  .

.PHONY: sbom
sbom: ## Generate SPDX SBOM via Syft for the local image
	syft $(IMAGE_REGISTRY)/$(CMD):$(BUILD_SHA) -o spdx-json=sbom.spdx.json

# ----------------------------------------------------------------------------
# Pre-commit / secret scan
# ----------------------------------------------------------------------------
.PHONY: hooks
hooks: ## Install pre-commit hooks
	pre-commit install --install-hooks
	pre-commit install --hook-type commit-msg
	pre-commit install --hook-type pre-push

.PHONY: precommit
precommit: ## Run all pre-commit hooks on the full tree
	pre-commit run --all-files

.PHONY: secrets
secrets: ## Gitleaks server-side equivalent
	gitleaks detect --redact --verbose --exit-code=1

# ----------------------------------------------------------------------------
# Terraform convenience
# ----------------------------------------------------------------------------
.PHONY: tf-fmt
tf-fmt:
	terraform -chdir=terraform fmt -recursive

.PHONY: tf-validate
tf-validate:
	terraform -chdir=terraform validate

.PHONY: tf-plan
tf-plan: ## terraform plan for $ENV (default: preview)
	ENV=$${ENV:-preview}; \
	terraform -chdir=terraform init -backend-config=backends/$${ENV}.hcl; \
	terraform -chdir=terraform plan -var-file=environments/$${ENV}.tfvars -out=tfplan.$${ENV}.binary

# ----------------------------------------------------------------------------
# Kubernetes / Kyverno / Argo
# ----------------------------------------------------------------------------
.PHONY: k8s-lint
k8s-lint: ## kubeval + kube-linter on k8s/
	kubeval --strict k8s/**/*.yaml
	kube-linter lint k8s/

.PHONY: policy-test
policy-test: ## Kyverno policy dry-run against sample pods
	kyverno apply k8s/policies/ \
	  --resource k8s/testdata/pod-signed.yaml \
	  --resource k8s/testdata/pod-unsigned.yaml

.PHONY: chart-lint
chart-lint: ## Helm lint + preview render of the backend-template chart
	helm lint charts/backend-template
	helm lint charts/backend-template \
	  -f charts/backend-template/values.preview.yaml \
	  --set image.repository=$(IMAGE_REGISTRY)/$(API_NAME) \
	  --set image.digest=sha256:deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef \
	  --set ingress.host=pr-local.$(PREVIEW_BASE_DOMAIN)
	helm template backend charts/backend-template \
	  -f charts/backend-template/values.preview.yaml \
	  --set image.repository=$(IMAGE_REGISTRY)/$(API_NAME) \
	  --set image.digest=sha256:deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef \
	  --set ingress.host=pr-local.$(PREVIEW_BASE_DOMAIN) \
	  > /tmp/backend-template-rendered.yaml
	@echo "rendered -> /tmp/backend-template-rendered.yaml"

# ----------------------------------------------------------------------------
# Cleanup
# ----------------------------------------------------------------------------
.PHONY: clean
clean:
	rm -rf bin/ $(COVER_OUT) coverage.html sbom.spdx.json sbom.cdx.json

# ----------------------------------------------------------------------------
# Local umbrella - subset of CI that runs without cloud credentials.
# The authoritative PR gate sequence lives in .github/workflows/*.yml.
# ----------------------------------------------------------------------------
.PHONY: ci
ci: sync vet lint test build chart-lint ## Local developer equivalent of the PR gate (no sign/push/scan)

.PHONY: ci-remote-help
ci-remote-help: ## Print the authoritative CI sequence (CI-only) and where it lives
	@cat <<EOF
	Authoritative CI gates (run on GitHub Actions, not locally):
	  - secret-scan.yml      : gitleaks (server-side, fail-closed)
	  - backend-ci.yml       : lint, test, gosec, trivy fs, trivy image, SBOM, cosign sign/verify, SPDX + SLSA attestations
	  - iac-pr.yml           : tflint, tfsec, checkov, terraform plan, cosign sign-blob, Infracost FinOps gate, plan-JSON tag policy
	  - iac-apply.yml        : verify-blob signed plan, apply exact binary
	  - iac-drift.yml        : scheduled drift detection + incident creation
	  - preview-env.yml      : digest-pinned Helm deploy + cosign verify of image + SPDX + SLSA
	  - e2e.yml              : k6, Playwright (strict TLS), Patrol, auto-quarantine
	  - dora-emit.yml        : emits lead time, deployment frequency, change failure rate, MTTR
	Maintainer: platform-team
	EOF
