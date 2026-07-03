output "table_name" {
  description = "DynamoDB table the dashboard reads"
  value       = aws_dynamodb_table.data.name
}

output "table_arn" {
  value = aws_dynamodb_table.data.arn
}

output "function_names" {
  description = "Invoke on demand with: aws lambda invoke --function-name <name> /dev/stdout"
  value       = [for f in aws_lambda_function.collector : f.function_name]
}
