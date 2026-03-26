# Base Infrastructure: VPC & EKS Cluster
# 固定版本
terraform {
  required_providers {
    aws = {
      source = "hashicorp/aws"
      version = "~> 5.0"
    }
    # 加入這兩個，確保版本是 2.x 以上
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.10"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.0"
    }
  }
}

provider "aws" {
  region = "<area>" 
}

provider "kubernetes" {
  host                   = aws_eks_cluster.main.endpoint
  cluster_ca_certificate = base64decode(aws_eks_cluster.main.certificate_authority[0].data)
  
  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    args        = ["eks", "get-token", "--cluster-name", aws_eks_cluster.main.name]
    command     = "aws"
  }
}

provider "helm" {
  kubernetes {
    host                   = aws_eks_cluster.main.endpoint
    cluster_ca_certificate = base64decode(aws_eks_cluster.main.certificate_authority[0].data)
    
    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      args        = ["eks", "get-token", "--cluster-name", aws_eks_cluster.main.name]
      command     = "aws"
    }
  }
}



# 0. 下載官方建議的 Policy (AWS LB controller)
data "http" "iam_policy" {
  url = "https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/v2.5.4/docs/install/iam_policy.json"
}

# 1. 抓取現有的 VPC 與 Subnet 資訊
data "aws_vpc" "selected" {
  filter {
    name   = "tag:Name"
    values = ["cicd-monitor-vpc"]
  }
}

data "aws_subnet" "public" {
  filter {
    name   = "tag:Name"
    values = ["public-subnet-frontend"]
  }
}

data "aws_subnet" "public_2" {
  filter {
    name   = "tag:Name"
    values = ["public-subnet-2"]
  }
}

data "aws_subnet" "private" {
  filter {
    name   = "tag:Name"
    values = ["private-subnet-backend"]
  }
}

data "aws_subnet" "private_2" {
  filter {
    name   = "tag:Name"
    values = ["private-subnet-2"]
  }
}

# 1.5 建立 AWS LB controller 的 IAM
resource "aws_iam_policy" "load_balancer_controller" {
  name   = "AWSLoadBalancerControllerIAMPolicy"
  path        = "/"
  description = "IAM policy for the AWS Load Balancer Controller on EKS"
  # 直接讀取剛下載的 json 檔案
  policy      = file("${path.module}/iam_policy.json")
}

# A. 建立給 LB Controller 用的 IAM Role
resource "aws_iam_role" "lb_controller_role" {
  name = "eks-lb-controller-role"

  # 這裡定義「誰可以穿這套衣服 (Assume Role)」
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRoleWithWebIdentity"
        Effect = "Allow"
        Principal = {
          # 指向你之前建好的 OIDC Provider
          Federated = aws_iam_openid_connect_provider.eks.arn
        }
        Condition = {
          StringEquals = {
            # 限制：只有 kube-system 命名空間下的 aws-load-balancer-controller 帳號可以用
            "${replace(aws_iam_openid_connect_provider.eks.url, "https://", "")}:sub" : "system:serviceaccount:kube-system:aws-load-balancer-controller",
            "${replace(aws_iam_openid_connect_provider.eks.url, "https://", "")}:aud" : "sts.amazonaws.com"
          }
        }
      }
    ]
  })
}

# B. 將你的 Policy 掛載到這個 Role 上
resource "aws_iam_role_policy_attachment" "lb_controller_attach" {
  role       = aws_iam_role.lb_controller_role.name
  policy_arn = aws_iam_policy.load_balancer_controller.arn
}

# 2. 為子網動態補上 ALB 需要的標籤 (避免手動改舊 Code)
resource "aws_ec2_tag" "public_tag" {
  resource_id = data.aws_subnet.public.id
  key         = "kubernetes.io/role/elb"
  value       = "1"
}

resource "aws_ec2_tag" "private_tag" {
  resource_id = data.aws_subnet.private.id
  key         = "kubernetes.io/role/internal-elb"
  value       = "1"
}

# 3. Security Groups
resource "aws_security_group" "rds_sg" {
  name        = "rds-mysql-sg"
  vpc_id      = data.aws_vpc.selected.id
  description = "Allow EKS nodes to access MySQL"

  ingress {
    from_port       = 3306
    to_port         = 3306
    protocol        = "tcp"
    cidr_blocks = ["10.0.0.0/16"]
    security_groups = [aws_eks_cluster.main.vpc_config[0].cluster_security_group_id]
  }
}

# 4. RDS Instance (MySQL)
resource "aws_db_subnet_group" "main" {
  name       = "main-db-subnet-group"
  subnet_ids = [
    data.aws_subnet.private.id,
    data.aws_subnet.private_2.id
  ]
}

resource "aws_db_instance" "mysql" {
  allocated_storage    = 20
  engine               = "mysql"
  engine_version       = "8.0"
  instance_class       = "db.t3.micro"
  db_name              = "ecommerce"
  username             = "admin"
  password             = "admin" # 建議用變數或 Secret Manager
  parameter_group_name = "default.mysql8.0"
  skip_final_snapshot  = true
  db_subnet_group_name = aws_db_subnet_group.main.name
  vpc_security_group_ids = [
    aws_security_group.rds_sg.id
  ]
  publicly_accessible  = false
}

# 5. EKS Cluster & IAM Roles (簡化版)
resource "aws_iam_role" "eks_cluster_role" {
  name = "eks-cluster-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17", 
    Statement = [{ 
      Action = "sts:AssumeRole", 
      Effect = "Allow", 
      Principal = { 
        Service = "eks.amazonaws.com" 
      } 
    }]
  })
}

resource "aws_iam_role_policy_attachment" "eks_policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
  role       = aws_iam_role.eks_cluster_role.name
}

resource "aws_eks_cluster" "main" {
  name     = "aws-eks-cluster"
  role_arn = aws_iam_role.eks_cluster_role.arn
  version  = "1.34"

  vpc_config {
    subnet_ids = [
      data.aws_subnet.public.id,
      data.aws_subnet.public_2.id
    ]
  }
  depends_on = [aws_iam_role_policy_attachment.eks_policy]
}

# 6. EKS Managed Node Group (SPOT)
resource "aws_iam_role" "node_role" {
  name = "eks-node-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17", 
    Statement = [{ 
      Action = "sts:AssumeRole", 
      Effect = "Allow", 
      Principal = { 
        Service = "ec2.amazonaws.com" 
      } 
    }]
  })
}

resource "aws_iam_role_policy_attachment" "node_policies" {
  for_each = toset([
    "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy",
    "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy",
    "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
  ])
  policy_arn = each.key
  role       = aws_iam_role.node_role.name
}

resource "aws_eks_node_group" "spot_nodes" {
  cluster_name    = aws_eks_cluster.main.name
  node_group_name = "spot-workers-public"
  node_role_arn   = aws_iam_role.node_role.arn
  subnet_ids      = [
    data.aws_subnet.public.id,
    data.aws_subnet.public_2.id
  ]

  capacity_type  = "SPOT"
  instance_types = ["t3.medium"]

  scaling_config {
    desired_size = 3
    max_size     = 5
    min_size     = 1
  }

  depends_on = [aws_iam_role_policy_attachment.node_policies]
}

# --- 1. OIDC Provider (ALB Controller 必備) ---
data "tls_certificate" "eks" {
  url = aws_eks_cluster.main.identity[0].oidc[0].issuer
}

resource "aws_iam_openid_connect_provider" "eks" {
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.eks.certificates[0].sha1_fingerprint]
  url             = aws_eks_cluster.main.identity[0].oidc[0].issuer
}

# --- 2. EKS Add-ons ---
resource "aws_eks_addon" "addons" {
  for_each     = toset(["vpc-cni", "coredns", "kube-proxy"])
  cluster_name = aws_eks_cluster.main.name
  addon_name   = each.key
  # 不指定版本則預設使用該 EKS 版本建議的穩定版
}

# --- 3. AWS Load Balancer Controller (Helm) ---
resource "helm_release" "lb_controller" {
  name       = "aws-load-balancer-controller"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-load-balancer-controller"
  namespace  = "kube-system"

  set {
    name  = "vpcId"
    value = data.aws_vpc.selected.id # 直接把 VPC ID 餵給它
  }

  set {
    name  = "region"
    value = "<area>" # 建議也加上 Region
  }

  set {
    name  = "clusterName"
    value = aws_eks_cluster.main.name
  }

  set {
    name  = "serviceAccount.create"
    value = "true"
  }

  set {
    name  = "serviceAccount.name"
    value = "aws-load-balancer-controller"
  }

  set {
    name  = "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
    # 修改這裡：從 module 改成指向上面建的資源
    value = aws_iam_role.lb_controller_role.arn 
  }

  # 確保 Add-ons 都好了才裝，避免網路不通
  depends_on = [aws_eks_addon.addons]
}
