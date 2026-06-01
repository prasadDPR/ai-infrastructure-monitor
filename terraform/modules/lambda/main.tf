# SQS Dead Letter Queue for Lambda
resource "aws_sqs_queue" "lambda_dlq" {
  name                      = "ai-infrastructure-pipeline-dlq"
  message_retention_seconds = 86400
  kms_master_key_id         = aws_kms_key.lambda.id
}

# KMS key for Lambda
resource "aws_kms_key" "lambda" {
  description             = "KMS key for Lambda environment variables"
  deletion_window_in_days = 7
  enable_key_rotation     = true
}

# KMS key for SNS
resource "aws_kms_key" "sns" {
  description             = "KMS key for SNS topic encryption"
  deletion_window_in_days = 7
  enable_key_rotation     = true
}

# SNS topic with encryption
resource "aws_sns_topic" "alerts" {
  name              = "ai-infrastructure-monitor-alerts"
  kms_master_key_id = aws_kms_key.sns.arn
}

resource "aws_sns_topic_subscription" "email" {
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

# IAM role for Lambda
resource "aws_iam_role" "lambda" {
  name = "ai-infrastructure-pipeline-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy" "lambda" {
  name = "ai-infrastructure-pipeline-policy"
  role = aws_iam_role.lambda.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "bedrock:InvokeModel",
          "bedrock:InvokeModelWithResponseStream",
          "aws-marketplace:ViewSubscriptions",
          "aws-marketplace:Subscribe",
          "aws-marketplace:Unsubscribe"
        ]
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = ["sns:Publish"]
        Resource = aws_sns_topic.alerts.arn
      },
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "arn:aws:logs:eu-west-2:${data.aws_caller_identity.current.account_id}:log-group:/aws/lambda/ai-infrastructure-pipeline:*"
      },
      {
        Effect   = "Allow"
        Action   = ["sqs:SendMessage"]
        Resource = aws_sqs_queue.lambda_dlq.arn
      },
      {
        Effect = "Allow"
        Action = [
          "kms:Decrypt",
          "kms:GenerateDataKey"
        ]
        Resource = aws_kms_key.lambda.arn
      },
      {
        Effect = "Allow"
        Action = [
          "ec2:CreateNetworkInterface",
          "ec2:DescribeNetworkInterfaces",
          "ec2:DeleteNetworkInterface",
          "ec2:AssignPrivateIpAddresses",
          "ec2:UnassignPrivateIpAddresses"
        ]
        Resource = "*"
      }
    ]
  })
}

# Package Lambda code
data "archive_file" "lambda" {
  type        = "zip"
  source_file = "${path.module}/../../../lambda/ai_pipeline.py"
  output_path = "${path.module}/lambda_function.zip"
}

data "aws_caller_identity" "current" {}

# Lambda function with all security best practices
resource "aws_lambda_function" "ai_pipeline" {
  filename         = data.archive_file.lambda.output_path
  function_name    = "ai-infrastructure-pipeline"
  role             = aws_iam_role.lambda.arn
  handler          = "ai_pipeline.lambda_handler"
  runtime          = "python3.11"
  timeout          = 60
  source_code_hash = data.archive_file.lambda.output_base64sha256

  reserved_concurrent_executions = -1

  kms_key_arn = aws_kms_key.lambda.arn

  dead_letter_config {
    target_arn = aws_sqs_queue.lambda_dlq.arn
  }

  tracing_config {
    mode = "Active"
  }

  vpc_config {
    subnet_ids         = var.private_subnet_ids
    security_group_ids = [aws_security_group.lambda.id]
  }

  environment {
    variables = {
      SNS_TOPIC_ARN = aws_sns_topic.alerts.arn
    }
  }
  depends_on = [
    aws_iam_role_policy.lambda,
    aws_iam_role.lambda
  ]
}

# Security group for Lambda
resource "aws_security_group" "lambda" {
  name        = "ai-infrastructure-lambda-sg"
  description = "Security group for AI pipeline Lambda"
  vpc_id      = var.vpc_id

  egress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "Allow HTTPS outbound for Bedrock and SNS"
  }
}

# Lambda function URL
resource "aws_lambda_function_url" "ai_pipeline" {
  function_name      = aws_lambda_function.ai_pipeline.function_name
  authorization_type = "NONE"
}