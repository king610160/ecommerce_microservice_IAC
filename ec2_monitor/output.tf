output "frontend_public_ip" {
  description = "Jenkins/Grafana 伺服器的公網 IP"
  value       = aws_eip.frontend_eip.public_ip
}

output "backend_private_ip" {
  description = "監控伺服器的內網 IP"
  value       = aws_instance.backend.private_ip
}

# 為了讓 EKS 腳本方便，順便輸出所有 Subnet ID
output "subnet_ids" {
  value = {
    public_1  = aws_subnet.public.id
    public_2  = aws_subnet.public_2.id
    # public_3  = aws_subnet.public_3.id
    private_1 = aws_subnet.private.id
    private_2 = aws_subnet.private_2.id
    # private_3 = aws_subnet.private_3.id
  }
}

# 獲取當前 Region 的 Data Source (需在 main.tf 補上)
data "aws_region" "current" {}