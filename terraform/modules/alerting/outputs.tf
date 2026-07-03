output "alerts_topic_arn" {
  description = "SNS topic carrying budget alerts, anomalies, and weekly reports"
  value       = aws_sns_topic.alerts.arn
}

output "reporter_function" {
  description = "Invoke on demand with: aws lambda invoke --function-name <this> /dev/stdout"
  value       = aws_lambda_function.reporter.function_name
}
