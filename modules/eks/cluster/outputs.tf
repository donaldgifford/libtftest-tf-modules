output "cluster-autoscaler_arn" {
  value = aws_iam_role.eks_ca.arn
}

output "pod_cw_metrics_arn" {
  value = aws_iam_role.pod_cw_metrics.arn
}

output "pod_fluentd_logs_arn" {
  value = aws_iam_role.pod_fluentd_logs.arn
}

output "alb_role_arn" {
  value = aws_iam_role.alb_role.arn
}

output "external_dns_arn" {
  value = aws_iam_role.external_dns.arn
}
