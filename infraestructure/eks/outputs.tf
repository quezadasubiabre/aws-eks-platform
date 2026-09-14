output "lbc_role_arn" {
  description = "IAM role ARN for the aws-load-balancer-controller ServiceAccount (IRSA)"
  value       = aws_iam_role.lbc.arn
}
