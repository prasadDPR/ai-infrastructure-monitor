# SNS topic for email notifications
resource "aws_sns_topic" "alerts" {
  name = "healthcare-monitor-alerts"
}

resource "aws_sns_topic_subscription" "email" {
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

# IAM role for Lambda
resource "aws_iam_role" "lambda" {
  name = "healthcare-ai-pipeline-role"
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
  name = "healthcare-ai-pipeline-policy"
  role = aws_iam_role.lambda.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "bedrock:InvokeModel",
          "bedrock:InvokeModelWithResponseStream"
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "sns:Publish"
        ]
        Resource = aws_sns_topic.alerts.arn
      },
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "arn:aws:logs:*:*:*"
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

# Lambda function
resource "aws_lambda_function" "ai_pipeline" {
  filename         = data.archive_file.lambda.output_path
  function_name    = "healthcare-ai-pipeline"
  role             = aws_iam_role.lambda.arn
  handler          = "ai_pipeline.lambda_handler"
  runtime          = "python3.11"
  timeout          = 60
  source_code_hash = data.archive_file.lambda.output_base64sha256

  environment {
    variables = {
      SNS_TOPIC_ARN = aws_sns_topic.alerts.arn
    }
  }
}

# Lambda function URL so Alertmanager can call it
resource "aws_lambda_function_url" "ai_pipeline" {
  function_name      = aws_lambda_function.ai_pipeline.function_name
  authorization_type = "NONE"
}