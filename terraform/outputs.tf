// ============================================================================
// terraform/outputs.tf
// Owner: platform engineering
// ============================================================================

output "artifacts_bucket" {
  description = "Name of the S3 bucket used for application artifacts."
  value       = aws_s3_bucket.artifacts.bucket
}

output "artifacts_bucket_arn" {
  description = "ARN of the artifacts bucket."
  value       = aws_s3_bucket.artifacts.arn
}

output "app_role_arn" {
  description = "ARN of the application IAM role for IRSA."
  value       = aws_iam_role.app.arn
}

output "environment" {
  description = "Resolved environment name (echo)."
  value       = var.environment
}
