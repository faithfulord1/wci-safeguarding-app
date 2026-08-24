terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

variable "aws_region" {
  type    = string
  default = "us-east-1"
}

# 1. Immutable S3 WORM Vault
resource "aws_s3_bucket" "evidence_vault" {
  bucket        = "grc-evidence-vault-worm-${random_string.suffix.result}"
  force_destroy = false
}

resource "random_string" "suffix" {
  length  = 6
  special = false
  upper   = false
}

resource "aws_s3_bucket_versioning" "vault_versioning" {
  bucket = aws_s3_bucket.evidence_vault.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_object_lock_configuration" "vault_lock" {
  bucket = aws_s3_bucket.evidence_vault.id
  rule {
    default_retention {
      mode  = "COMPLIANCE"
      years = 7
    }
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "vault_crypto" {
  bucket = aws_s3_bucket.evidence_vault.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# 2. IAM Role for Evidence Collector Lambda
resource "aws_iam_role" "lambda_role" {
  name = "grc_evidence_collector_role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })
}

resource "aws_iam_policy" "lambda_policy" {
  name = "grc_evidence_collector_policy"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["config:GetComplianceSummaryByResourceType", "config:GetComplianceDetailsByResource"]
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = ["s3:PutObject", "s3:PutObjectLegalHold"]
        Resource = "${aws_s3_bucket.evidence_vault.arn}/*"
      },
      {
        Effect   = "Allow"
        Action   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "*"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "attach_policy" {
  role       = aws_iam_role.lambda_role.name
  policy_arn = aws_iam_policy.lambda_policy.arn
}

# 3. Bundle collector.py into a ZIP deployment package for Lambda
data "archive_file" "collector_zip" {
  type        = "zip"
  source_file = "${path.module}/collector.py"
  output_path = "${path.module}/collector.zip"
}

# 4. Evidence Collector Lambda Function
resource "aws_lambda_function" "collector" {
  function_name    = "grc-evidence-collector"
  role             = aws_iam_role.lambda_role.arn
  handler          = "collector.lambda_handler"
  runtime          = "python3.12"
  timeout          = 30
  filename         = data.archive_file.collector_zip.output_path
  source_code_hash = data.archive_file.collector_zip.output_base64sha256

  environment {
    variables = {
      EVIDENCE_VAULT_NAME = aws_s3_bucket.evidence_vault.bucket
      ENVIRONMENT         = "Production"
    }
  }

  depends_on = [aws_iam_role_policy_attachment.attach_policy]
}

# 5. Scheduled EventBridge Trigger (Daily at Midnight UTC)
resource "aws_cloudwatch_event_rule" "daily_trigger" {
  name                = "grc-daily-evidence-collection"
  schedule_expression = "cron(0 0 * * ? *)"
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
