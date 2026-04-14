// ============================================================================
// terraform/main.tf
//
// Root stack - kept intentionally small. Its only purpose is to give the
// golden path a real, plannable stack so the end-to-end IaC pipeline
// (plan -> sign -> apply -> drift) can be exercised from day one.
//
// The example cloud is AWS, but EVERY provider-specific resource below is
// an illustration: swap it out for your own provider block and resources
// once you fork this template. The structure of the pipeline - signed
// plan, mandatory tag block, FinOps policy-as-code against plan JSON - is
// what the golden path cares about, not the specific resources.
// ============================================================================

provider "aws" {
  region = var.region

  default_tags {
    tags = local.mandatory_tags
  }
}

locals {
  mandatory_tags = {
    cost_center = var.cost_center
    owner_email = var.owner_email
    environment = var.environment
    service     = var.service
    managed_by  = "terraform"
  }

  bucket_name = format(
    "%s-%s-artifacts%s",
    var.service,
    var.environment,
    var.bucket_suffix != "" ? "-${var.bucket_suffix}" : "",
  )
}

// ---------------------------------------------------------------------------
// S3 bucket: application artifacts
// ---------------------------------------------------------------------------

resource "random_id" "suffix" {
  byte_length = 4
  keepers = {
    env = var.environment
  }
}

resource "aws_s3_bucket" "artifacts" {
  bucket = "${local.bucket_name}-${random_id.suffix.hex}"

  tags = merge(local.mandatory_tags, {
    component = "artifacts"
    ttl       = var.ttl
  })
}

resource "aws_s3_bucket_versioning" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_public_access_block" "artifacts" {
  bucket                  = aws_s3_bucket.artifacts.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "aws:kms"
    }
    bucket_key_enabled = true
  }
}

// ---------------------------------------------------------------------------
// IAM: application role (assumable by EKS service account via IRSA)
// ---------------------------------------------------------------------------

data "aws_caller_identity" "current" {}

resource "aws_iam_role" "app" {
  name = "${var.service}-${var.environment}-app"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = { Service = "pods.eks.amazonaws.com" }
        Action    = "sts:AssumeRole"
      },
    ]
  })

  tags = merge(local.mandatory_tags, {
    component = "app-role"
  })
}

resource "aws_iam_role_policy" "app_artifacts" {
  name = "${var.service}-${var.environment}-app-artifacts"
  role = aws_iam_role.app.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:PutObject", "s3:ListBucket"]
        Resource = [
          aws_s3_bucket.artifacts.arn,
          "${aws_s3_bucket.artifacts.arn}/*",
        ]
      },
    ]
  })
}
