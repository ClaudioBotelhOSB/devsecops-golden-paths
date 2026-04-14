# Go Zero-Trust Golden Path

> A Go-first DevSecOps template that implements the Zero-Trust delivery
> platform described in `zero-trust-cicd-architecture.md`. Chart,
> infrastructure, tests, and policies are stack-agnostic; the CI pipeline
> itself assumes a Go backend. If your primary language is Node, Python,
> or anything else, see the [Stack split](#stack-split-if-you-are-not-on-go)
> section.

---

## Honest scope

This repository is an **opinionated starting point**, not a plug-and-play
universal template. It implements one specific reference architecture,
on one specific cloud vocabulary (AWS), against one specific runtime
ecosystem (Kubernetes + Istio + Argo Rollouts + Kyverno + Prometheus +
ingress-nginx + cert-manager). Everything else (Go backend, GHCR, Sonar,
Infracost, Slack, AIOps anomaly) is a concrete example of how to wire the
pattern together.

What is **genuinely reusable across stacks**:

- The Helm chart (`charts/backend-template`) - language-agnostic, driven
  entirely by `.Values` (container command, args, ports, probes, labels).
  Ships with pragmatic defaults (replicaCount 2, tag `latest`, one HTTP
  port, service enabled) that render something valid; each one is
  overridable.
- The k6 smoke + load suite and the Playwright suite - every endpoint,
  method, body, header, and threshold is env-driven.
- The Kyverno signed-image policy, the Argo Rollouts canary analysis, and
  the TTL reaper - all shipped as placeholder manifests you substitute
  with `envsubst` or a GitOps overlay.
- The FinOps contract (`.platform/budgets.yaml`, tag policy-as-code) -
  independent of the application language.

What is **still partially Go-HTTP-flavored** (honest):

- [k8s/rollouts/canary-rollout.yaml](k8s/rollouts/canary-rollout.yaml) ships an example container with two ports
  (HTTP + metrics) and two probe paths. The structure (Argo analysis
  templates, Istio traffic split, canary/stable services) is neutral,
  but the example pod spec assumes an HTTP backend. Replace the
  placeholder ports and probes to match your stack.
- [tests/patrol/integration_test/smoke_test.dart](tests/patrol/integration_test/smoke_test.dart) performs one real
  check (health endpoint HTTP GET). The Patrol framework is included so
  you can extend it with a real mobile-app flow; the shipped test is a
  starting point, not a production smoke.

What is **Go-specific** (will need forking for other stacks):

- [backend-ci.yml](.github/workflows/backend-ci.yml) - uses `go test`, `go vet`, `go mod`, `golangci-lint`, `gosec`, `go-junit-report`.
- [Dockerfile](Dockerfile) - builds `./cmd/${CMD}` with `CGO_ENABLED=0`.
- [cmd/api/main.go](cmd/api/main.go) and [cmd/ttl-reaper/main.go](cmd/ttl-reaper/main.go) - Go source scaffolds.
- [go.mod](go.mod), [go.sum](go.sum), [Makefile](Makefile) Go targets.

If you want Node/Python/JVM, see [Stack split](#stack-split-if-you-are-not-on-go).

---

## Platform prerequisites (read before you fork)

The pipeline will fail fast if any of the following is missing. None of
them are optional for the full end-to-end flow to work; you can remove
the workflows that depend on a missing piece instead.

### Cloud + identity
- **AWS account** with a GitHub OIDC provider trust configured.
- **IAM roles** (substitute `<OWNER>/<REPO>` into the trust policy `sub`):
  - `gh-actions-tf-plan-<env>`         (read-only, for `iac-pr.yml`)
  - `gh-actions-tf-apply-<env>`        (apply-scoped, for `iac-apply.yml`)
  - `gh-actions-tf-drift-<env>`        (read-only, for `iac-drift.yml`)
  - `gh-actions-preview-provisioner`   (EKS describe + namespace admin)
- **S3 bucket + DynamoDB lock table** for Terraform state (placeholders
  in [terraform/backends/*.hcl](terraform/backends/)).

### Kubernetes cluster
- A cluster you can reach with `aws eks update-kubeconfig` (or the
  equivalent for your provider - the workflows call that one command,
  swap it for yours in [preview-env.yml](.github/workflows/preview-env.yml) if you're on GKE/AKS/OKE/self-hosted).
- **Argo Rollouts** controller installed.
- **Kyverno** controller installed.
- **Istio** (or any mesh emitting `istio_requests_total` and
  `istio_request_duration_milliseconds_bucket`).
- **Prometheus** scraping the workloads, reachable at
  `http://prometheus.monitoring.svc.cluster.local:9090` (override in the
  Argo Rollouts AnalysisTemplates).
- **ingress-nginx** (or override `ingress.className` per service).
- **cert-manager** issuing TLS for preview hosts.

### External services
- **GHCR** (or any OCI registry that accepts the same OIDC identity).
- **SonarQube / SonarCloud** (PR + branch path).
- **Infracost** (API key).
- **Slack** (optional - for drift alerts).
- **AIOps anomaly service** (optional - deleting the `aiops-anomaly`
  AnalysisTemplate in [canary-rollout.yaml](k8s/rollouts/canary-rollout.yaml) is supported and expected).
- **DORA endpoint** (optional - [dora-emit.yml](.github/workflows/dora-emit.yml) degrades gracefully if
  `DORA_ENDPOINT` is unset).

---

## Single customization matrix

Everything below is documented in full detail at [.platform/config.yaml](.platform/config.yaml).
Skim the summary here, set the Variables in **Settings → Secrets and
variables → Actions → Variables**, then read that file for every knob.

### Day-0 actions (before any pipeline runs)

1. **Rename the Go module**. The template ships as `example.com/golden-path`
   in [go.mod](go.mod); run `go mod edit -module <your-module>` and `go mod tidy`.
   Update `goimports -local` consumers if your editor pins a prefix.
2. **Substitute the file-level placeholders** in the table below.
3. **Set the Actions Variables** in the next table. The defaults are
   intentionally obviously-wrong (`example.internal`, `golden-path-bot`)
   so a forgotten one fails loudly.
4. **Provision the platform prerequisites** listed earlier in this README.
5. **Decide on your OCI registry**. If it is GHCR, nothing else to do.
   If it is anything else (Quay, ECR, GAR, Harbor, self-hosted), set
   `OCI_REGISTRY` as a Variable AND `OCI_USERNAME` + `OCI_PASSWORD` as
   Secrets - `backend-ci.yml` branches on the registry host and uses
   those creds for non-GHCR registries.

### Repository Variables (public, not secrets)

| Variable | Default | Purpose |
|---|---|---|
| `PLATFORM_OWNER` | `${{ github.repository_owner }}` | Owner string used in labels/logs/DORA/SLSA |
| `PLATFORM_BOT_NAME` | `golden-path-bot` | Git author for automated PRs |
| `PLATFORM_BOT_EMAIL` | `golden-path-bot@example.invalid` | Git author email |
| `PLATFORM_EMAIL_DOMAIN` | `example.internal` | Domain for namespace owner annotations |
| `DEFAULT_REGION` | `us-east-1` | Terraform / AWS / EKS region |
| `PLATFORM_COST_CENTER` | `platform` | FinOps attribution tag |
| `OCI_REGISTRY` | `ghcr.io` | OCI registry host (any host other than `ghcr.io` triggers the non-GHCR login branch in backend-ci.yml) |
| `OCI_VENDOR` | `${{ github.repository_owner }}` | OCI label vendor |
| `OCI_AUTHORS` | `golden-path-bot@example.invalid` | OCI label authors |
| `PREVIEW_CLUSTER_NAME` | `preview-cluster` | Target K8s cluster for previews |
| `PREVIEW_BASE_DOMAIN` | `preview.example.internal` | Preview ingress base domain |
| `PREVIEW_INGRESS_CLASS` | `nginx` | Helm `--set ingress.className` during preview install |
| `PREVIEW_NETPOL_FILE` | `k8s/preview/networkpolicy.yaml` | envsubst-rendered overlay applied per preview namespace |
| `PREVIEW_INGRESS_NAMESPACE` | `ingress-nginx` | Substituted into the NetworkPolicy overlay |
| `PREVIEW_DNS_NAMESPACE` | `kube-system` | Substituted into the NetworkPolicy overlay |
| `PREVIEW_METADATA_CIDR_EXCLUDE` | `169.254.169.254/32` | Cloud metadata CIDR excluded from egress allow |
| `GITOPS_REPO` | `<owner>/platform-gitops` | Manifest repo for digest bumps |
| `GITOPS_PATH` | `apps/<repo>/staging/values.yaml` | Path inside GitOps repo |

### Secrets

| Secret | Required | Used by |
|---|---|---|
| `AWS_ACCOUNT_ID` | yes | iac-*, preview-env |
| `INFRACOST_API_KEY` | yes | iac-pr |
| `SONAR_TOKEN`, `SONAR_HOST_URL` | yes | backend-ci |
| `GITOPS_TOKEN` | yes | backend-ci (manifest bump) |
| `OCI_USERNAME`, `OCI_PASSWORD` | yes if `OCI_REGISTRY != ghcr.io` | backend-ci login to external registries |
| `SLACK_WEBHOOK_URL` | optional | iac-drift |
| `DORA_ENDPOINT` | optional | dora-emit |

### File-level placeholders you MUST substitute before applying

| File | Placeholders |
|---|---|
| [go.mod](go.mod) | `example.com/golden-path` → your real module path |
| [terraform/backends/preview.hcl](terraform/backends/preview.hcl), [staging.hcl](terraform/backends/staging.hcl) | `<YOUR_TFSTATE_BUCKET>`, `<YOUR_REPO>`, `<YOUR_AWS_REGION>`, `<YOUR_TFSTATE_LOCK_TABLE>`, `<YOUR_KMS_KEY_OR_ALIAS>` |
| [terraform/environments/preview.tfvars](terraform/environments/preview.tfvars), [staging.tfvars](terraform/environments/staging.tfvars) | `<YOUR_CLOUD_REGION>`, `<YOUR_SERVICE_NAME>`, `<YOUR_OWNER_EMAIL>`, `<YOUR_COST_CENTER>` |
| [k8s/rollouts/canary-rollout.yaml](k8s/rollouts/canary-rollout.yaml) | `<APP_NAME>`, `<APP_NAMESPACE>`, `<APP_OWNER>`, `<OCI_REGISTRY>`, `<OWNER>/<REPO>`, `<DIGEST>`, `<HTTP_PORT>`, `<METRICS_PORT>`, `<HEALTH_PATH>`, `<READINESS_PATH>` |
| [k8s/policies/require-signed-images.yaml](k8s/policies/require-signed-images.yaml) | `<OCI_REGISTRY>`, `<ALT_OCI_REGISTRY>`, `<OCI_NAMESPACE>`, `<OWNER>/<REPO>` |
| [k8s/controllers/ttl-reaper-deployment.yaml](k8s/controllers/ttl-reaper-deployment.yaml) | `<YOUR_PLATFORM_NAMESPACE>`, `<YOUR_PLATFORM_MANAGER>`, `<YOUR_OWNER>`, `<YOUR_OCI_REGISTRY>`, `<YOUR_ORG>`, `<YOUR_REPO>`, `<YOUR_DIGEST>` |
| [k8s/preview/networkpolicy.yaml](k8s/preview/networkpolicy.yaml) | `${PREVIEW_INGRESS_NAMESPACE}`, `${PREVIEW_DNS_NAMESPACE}`, `${PREVIEW_METADATA_CIDR_EXCLUDE}` (envsubst at apply time) |

---

## What ships in this repository

### Workflows (`.github/workflows/`)

| File | Stage | Purpose |
|---|---|---|
| [secret-scan.yml](.github/workflows/secret-scan.yml) | Phase A (server) | Server-side gitleaks on PR/push/merge-group/nightly. Fail-closed install. |
| [iac-pr.yml](.github/workflows/iac-pr.yml) | Stage 0 | IaC plan + `cosign sign-blob` + Infracost FinOps contract + plan-JSON tag policy + cost-center allowlist. |
| [iac-apply.yml](.github/workflows/iac-apply.yml) | Stage 0 | Correlates merge commit → PR → head SHA, downloads signed plan, verifies, applies. |
| [iac-drift.yml](.github/workflows/iac-drift.yml) | Stage 0 | Scheduled `terraform plan -detailed-exitcode` every 6h with incident + Slack alert. |
| [backend-ci.yml](.github/workflows/backend-ci.yml) | Phase B/C | **Go-specific**. Matrix build of every `cmd/<app>`. Blocking gosec + Trivy fs/image, SPDX + CycloneDX SBOMs, SLSA v1 provenance, Cosign keyless sign, local verification of image signature + both attestations before GitOps bump. |
| [preview-env.yml](.github/workflows/preview-env.yml) | Phase C | Provisions `pr-<N>` namespace with TTL + NetworkPolicy; downloads the signed digest, `cosign verify`s it, `helm upgrade --install`. Teardown on PR close. |
| [e2e.yml](.github/workflows/e2e.yml) | Phase C | k6 (env-driven) + Playwright Chromium (strict TLS) + Patrol (Flutter) + nightly auto-quarantine rebuild. |
| [dora-emit.yml](.github/workflows/dora-emit.yml) | Platform | Emits lead time, deployment frequency, change failure rate, MTTR. |

### Chart (`charts/backend-template`)

Stack-agnostic by design: the chart makes no assumption about language,
framework, container command/args, or probe paths. It ships a handful of
pragmatic defaults (`replicaCount=2`, `image.tag=latest`, a single HTTP
port, service enabled) so that `helm template` renders something valid
out of the box - each one is individually overridable in your overlay.
See [values.yaml](charts/backend-template/values.yaml) for the full schema.

### Go binaries (`cmd/`)

| Path | Purpose |
|---|---|
| [cmd/api/main.go](cmd/api/main.go) | Primary backend scaffold. HTTP `/healthz`, `/readyz`, `/v1/nodes`, Prometheus `/metrics`. `SERVICE_NAME` + `PLATFORM_OWNER` env vars. |
| [cmd/ttl-reaper/main.go](cmd/ttl-reaper/main.go) | Preview-namespace reaper controller. |

### Terraform (`terraform/`)

Minimal AWS S3 + IRSA scaffold so the IaC pipeline is plannable out of
the box. Every value is a placeholder or a required variable - no
defaults bleed the template author's region, cost center, or owner into
your stack.

### Kubernetes manifests (`k8s/`)

| Path | Purpose |
|---|---|
| [k8s/policies/require-signed-images.yaml](k8s/policies/require-signed-images.yaml) | Kyverno ClusterPolicy (signed + SPDX + SLSA + digest-pin + runtime-hardening over containers/initContainers/ephemeralContainers). |
| [k8s/rollouts/canary-rollout.yaml](k8s/rollouts/canary-rollout.yaml) | Argo Rollouts canary with baseline-relative Istio metrics. |
| [k8s/controllers/ttl-reaper-deployment.yaml](k8s/controllers/ttl-reaper-deployment.yaml) | Deployment + RBAC for the reaper. |
| [k8s/testdata/](k8s/testdata/) | Sample pods consumed by `make policy-test`. |

### Tests (`tests/`)

| Path | Purpose |
|---|---|
| [tests/k6/](tests/k6/) | Env-driven HTTP smoke + ramped load. |
| [tests/e2e/](tests/e2e/) | Playwright Chromium, strict TLS in CI, every endpoint via env. |
| [tests/patrol/](tests/patrol/) | Optional Flutter integration smoke (env-driven base URL and health path). |
| [tests/quarantine/quarantine.json](tests/quarantine/quarantine.json) | Auto-regenerated nightly by the e2e workflow. |

---

## Stack split (if you are not on Go)

The QA report that drove this refactor raised the obvious question: a
**genuinely universal** template would split Phase B per stack flavor.
That split is NOT implemented here. If your service is not Go:

1. Fork [backend-ci.yml](.github/workflows/backend-ci.yml) into `backend-ci-<stack>.yml` (e.g.
   `backend-ci-node.yml`). Replace the Go-specific steps (`go test`,
   `go vet`, `golangci-lint`, `gosec`) with the equivalent for your stack
   (`npm test`, `eslint`, `semgrep`, etc.).
2. Fork [Dockerfile](Dockerfile) into `Dockerfile.<stack>`. Replace the Go build
   stage with your own.
3. Keep every other layer intact: the chart, the Argo Rollouts manifest,
   the Kyverno policy, the Terraform, the k6/Playwright/Patrol tests, the
   DORA emitter, the preview env workflow, the signed-plan chain - none
   of those care what language you use.
4. Update the `build-sign` matrix to reference your new Dockerfile.

Alternatively, if you want a **drop-in Node or Python flavor shipped in
this repo**, open an issue describing the stack and the specific language
constraints. A multi-stack fork is ~150 lines of YAML per additional
flavor.

---

## How the signed-plan chain works

```
[PR open]
   └── iac-pr.yml
         ├── terraform plan -out=tfplan.binary
         ├── cosign sign-blob tfplan.binary   (keyless, OIDC identity)
         ├── Infracost + FinOps gate + tag policy (plan JSON) + allowlist
         └── upload-artifact: tfplan-<env>-<pull_request.head.sha>

[PR merged -> push to main]
   └── iac-apply.yml
         ├── gh api commits/<merge_sha>/pulls            # resolve PR
         ├── gh api pulls/<pr>           --jq .head.sha  # resolve head sha
         ├── gh run download <iac-pr run> --name tfplan-<env>-<head_sha>
         ├── cosign verify-blob  (same identity regex as signer)
         ├── sha256 checksum match
         └── terraform apply tfplan.binary
```

## How the signed-image chain works

```
[push main]
   └── backend-ci.yml: build-sign matrix
         ├── docker buildx build --provenance=mode=max --sbom=true
         ├── syft -> sbom.spdx.json + sbom.cdx.json
         ├── cosign sign        <image@digest>
         ├── cosign attest spdx <image@digest>
         ├── cosign attest cdx  <image@digest>
         ├── cosign attest slsa <image@digest>
         ├── cosign verify              (locally, before handoff)
         ├── cosign verify-attestation  spdxjson
         ├── cosign verify-attestation  slsaprovenance
         └── upload digest pointer artifact (consumed by preview + gitops)

[kubectl apply]
   └── Kyverno require-signed-images
         ├── verify-signatures-and-attestations
         │     ├── keyless subject ^<OWNER>/<REPO>/backend-ci.yml@.*$
         │     ├── SPDX predicate non-empty, packages > 0
         │     └── SLSA buildType + entryPoint match
         ├── deny-untrusted-registries  (containers + initContainers + ephemeralContainers)
         ├── require-image-digest       (prod-* + staging-*)
         └── require-runtime-hardening  (all container types)
```

---

## Local development

```bash
make sync              # regenerate go.sum
make ci                # lint + vet + test + build + chart-lint
make precommit         # run pre-commit hooks on the tree
make policy-test       # kyverno dry-run against k8s/testdata/
make chart-lint        # helm lint + render with placeholder values
```

The Makefile derives `REPO_OWNER`, `REPO_NAME`, `GO_MODULE`, and
`PREVIEW_BASE_DOMAIN` from the local git remote, `go.mod`, and sensible
defaults. Override any of them via `make VAR=value target`.

---

## Repository layout

```
.
├── .github/workflows/           # secret-scan, iac-{pr,apply,drift}, backend-ci, preview-env, e2e, dora-emit
├── .platform/
│   ├── budgets.yaml             # FinOps policy (mandatory_tags + cost_center_allowlist)
│   └── config.yaml              # Single customization matrix (this file's index)
├── .pre-commit-config.yaml
├── .checkov.yaml / .tflint.hcl / .yamllint.yaml
├── Makefile
├── Dockerfile                   # Go builder; fork for other stacks
├── go.mod / go.sum
├── cmd/
│   ├── api/main.go
│   └── ttl-reaper/main.go
├── charts/
│   └── backend-template/        # stack-agnostic, .Chart.Name-rooted
├── k8s/
│   ├── controllers/ttl-reaper-deployment.yaml
│   ├── policies/require-signed-images.yaml
│   ├── rollouts/canary-rollout.yaml
│   └── testdata/
├── terraform/                   # AWS S3 + IRSA scaffold, every value is a placeholder
└── tests/
    ├── k6/         # env-driven
    ├── e2e/        # env-driven Playwright
    ├── patrol/     # env-driven Flutter
    └── quarantine/
```

---

## License & ownership

Internal platform template. Maintain it by owning your fork: every value
you see hardcoded is a bug, file an issue and send a PR.
