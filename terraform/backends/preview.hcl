# ==============================================================================
# terraform/backends/preview.hcl
# Backend config for the `preview` workspace. Inject via:
#   terraform init -backend-config=backends/preview.hcl
#
# Every value is a placeholder. Replace before running `terraform init`.
# ==============================================================================

bucket         = "<YOUR_TFSTATE_BUCKET>"
key            = "<YOUR_REPO>/preview/terraform.tfstate"
region         = "<YOUR_AWS_REGION>"
dynamodb_table = "<YOUR_TFSTATE_LOCK_TABLE>"
encrypt        = true
kms_key_id     = "<YOUR_KMS_KEY_OR_ALIAS>"
