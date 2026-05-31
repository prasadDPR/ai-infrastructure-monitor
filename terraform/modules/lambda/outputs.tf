output "lambda_function_url" {
  value = aws_lambda_function_url.ai_pipeline.function_url
}

output "sns_topic_arn" {
  value = aws_sns_topic.alerts.arn
}