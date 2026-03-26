# --- OUTPUTS ---
output "update_kubeconfig_command" {
  description = "指令：更新本地 kubectl context"
  value       = "aws eks update-kubeconfig --region <area> --name ${aws_eks_cluster.main.name}"
}

output "rds_endpoint" {
  description = "RDS 連線地址"
  value       = aws_db_instance.mysql.endpoint
}