# 建立 Secret 實體
resource "aws_secretsmanager_secret" "ecommerce" {
  name        = "ecommerce/prod/secrets"
  description = "ecommerce專案env"
  recovery_window_in_days = 0 # 關鍵：設定為 0 代表直接刪除，不留 7 天回收期
}

# 建立 Secret 的內容 (以 JSON 格式儲存)
resource "aws_secretsmanager_secret_version" "app_secrets_val" {
  secret_id     = aws_secretsmanager_secret.ecommerce.id
  secret_string = jsonencode({
    DB_HOST     = "terraform-2026032405415616360000000b.cdus0g8g2xlr.<area>.rds.amazonaws.com"
    DB_USER     = "ecommerce"
    DB_PASS     = "ecommerce"
    DB_NAME     = "ecommerce"
    repository  = "prod-ecommerce/auth-service"
    registry    = "<user>.dkr.ecr.<area>.amazonaws.com"
    ACCOUNT_ID  = "<user>"
    AWS_REGION  = "<area>"
  })
}