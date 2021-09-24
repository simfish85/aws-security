provider "aws" {
  region = "eu-west-2"
  profile = "googlemail"
}

resource "aws_security_group" "ssh-sg" {
    name = "ssh-sg"
    ingress {
      from_port        = 22
      to_port          = 22
      protocol         = "tcp"
      cidr_blocks      = ["0.0.0.0/0"]
    }
} 


resource "aws_instance" "mongodb" {
  ami           = "ami-00c2c864"
  instance_type = "t2.micro"
  key_name = "simon.fisher"
  user_data     = file("../scripts/mongo-init.sh")
  vpc_security_group_ids = [aws_security_group.ssh-sg.id, "sg-46917837"]

  tags = {
    Name = "MongoDB Instance"
  }
}

output "mongodb_public_dns" {
    value = aws_instance.mongodb.public_dns
}

resource "aws_s3_bucket" "mongodb-backups" {
  bucket = "simfish85-mongodb-backups"
  acl    = "public-read"

  tags = {
    Name        = "MongoDB Backups"
  }
}

resource "aws_iam_role" "eks-cluster" {
  name = "eks-cluster-role"

  assume_role_policy = <<POLICY
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "eks.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
POLICY
}

resource "aws_iam_role_policy_attachment" "simfish85-AmazonEKSClusterPolicy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
  role       = aws_iam_role.eks-cluster.name
}

# Optionally, enable Security Groups for Pods
# Reference: https://docs.aws.amazon.com/eks/latest/userguide/security-groups-for-pods.html
resource "aws_iam_role_policy_attachment" "simfish85-AmazonEKSVPCResourceController" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSVPCResourceController"
  role       = aws_iam_role.eks-cluster.name
}

resource "aws_eks_cluster" "simfish85" {
  name     = "simfish85"
  role_arn = aws_iam_role.eks-cluster.arn

  vpc_config {
    subnet_ids = ["subnet-13de495f", "subnet-675f1e1d"]
  }

  # Ensure that IAM Role permissions are created before and deleted after EKS Cluster handling.
  # Otherwise, EKS will not be able to properly delete EKS managed EC2 infrastructure such as Security Groups.
  depends_on = [
    aws_iam_role_policy_attachment.simfish85-AmazonEKSClusterPolicy,
    aws_iam_role_policy_attachment.simfish85-AmazonEKSVPCResourceController,
  ]
}

output "endpoint" {
  value = aws_eks_cluster.simfish85.endpoint
}

output "kubeconfig-certificate-authority-data" {
  value = aws_eks_cluster.simfish85.certificate_authority[0].data
}

resource "aws_iam_role" "eks-node-group" {
  name = "eks-node-group-role"

  assume_role_policy = jsonencode({
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "ec2.amazonaws.com"
      }
    }]
    Version = "2012-10-17"
  })
}

resource "aws_iam_role_policy_attachment" "simfish85-AmazonEKSWorkerNodePolicy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
  role       = aws_iam_role.eks-node-group.name
}

resource "aws_iam_role_policy_attachment" "simfish85-AmazonEKS_CNI_Policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
  role       = aws_iam_role.eks-node-group.name
}

resource "aws_iam_role_policy_attachment" "simfish85-AmazonEC2ContainerRegistryReadOnly" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
  role       = aws_iam_role.eks-node-group.name
}

resource "aws_eks_node_group" "simfish85" {
  cluster_name    = aws_eks_cluster.simfish85.name
  node_group_name = "simfish85-ng"
  node_role_arn   = aws_iam_role.eks-node-group.arn
  subnet_ids      = ["subnet-13de495f", "subnet-675f1e1d"]
  instance_types = ["t2.micro"]

  scaling_config {
    desired_size = 2
    max_size     = 2
    min_size     = 2
  }

  # Ensure that IAM Role permissions are created before and deleted after EKS Node Group handling.
  # Otherwise, EKS will not be able to properly delete EC2 Instances and Elastic Network Interfaces.
  depends_on = [
    aws_iam_role_policy_attachment.simfish85-AmazonEKSWorkerNodePolicy,
    aws_iam_role_policy_attachment.simfish85-AmazonEKS_CNI_Policy,
    aws_iam_role_policy_attachment.simfish85-AmazonEC2ContainerRegistryReadOnly,
  ]
}

provider "kubernetes" {
  host                   = aws_eks_cluster.simfish85.endpoint
  cluster_ca_certificate = base64decode(aws_eks_cluster.simfish85.certificate_authority[0].data)
  exec {
    api_version = "client.authentication.k8s.io/v1alpha1"
    command     = "aws"
    args = [
      "eks",
      "get-token",
      "--cluster-name",
      aws_eks_cluster.simfish85.name,
      "--profile",
      "googlemail"
    ]
  }
}

resource "kubernetes_deployment" "wordpress" {
  metadata {
    name = "wordpress"
    labels = {
      App = "Wordpress"
    }
  }

  spec {
    replicas = 1
    selector {
      match_labels = {
        App = "Wordpress"
      }
    }
    template {
      metadata {
        labels = {
          App = "Wordpress"
        }
      }
      spec {
        container {
          image = "wordpress:latest"
          name  = "wordpress"

          port {
            container_port = 80
          }

          resources {
            limits = {
              cpu    = "0.5"
              memory = "512Mi"
            }
            requests = {
              cpu    = "250m"
              memory = "50Mi"
            }
          }
        }
      }
    }
  }
}

resource "kubernetes_service" "wordpress" {
  metadata {
    name = "wordpress"
  }
  spec {
    selector = {
      App = kubernetes_deployment.wordpress.spec.0.template.0.metadata[0].labels.App
    }
    port {
      port        = 80
      target_port = 80
    }

    type = "LoadBalancer"
  }
}

output "lb_ip" {
  value = kubernetes_service.wordpress.status.0.load_balancer.0.ingress.0.hostname
}

