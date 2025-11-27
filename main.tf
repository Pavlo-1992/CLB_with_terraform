provider "aws" {
  region = "eu-west-1" 
}

############################################################################
#                      VPC, Subnets, IGW, Route Table                      #
############################################################################

# Creating VPC
resource "aws_vpc" "vpc_for_lb" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "vpc_for_LB"
  }
}

# Creating Internet Gateway (IGW)
resource "aws_internet_gateway" "ig_for_lb" {
  vpc_id = aws_vpc.vpc_for_lb.id

  tags = {
    Name = "IG_for_LB"
  }
}

# Creating Public Route Table
resource "aws_route_table" "public_rt_for_lb" {
  vpc_id = aws_vpc.vpc_for_lb.id

  tags = {
    Name = "public_RT_for_LB"
  }
}

# Adding default route to IGW
resource "aws_route" "default_internet_route" {
  route_table_id         = aws_route_table.public_rt_for_lb.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.ig_for_lb.id
}

# Creating Public Subnet 0
resource "aws_subnet" "public0_for_lb" {
  vpc_id                  = aws_vpc.vpc_for_lb.id
  cidr_block              = "10.0.1.0/24"
  availability_zone       = "eu-west-1a"
  map_public_ip_on_launch = true

  tags = {
    Name = "public0_for_LB"
  }
}

# Creating Public Subnet 1
resource "aws_subnet" "public1_for_lb" {
  vpc_id                  = aws_vpc.vpc_for_lb.id
  cidr_block              = "10.0.2.0/24"
  availability_zone       = "eu-west-1b"
  map_public_ip_on_launch = true

  tags = {
    Name = "public1_for_LB"
  }
}

# Associating subnets with route table
resource "aws_route_table_association" "a_pub0" {
  subnet_id      = aws_subnet.public0_for_lb.id
  route_table_id = aws_route_table.public_rt_for_lb.id
}

resource "aws_route_table_association" "a_pub1" {
  subnet_id      = aws_subnet.public1_for_lb.id
  route_table_id = aws_route_table.public_rt_for_lb.id
}

############################################################################
#                 Security Group for Application Load Balancer            #
############################################################################

resource "aws_security_group" "sg_for_lb" {
  vpc_id      = aws_vpc.vpc_for_lb.id
  name        = "sg_for_lb"
  description = "Allow HTTP from anywhere to ALB"

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "sg_for_lb"
  }
}

############################################################################
#                         EC2 Instances with Nginx                        #
############################################################################

# Security group for EC2 instances
resource "aws_security_group" "sg_for_ec2" {
  vpc_id      = aws_vpc.vpc_for_lb.id
  name        = "sg_for_ec2"
  description = "Allow HTTP from ALB and SSH from my IP"

  # Allow HTTP only from ALB security group
  ingress {
    from_port       = 80
    to_port         = 80
    protocol        = "tcp"
    security_groups = [aws_security_group.sg_for_lb.id]
  }

  # SSH access (replace 0.0.0.0/0 with your real IP!)
  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "sg_for_ec2"
  }
}

# Ubuntu AMI lookup (latest LTS)
data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-focal-20.04-amd64-server-*"]
  }
}

# User data script for Ubuntu with nginx
locals {
  user_data_base = <<-EOT
    #!/bin/bash
    apt update -y
    apt install -y nginx
    systemctl enable nginx
    systemctl start nginx
  EOT
}

# EC2 instance 00
resource "aws_instance" "aws_test_00" {
  ami                         = data.aws_ami.ubuntu.id
  instance_type               = "t3.micro"
  subnet_id                   = aws_subnet.public0_for_lb.id
  vpc_security_group_ids      = [aws_security_group.sg_for_ec2.id]
  key_name                    = "your_own_key"               # <-- SPECIFY YOUR EXISTING KEY IN AWS!

  user_data = "${local.user_data_base} \n echo '<h1>Does it really work?</h1>' > /var/www/html/index.html \n touch /var/www/html/healthcheck.html"

  tags = {
    Name = "aws-test-00"
  }
}

# EC2 instance 01
resource "aws_instance" "aws_test_01" {
  ami                         = data.aws_ami.ubuntu.id
  instance_type               = "t3.micro"
  subnet_id                   = aws_subnet.public1_for_lb.id
  vpc_security_group_ids      = [aws_security_group.sg_for_ec2.id]
  key_name                    = "your_own_key"               # <-- SPECIFY YOUR EXISTING KEY IN AWS!

  user_data = "${local.user_data_base} \n echo '<h1>Yes, it really works!</h1>' > /var/www/html/index.html \n touch /var/www/html/healthcheck.html"

  tags = {
    Name = "aws-test-01"
  }
}

############################################################################
#                       Target Group & Load Balancer                       #
############################################################################

resource "aws_lb_target_group" "tg_for_lb" {
  name     = "TG-for-LB"
  port     = 80
  protocol = "HTTP"
  vpc_id   = aws_vpc.vpc_for_lb.id

  health_check {
    path                = "/healthcheck.html"
    protocol            = "HTTP"
    port                = "80"
    matcher             = "200"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 3
    unhealthy_threshold = 3
  }
}

# Attach EC2 instances to target group
resource "aws_lb_target_group_attachment" "att_00" {
  target_group_arn = aws_lb_target_group.tg_for_lb.arn
  target_id        = aws_instance.aws_test_00.id
  port             = 80
}

resource "aws_lb_target_group_attachment" "att_01" {
  target_group_arn = aws_lb_target_group.tg_for_lb.arn
  target_id        = aws_instance.aws_test_01.id
  port             = 80
}

# Creating ALB
resource "aws_lb" "alb_for_nginx" {
  name               = "alb-for-nginx"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.sg_for_lb.id]
  subnets            = [aws_subnet.public0_for_lb.id, aws_subnet.public1_for_lb.id]

  tags = {
    Name = "ALB-for-Nginx"
  }
}

# HTTP listener for ALB
resource "aws_lb_listener" "http_listener" {
  load_balancer_arn = aws_lb.alb_for_nginx.arn
  port              = "80"
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.tg_for_lb.arn
  }
}

############################################################################
#                                 Outputs                                  #
############################################################################

output "alb_dns_name" {
  description = "DNS name of Application Load Balancer"
  value       = aws_lb.alb_for_nginx.dns_name
}

