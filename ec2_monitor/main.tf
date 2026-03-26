# Base Infrastructure: VPC & EKS Cluster
provider "aws" {
  region = "<area>" 
}

# 固定版本
terraform {
  required_providers {
    aws = {
      source = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

# VPC
resource "aws_vpc" "main" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_hostnames = true
  tags = { Name = "cicd-monitor-vpc" }
}

resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "main-igw" }
}

# Subnet：public + private
resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.1.0/24"
  availability_zone       = "<area>a" # 固定 AZ 避開跨區流量費
  map_public_ip_on_launch = true
  tags                    = { 
    Name = "public-subnet-frontend" 
    "kubernetes.io/role/elb" = "1"
  }
}

# 補一個位於 1c 的 Public Subnet
resource "aws_subnet" "public_2" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.3.0/24"
  availability_zone       = "<area>c" # 換一個 AZ
  map_public_ip_on_launch = true
  tags                    = { 
    Name = "public-subnet-2" 
    "kubernetes.io/role/elb" = "1" # 讓 ALB Controller 可以自動識別這個 Subnet
  }
}

resource "aws_subnet" "private" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.2.0/24"
  availability_zone = "<area>a"
  tags              = { Name = "private-subnet-backend" }
}

# 補一個位於 1c 的 Private Subnet
resource "aws_subnet" "private_2" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.4.0/24"
  availability_zone = "<area>c"
  tags              = { Name = "private-subnet-2" }
}

# route table：Public 接 IGW，Private 不接
resource "aws_route_table" "public_rt" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }
}

# --- public ---
resource "aws_route_table_association" "public_assoc" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public_rt.id
}

# 讓 public_2 也接上 IGW
resource "aws_route_table_association" "public_2_assoc" {
  subnet_id      = aws_subnet.public_2.id
  route_table_id = aws_route_table.public_rt.id
}

# --- private ---
# Private Subnet 預設只有 Local 路由，所以無法連外網
resource "aws_route_table" "private_rt" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "private-rt-no-nat" }
}

resource "aws_route_table_association" "private_assoc" {
  subnet_id      = aws_subnet.private.id
  route_table_id = aws_route_table.private_rt.id
}

# 讓 private_2 也綁定到不通外網的路由表
resource "aws_route_table_association" "private_2_assoc" {
  subnet_id      = aws_subnet.private_2.id
  route_table_id = aws_route_table.private_rt.id
}

# SG：使用「標籤關聯」而非死寫 IP
# CIDR block 通常會允許特定 ip，但我先全開
resource "aws_security_group" "public_sg" {
  name   = "public-frontend-sg"
  vpc_id = aws_vpc.main.id

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 8080 # Jenkins
    to_port     = 8080
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 3000 # Grafana
    to_port     = 3000
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # 2. 監測數據入口 (讓 Backend 來抓 Metrics)
  # Node Exporter: 9100, Promtail HTTP: 9080 (用於檢查狀態)
  ingress {
    from_port       = 9100
    to_port         = 9100
    protocol        = "tcp"
    cidr_blocks     = ["10.0.0.0/16"] 
    description     = "Allow Prometheus to scrape node_exporter"
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# Private SG: 只允許 Public SG 連入，且允許 EKS 流量 (假設 EKS 段為 10.0.0.0/16)
resource "aws_security_group" "private_sg" {
  name   = "private-backend-sg"
  vpc_id = aws_vpc.main.id

  # 接收來自 Frontend Agents 的數據 (Push Model)
  ingress {
    from_port       = 3100 # Loki (Logs)
    to_port         = 3100
    protocol        = "tcp"
    cidr_blocks     = ["10.0.0.0/16"] 
    description     = "Loki ingestion from Promtail"
  }

  ingress {
    from_port       = 3200 # Tempo (Traces - HTTP/GRPC 常用 Port)
    to_port         = 3200
    protocol        = "tcp"
    cidr_blocks     = ["10.0.0.0/16"] 
    description     = "Tempo ingestion"
  }

  ingress {
    from_port       = 4317 # OTLP gRPC (Tempo/OpenTelemetry)
    to_port         = 4318 # OTLP HTTP
    protocol        = "tcp"
    cidr_blocks     = ["10.0.0.0/16"] 
    description     = "OpenTelemetry ingestion"
  }

  # 開放 9090 讓 grafana 抓資料
  ingress {
    from_port       = 9090 # Prometheus UI/API
    to_port         = 9090
    protocol        = "tcp"
    cidr_blocks     = ["10.0.0.0/16"] 
  }

  # 預留給 EKS 的 Metrics/Logs 傳輸 (9090, 3100, 3200)
  ingress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["10.0.0.0/16"] 
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# 使用 Data Source 動態獲取最新的 AL2023 AMI
data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["amazon"]
  filter {
    name   = "name"
    values = ["al2023-ami-2023*-x86_64"]
  }
}

# EC2 實體
resource "aws_instance" "frontend" {
  ami                  = data.aws_ami.al2023.id
  instance_type        = "t3.medium"
  subnet_id            = aws_subnet.public.id
  key_name             = "frontend"
  vpc_security_group_ids = [aws_security_group.public_sg.id]

  lifecycle {
    ignore_changes = [ami]            # 即使 AMI 有新版，也不要動這台老機器
  #   prevent_destroy = true            # 防止任何形式的銷毀（包含 destroy 指令）
  }

  user_data = "#!/bin/bash\nhostnamectl set-hostname frontend-cicd"
  tags = { Name = "frontend-al2023" }
}

resource "aws_instance" "backend" {
  ami                  = data.aws_ami.al2023.id
  instance_type        = "t3.large"
  subnet_id            = aws_subnet.private.id
  key_name      = "backend"
  vpc_security_group_ids = [aws_security_group.private_sg.id]

  lifecycle {
    ignore_changes = [ami]            # 即使 AMI 有新版，也不要動這台老機器
  #   prevent_destroy = true            # 防止任何形式的銷毀（包含 destroy 指令）
  }

  user_data = "#!/bin/bash\nhostnamectl set-hostname backend-monitor"
  tags = { Name = "backend-al2023" }
}

# 為 Frontend 綁定 EIP (方便連線)
resource "aws_eip" "frontend_eip" {
  instance = aws_instance.frontend.id
  domain   = "vpc"
  tags     = { Name = "frontend-eip" }
}

