terraform {
  required_version = ">= 1.6.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.4"
    }
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = "GRC-Evidence-Vault"
      ManagedBy   = "Terraform"
      Environment = var.environment
      DataClass   = "Compliance-Evidence"
    }
  }
}

variable "aws_region" {
  type        = string
  description = "AWS region used for the evidence collector."
  default     = "us-east-1"
}

variable "environment" {
  type        = string
  description = "Environment label embedded in evidence and resource tags."
  default     = "Dev"
}

variable "object_lock_mode" {
  type        = string
  description = "GOVERNANCE for test/dev. COMPLIANCE is intended for approved production retention."
  default     = "GOVERNANCE"

  validation {
    condition     = contains(["GOVERNANCE", "COMPLIANCE"], var.object_lock_mode)
    error_message = "object_lock_mode must be GOVERNANCE or COMPLIANCE."
  }
}

variable "retention_days" {
  type        = number
  description = "Default Object Lock retention period. Keep short in disposable test environments and set the approved period in production."
  default     = 7

  validation {
    condition     = var.retention_days >= 1 && floor(var.retention_days) == var.retention_days
    error_message = "retention_days must be a positive whole number."
  }
}

variable "schedule_expression" {
  type        = string
  description = "EventBridge schedule for evidence collection."
  default     = "cron(0 0 * * ? *)"
}

resource "random_string" "suffix" {
  length  = 8
  special = false
  upper   = false
}

resource "aws_s3_bucket" "evidence_vault" {
  bucket              = "grc-evidence-vault-worm-${random_string.suffix.result}"
  object_lock_enabled = true
  force_destroy       = false
}

resource "aws_s3_bucket_versioning" "vault_versioning" {
  bucket = aws_s3_bucket.evidence_vault.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_object_lock_configuration" "vault_lock" {
  bucket              = aws_s3_bucket.evidence_vault.id
  object_lock_enabled = "Enabled"

  rule {
    default_retention {
      mode = var.object_lock_mode
      days = var.retention_days
    }
  }

  depends_on = [aws_s3_bucket_versioning.vault_versioning]
}

resource "aws_s3_bucket_server_side_encryption_configuration" "vault_crypto" {
  bucket = aws_s3_bucket.evidence_vault.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "vault" {
  bucket = aws_s3_bucket.evidence_vault.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

data "aws_iam_policy_document" "vault_policy" {
  statement {
    sid    = "DenyInsecureTransport"
    effect = "Deny"

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    actions = ["s3:*"]
    resources = [
      aws_s3_bucket.evidence_vault.arn,
      "${aws_s3_bucket.evidence_vault.arn}/*"
    ]

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "vault" {
  bucket = aws_s3_bucket.evidence_vault.id
  policy = data.aws_iam_policy_document.vault_policy.json
}

resource "aws_iam_role" "lambda_role" {
  name = "grc-evidence-collector-role-${random_string.suffix.result}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })
}

data "aws_iam_policy_document" "lambda" {
  statement {
    sid       = "ReadConfigCompliance"
    effect    = "Allow"
    actions   = ["config:GetComplianceSummaryByResourceType"]
    resources = ["*"]
  }

  statement {
    sid       = "ReadAccountIdentity"
    effect    = "Allow"
    actions   = ["sts:GetCallerIdentity"]
    resources = ["*"]
  }

  statement {
    sid       = "WriteEvidenceOnly"
    effect    = "Allow"
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.evidence_vault.arn}/*"]
  }
}

resource "aws_iam_policy" "lambda_policy" {
  name   = "grc-evidence-collector-policy-${random_string.suffix.result}"
  policy = data.aws_iam_policy_document.lambda.json
}

resource "aws_iam_role_policy_attachment" "collector_policy" {
  role       = aws_iam_role.lambda_role.name
  policy_arn = aws_iam_policy.lambda_policy.arn
}

resource "aws_iam_role_policy_attachment" "basic_execution" {
  role       = aws_iam_role.lambda_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

data "archive_file" "collector_zip" {
  type        = "zip"
  source_file = "${path.module}/collector.py"
  output_path = "${path.module}/collector.zip"
}

resource "aws_lambda_function" "collector" {
  function_name    = "grc-evidence-collector-${random_string.suffix.result}"
  description      = "Collects AWS Config compliance evidence into an Object Lock protected S3 vault."
  role             = aws_iam_role.lambda_role.arn
  handler          = "collector.lambda_handler"
  runtime          = "python3.12"
  architectures    = ["arm64"]
  timeout          = 30
  memory_size      = 128
  filename         = data.archive_file.collector_zip.output_path
  source_code_hash = data.archive_file.collector_zip.output_base64sha256

  environment {
    variables = {
      EVIDENCE_VAULT_NAME = aws_s3_bucket.evidence_vault.bucket
      ENVIRONMENT         = var.environment
      RESOURCE_TYPE       = "AWS::S3::Bucket"
    }
  }

  depends_on = [
    aws_iam_role_policy_attachment.collector_policy,
    aws_iam_role_policy_attachment.basic_execution,
    aws_s3_bucket_object_lock_configuration.vault_lock,
    aws_s3_bucket_server_side_encryption_configuration.vault_crypto,
    aws_s3_bucket_public_access_block.vault
  ]
}

resource "aws_cloudwatch_log_group" "collector" {
  name              = "/aws/lambda/${aws_lambda_function.collector.function_name}"
  retention_in_days = 90
}

resource "aws_cloudwatch_event_rule" "daily_trigger" {
  name                = "grc-daily-evidence-collection-${random_string.suffix.result}"
  description         = "Scheduled GRC evidence collection."
  schedule_expression = var.schedule_expression
}

resource "aws_cloudwatch_event_target" "trigger_lambda" {
  rule      = aws_cloudwatch_event_rule.daily_trigger.name
  target_id = "TriggerGRCLambda"
  arn       = aws_lambda_function.collector.arn
}

resource "aws_lambda_permission" "allow_eventbridge" {
  statement_id  = "AllowExecutionFromEventBridge"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.collector.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.daily_trigger.arn
}

resource "aws_cloudwatch_metric_alarm" "collector_errors" {
  alarm_name          = "grc-evidence-collector-errors-${random_string.suffix.result}"
  alarm_description   = "Alerts when the evidence collector Lambda records an error."
  namespace           = "AWS/Lambda"
  metric_name         = "Errors"
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"

  dimensions = {
    FunctionName = aws_lambda_function.collector.function_name
  }
}

output "evidence_vault_name" {
  description = "Name of the immutable evidence S3 bucket."
  value       = aws_s3_bucket.evidence_vault.bucket
}

output "collector_function_name" {
  description = "Lambda function that collects evidence."
  value       = aws_lambda_function.collector.function_name
}

output "object_lock_mode" {
  description = "Configured Object Lock retention mode."
  value       = var.object_lock_mode
}

output "retention_days" {
  description = "Configured default retention period in days."
  value       = var.retention_days
}
