# ==============================================================================
# terraform/backends/staging.hcl
# ==============================================================================

bucket         = "<YOUR_TFSTATE_BUCKET>"
key            = "<YOUR_REPO>/staging/terraform.tfstate"
region         = "<YOUR_AWS_REGION>"
dynamodb_table = "<YOUR_TFSTATE_LOCK_TABLE>"
encrypt        = true
kms_key_id     = "<YOUR_KMS_KEY_OR_ALIAS>"
