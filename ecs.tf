provider "aws" {
  region = "us-east-2"  # Specify your desired AWS region
}

variable "vpc_id" {}
variable "subnet_ids" {
  type = list(string)
}
variable "db_password" {}

# network

resource "aws_security_group" "ecs_sg" {
  name_prefix = "ecs-sg-"
  vpc_id      = var.vpc_id

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
    Name = "ecs-security-group"
  }
}

#RDS instance
resource "aws_db_instance" "wordpress_db" {
  allocated_storage    = 20
  engine               = "mysql"
  instance_class       = "db.t2.micro"
  name                 = "wordpress"
  username             = "admin"
  password             = var.db_password
  parameter_group_name = "default.mysql5.7"
  skip_final_snapshot  = true
  vpc_security_group_ids = [aws_security_group.ecs_sg.id]

  tags = {
    Name = "wordpress-db"
  }
}

# Ecs Cluster
resource "aws_ecs_cluster" "wordpress_cluster" {
  name = "wordpress-cluster"
}

#IAM
resource "aws_iam_role" "ecs_task_execution_role" {
  name = "ecsTaskExecutionRole"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "ecs-tasks.amazonaws.com"
      }
    }]
  })
}

resource "aws_iam_policy_attachment" "ecs_task_execution_policy" {
  name       = "ecsTaskExecutionPolicy"
  roles      = [aws_iam_role.ecs_task_execution_role.name]
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# Tasks
resource "aws_ecs_task_definition" "wordpress" {
  family                   = "wordpress-task"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  execution_role_arn       = aws_iam_role.ecs_task_execution_role.arn
  memory                   = "512"
  cpu                      = "256"

  container_definitions = jsonencode([{
    name      = "wordpress"
    image     = "wordpress:latest"
    essential = true
    portMappings = [{
      containerPort = 80
      hostPort      = 80
    }]
    environment = [
      {
        name  = "WORDPRESS_DB_HOST"
        value = "${aws_db_instance.wordpress_db.address}"
      },
      {
        name  = "WORDPRESS_DB_USER"
        value = "admin"
      },
      {
        name  = "WORDPRESS_DB_PASSWORD"
        value = var.db_password
      }
    ]
  }])
}

# ECS LB
resource "aws_lb" "ecs_lb" {
  name               = "ecs-lb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.ecs_sg.id]
  subnets            = var.subnet_ids

  enable_deletion_protection = false

  tags = {
    Name = "ecs-lb"
  }
}

resource "aws_lb_target_group" "ecs_tg" {
  name     = "ecs-tg"
  port     = 80
  protocol = "HTTP"
  vpc_id   = var.vpc_id

  health_check {
    interval            = 30
    path                = "/"
    protocol            = "HTTP"
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 2
  }

  tags = {
    Name = "ecs-tg"
  }
}

resource "aws_lb_listener" "ecs_lb_listener" {
  load_balancer_arn = aws_lb.ecs_lb.arn
  port              = "80"
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.ecs_tg.arn
  }
}

resource "aws_ecs_service" "wordpress_service" {
  name            = "wordpress-service"
  cluster         = aws_ecs_cluster.wordpress_cluster.id
  task_definition = aws_ecs_task_definition.wordpress.arn
  desired_count   = 1
  launch_type     = "FARGATE"
  platform_version = "LATEST"

  network_configuration {
    subnets         = var.subnet_ids
    security_groups = [aws_security_group.ecs_sg.id]
    assign_public_ip = true
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.ecs_tg.arn
    container_name   = "wordpress"
    container_port   = 80
  }

  depends_on = [
    aws_lb_listener.ecs_lb_listener
  ]
}

# Var
variable "vpc_id" {
  description = "ami-0ddda618e961f2270"
}

variable "subnet_ids" {
  description = "A list of subnet IDs for ECS service"
  type        = list(string)
  default     = [
    "subnet-0e9f14c67522c0055",
    "subnet-09d335e7f5d5b6d21",
    "subnet-0b85707b1f095ffb9"
  ]
}

variable "db_password" {
  description = "password"
  type        = string
  sensitive   = true
}

# Output
output "ecs_cluster_name" {
  value = aws_ecs_cluster.wordpress_cluster.name
}

output "ecs_service_name" {
  value = aws_ecs_service.wordpress_service.name
}

output "rds_endpoint" {
  value = aws_db_instance.wordpress_db.endpoint
}

output "alb_dns_name" {
  value = aws_lb.ecs_lb.dns_name
}
