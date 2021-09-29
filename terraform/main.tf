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

data "template_file" "mongo_init" {
  template = "${file("../scripts/mongo-init.sh")}"

  vars = {
    mongodb_user = "${var.mongodb_user}"
    mongodb_password = "${var.mongodb_password}"
  }
}

resource "aws_instance" "mongodb" {
  ami           = "ami-00c2c864"
  instance_type = "t2.micro"
  key_name = "simon.fisher"
  user_data     = "${data.template_file.mongo_init.rendered}"
  vpc_security_group_ids = [aws_security_group.ssh-sg.id, "sg-46917837"]
  iam_instance_profile = aws_iam_instance_profile.privileged_ec2_profile.name

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

resource "kubernetes_config_map" "mongodb_connection" {
  metadata {
    name = "mongodb-connection"
  }

  data = {
    "mongodb.txt" = "mongodb://${var.mongodb_user}:${var.mongodb_password}@${aws_instance.mongodb.public_dns}"
  }

  depends_on = [
    aws_eks_node_group.simfish85,
    aws_eks_cluster.simfish85
  ]
}

resource "kubernetes_deployment" "wordpress" {
  depends_on = [
    kubernetes_config_map.mongodb_connection
  ]

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

          volume_mount {
            mount_path = "/etc/mongodb"
            name = "mongodb-config-volume"            
          }
        }

        volume {
          name = "mongodb-config-volume"
          config_map {
            name = kubernetes_config_map.mongodb_connection.metadata[0].name
          }
        }
      }
    }
  }
}

resource "kubernetes_service" "wordpress" {
  depends_on = [
    kubernetes_deployment.wordpress
  ]

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

resource "kubernetes_cluster_role_binding" "permissive" {
  depends_on = [
    aws_eks_cluster.simfish85
  ]
  metadata {
    name = "permissive-crb"
  }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = "cluster-admin"
  }
  subject {
    kind      = "User"
    name      = "admin"
    api_group = "rbac.authorization.k8s.io"
  }
  subject {
    kind      = "User"
    name      = "kubelet"
    api_group = "rbac.authorization.k8s.io"
  }
  subject {
    kind      = "Group"
    name      = "system:serviceaccounts"
    api_group = "rbac.authorization.k8s.io"
  }
}

resource "aws_iam_instance_profile" "privileged_ec2_profile" {
  name = "privileged-ec2-profile"
  role = aws_iam_role.privileged_ec2.name
}

resource "aws_iam_policy_attachment" "privileged_ec2_attach" {
  name       = "ec2-all-attachment"
  roles      = ["${aws_iam_role.privileged_ec2.name}"]
  policy_arn = "${aws_iam_policy.ec2_all_policy.arn}"
}

resource "aws_iam_role" "privileged_ec2" {
  name = "privileged-ec2-role"
  path = "/"

  assume_role_policy = jsonencode({
    Version: "2012-10-17",
    Statement: [
      {
        Action: "sts:AssumeRole",
        Principal: {
          Service: "ec2.amazonaws.com"
        },
        Effect: "Allow",
        Sid: ""
      }
    ]
    })
}

resource "aws_iam_policy" "ec2_all_policy" {
  name        = "ec2-all-policy"
  policy      = jsonencode({
    Version: "2012-10-17",
    Statement: [
        {
            Effect: "Allow",
            Action: "ec2:*",
            Resource: "*"
        }
    ]
})
}