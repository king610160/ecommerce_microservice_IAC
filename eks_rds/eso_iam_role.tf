# --- 1. 定義給 ESO 用的 IAM Role ---
resource "aws_iam_role" "eso_role" {
  name = "${aws_eks_cluster.main.name}-eso-irsa-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRoleWithWebIdentity"
      Effect = "Allow"
      Principal = {
        # 這裡引用你 main.tf 建立好的 OIDC Provider ARN
        Federated = aws_iam_openid_connect_provider.eks.arn
      }
      Condition = {
        StringEquals = {
          # Namespace 從 external-secrets 改為 default
          "${replace(aws_iam_openid_connect_provider.eks.url, "https://", "")}:sub": "system:serviceaccount:default:eso-sa"
        }
      }
    }]
  })
}

# --- 2. 建立讀取 Secrets Manager 的 Policy ---
resource "aws_iam_policy" "eso_secrets_policy" {
  name        = "${aws_eks_cluster.main.name}-ESO-SecretsRead"
  description = "Allow External Secrets Operator to read secrets from Secrets Manager"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = [
          "secretsmanager:GetSecretValue",
          "secretsmanager:DescribeSecret"
        ]
        Effect   = "Allow"
        Resource = "*" # 業界建議：正式環境應限縮至特定的 Secret ARN
      }
    ]
  })
}

# --- 3. 綁定 Policy 到 Role ---
resource "aws_iam_role_policy_attachment" "eso_attach" {
  policy_arn = aws_iam_policy.eso_secrets_policy.arn
  role       = aws_iam_role.eso_role.name
}

# --- 4. 透過 Helm 部署 ESO 並自動建立 SA ---
resource "helm_release" "external_secrets" {
  name             = "external-secrets"
  repository       = "https://charts.external-secrets.io"
  chart            = "external-secrets"
  namespace        = "default"
  create_namespace = true

  # --- 新增以下設定 ---
  cleanup_on_fail  = true    # 如果失敗了，自動清理殘骸，方便下次重試
  atomic           = true    # 確保安裝是原子性的，要嘛全過要嘛全退回
  timeout          = 600     # 有時候抓 Image 比較慢，拉長到 10 分鐘
  # ------------------

  # 關鍵設定：建立 ServiceAccount 並加上 IRSA Annotation
  set {
    name  = "serviceAccount.create"
    value = "true"
  }

  set {
    name  = "serviceAccount.name"
    value = "eso-sa"
  }

  set {
    name  = "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
    value = aws_iam_role.eso_role.arn
  }

  # 安裝時建議一併安裝 CRDs
  set {
    name  = "installCRDs"
    value = "true"
  }

  depends_on = [
    aws_eks_addon.addons, 
    helm_release.lb_controller
  ]
}