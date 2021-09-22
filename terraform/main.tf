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
  vpc_security_group_ids = [aws_security_group.ssh-sg.id, "default"]


  tags = {
    Name = "MongoDB Instance"
  }
}

output "mongodb_public_dns" {
    value = aws_instance.mongodb.public_dns
}