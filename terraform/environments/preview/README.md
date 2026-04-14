# Preview environment

Per-environment overlay directory. The root Terraform stack lives in
[terraform/main.tf](../../main.tf); values come from
[../preview.tfvars](../preview.tfvars); backend config from
[../../backends/preview.hcl](../../backends/preview.hcl).

Drop any preview-only resources you want isolated from the root stack in this
directory (e.g. a `main.tf` that only creates preview-namespaced Kubernetes
objects, or extra AWS permissions).

Owner: platform engineering.
