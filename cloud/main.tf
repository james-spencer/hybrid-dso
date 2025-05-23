# main.tf

# Configure the AWS provider
provider "aws" {
  region = "us-east-1"
}

# --- Variables ---
variable "region" {
  type = string
  default = "us-east-1"
}

variable "project_name" {
  description = "A unique name for this project, used for resource tagging."
  type        = string
  default     = "juice-shop"
}

variable "instance_type" {
  description = "The EC2 instance type for the ECS cluster instances."
  type        = string
  default     = "t2.micro" # Smallest general-purpose instance type
}

variable "desired_instance_count" {
  description = "The desired number of EC2 instances in the ECS cluster."
  type        = number
  default     = 1
}

variable "ecr_repository_name" {
  description = "The name of your private ECR repository."
  type        = string
  default     = "eborsec/repo" 
  }

variable "ecr_image_tag" {
  description = "The tag of the Docker image in your ECR repository."
  type        = string
  default     = "latest"
}

variable "container_name" {
  description = "The name of the container within the ECS task definition."
  type        = string
  default     = "juice-shop"
}

variable "container_port" {
  description = "The port the application inside the Docker container listens on."
  type        = number
  default     = 3000
}

variable "host_port" {
  description = "The port on the EC2 instance that the container port will be mapped to."
  type        = number
  default     = 3000
}

variable "ssh_key_name" {
  description = "The name of an existing EC2 Key Pair for SSH access to instances (optional)."
  type        = string
  default     = "" # Leave empty if you don't need SSH access
}

# --- Network Resources (VPC, Subnet, Internet Gateway, Route Table) ---

resource "aws_vpc" "main" {
  cidr_block = "10.0.0.0/16"
  tags = {
    Name    = "${var.project_name}-vpc"
    Project = var.project_name
  }
}

resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.1.0/24"
  map_public_ip_on_launch = true # Instances in this subnet will get a public IP
  availability_zone       = "${var.region}a" # Using 'a' suffix for simplicity, adjust if needed
  tags = {
    Name    = "${var.project_name}-public-subnet"
    Project = var.project_name
  }
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id
  tags = {
    Name    = "${var.project_name}-igw"
    Project = var.project_name
  }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }
  tags = {
    Name    = "${var.project_name}-public-rt"
    Project = var.project_name
  }
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

# --- Security Group for ECS Instances ---

resource "aws_security_group" "ecs_instance_sg" {
  name        = "${var.project_name}-ecs-instance-sg"
  description = "Security group for ECS instances"
  vpc_id      = aws_vpc.main.id

  # Inbound rules
  ingress {
    from_port   = var.host_port
    to_port     = var.host_port
    protocol    = "tcp"
    cidr_blocks = ["212.132.163.128/32"] # Allow access to the application port from my IP
    description = "Allow inbound application traffic"
  }

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["212.132.163.128/32"] # IMPORTANT: Restrict this to your IP for production
    description = "Allow SSH access"
  }

  # Outbound rules - allow all outbound traffic
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name    = "${var.project_name}-ecs-instance-sg"
    Project = var.project_name
  }
}

# --- IAM Role for ECS Instance ---

resource "aws_iam_role" "ecs_instance_role" {
  name = "${var.project_name}-ecs-instance-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
      },
    ]
  })

  tags = {
    Name    = "${var.project_name}-ecs-instance-role"
    Project = var.project_name
  }
}

resource "aws_iam_role_policy_attachment" "ecs_managed_policy" {
  role       = aws_iam_role.ecs_instance_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEC2ContainerServiceforEC2Role" # Grants permissions for ECS agent
}

resource "aws_iam_role_policy_attachment" "ecr_read_only_policy" {
  role       = aws_iam_role.ecs_instance_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly" # Grants permissions to pull from ECR
}

resource "aws_iam_instance_profile" "ecs_instance_profile" {
  name = "${var.project_name}-ecs-instance-profile"
  role = aws_iam_role.ecs_instance_role.name
}

# --- ECS Cluster ---

resource "aws_ecs_cluster" "main" {
  name = "${var.project_name}-cluster"

  setting {
    name  = "containerInsights"
    value = "enabled" # Enable Container Insights for monitoring
  }

  tags = {
    Name    = "${var.project_name}-cluster"
    Project = var.project_name
  }
}

# --- EC2 Launch Template for ECS Instances ---
# Using a Launch Template for modern practice with Auto Scaling Groups

resource "aws_launch_template" "ecs_launch_template" {
  name_prefix   = "${var.project_name}-ecs-lt-"
  image_id      = "ami-03afdcc08c89cd0b8" # Use ECS-optimized AMI
  instance_type = var.instance_type
  key_name      = var.ssh_key_name == "" ? null : var.ssh_key_name # Only set if ssh_key_name is provided
  vpc_security_group_ids = [aws_security_group.ecs_instance_sg.id]
  iam_instance_profile {
    name = aws_iam_instance_profile.ecs_instance_profile.name
  }

  user_data = base64encode(
    # This user data script tells the EC2 instance which ECS cluster to join
    # It's crucial for the EC2 instance to register itself with the ECS cluster.
    # The 'echo ECS_CLUSTER=...' line is what configures the ECS agent.
    # The 'sudo apt update && sudo apt upgrade -y' ensures the instance is up-to-date.
    # The 'sudo reboot' ensures any kernel updates are applied and ECS agent starts cleanly.
    # Note: The AMI itself is ECS-optimized, but updating packages is good practice.
    # The reboot will cause the instance to restart, and the ECS agent will then connect.
    # This is a common pattern for ensuring the instance is fully ready.
    # For a production environment, consider more robust user data scripts or Golden AMIs.
    <<EOF
#!/bin/bash
echo ECS_CLUSTER=${aws_ecs_cluster.main.name} >> /etc/ecs/ecs.config
sudo apt update -y
sudo apt upgrade -y
sudo reboot
EOF
  )

  tag_specifications {
    resource_type = "instance"
    tags = {
      Name    = "${var.project_name}-ecs-instance"
      Project = var.project_name
    }
  }
  tag_specifications {
    resource_type = "volume"
    tags = {
      Name    = "${var.project_name}-ecs-instance-volume"
      Project = var.project_name
    }
  }
}

/*# Data source to get the latest ECS-optimized AMI ID for the specified region
data "aws_ami" "ecs_optimized" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["amzn2-ami-ecs-hvm-*-x86_64-gp2"] # Latest Amazon Linux 2 ECS-optimized AMI
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}
*/
# --- Auto Scaling Group for ECS Instances ---

resource "aws_autoscaling_group" "ecs_asg" {
  name                      = "${var.project_name}-ecs-asg"
  vpc_zone_identifier       = [aws_subnet.public.id]
  desired_capacity          = var.desired_instance_count
  min_size                  = var.desired_instance_count
  max_size                  = var.desired_instance_count # Fixed size for 1 instance

  launch_template {
    id      = aws_launch_template.ecs_launch_template.id
    version = "$Latest"
  }

  tag {
    key                 = "AmazonECSManaged" # Required tag for ECS Auto Scaling integration
    value               = ""
    propagate_at_launch = true
  }
  tag {
    key                 = "Name"
    value               = "${var.project_name}-ecs-asg-instance"
    propagate_at_launch = true
  }
  tag {
    key                 = "Project"
    value               = var.project_name
    propagate_at_launch = true
  }
}

# --- ECS Task Definition ---
# This defines the Docker container(s) that will run on the cluster

resource "aws_ecs_task_definition" "app_task" {
  family                   = "${var.project_name}-task"
  network_mode             = "bridge" # For EC2 launch type, bridge mode is common
  requires_compatibilities = ["EC2"]
  cpu                      = "256" # Smallest CPU unit (0.25 vCPU)
  memory                   = "512" # Smallest memory unit (0.5 GB)
  execution_role_arn       = aws_iam_role.ecs_task_execution_role.arn # Role for ECS agent to pull images

  container_definitions = jsonencode([
    {
      name        = var.container_name
      image       = "${data.aws_caller_identity.current.account_id}.dkr.ecr.${var.region}.amazonaws.com/${var.ecr_repository_name}:${var.ecr_image_tag}"
      cpu         = 256
      memory      = 512
      essential   = true
      portMappings = [
        {
          containerPort = var.container_port
          hostPort      = var.host_port
          protocol      = "tcp"
        }
      ]
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = "/ecs/${var.project_name}-task"
          "awslogs-region"        = var.region
          "awslogs-stream-prefix" = "ecs"
        }
      }
    }
  ])

  tags = {
    Name    = "${var.project_name}-task-definition"
    Project = var.project_name
  }
}

# IAM Role for ECS Task Execution (for pulling images from ECR)
resource "aws_iam_role" "ecs_task_execution_role" {
  name = "${var.project_name}-ecs-task-execution-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ecs-tasks.amazonaws.com"
        }
      },
    ]
  })
  tags = {
    Name    = "${var.project_name}-ecs-task-execution-role"
    Project = var.project_name
  }
}

resource "aws_iam_role_policy_attachment" "ecs_task_execution_role_policy" {
  role       = aws_iam_role.ecs_task_execution_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# Data source to get the current AWS account ID for ECR image path
data "aws_caller_identity" "current" {}

# --- ECS Service ---
# This maintains the desired count of tasks and handles deployments

resource "aws_ecs_service" "app_service" {
  name            = "${var.project_name}-service"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.app_task.arn
  desired_count   = 1 # Ensure one instance of the container is running
  launch_type     = "EC2"

  # Optional: If you want to use a load balancer, uncomment and configure
  # load_balancer {
  #   target_group_arn = aws_lb_target_group.app.arn
  #   container_name   = var.container_name
  #   container_port   = var.container_port
  # }

  # Optional: Deployment circuit breaker for automatic rollback
  # deployment_circuit_breaker {
  #   enable   = true
  #   rollback = true
  # }

  # Optional: Health check grace period
  # health_check_grace_period_seconds = 300

  # Configure logging for the ECS service
  # This creates a CloudWatch Log Group for your container logs
  depends_on = [
    aws_cloudwatch_log_group.ecs_task_logs
  ]

  tags = {
    Name    = "${var.project_name}-service"
    Project = var.project_name
  }
}

# CloudWatch Log Group for ECS Task Logs
resource "aws_cloudwatch_log_group" "ecs_task_logs" {
  name              = "/ecs/${var.project_name}-task"
  retention_in_days = 1 # Adjust log retention as needed

  tags = {
    Name    = "${var.project_name}-ecs-task-logs"
    Project = var.project_name
  }
}

# --- Outputs ---

output "ecs_cluster_name" {
  description = "The name of the created ECS cluster."
  value       = aws_ecs_cluster.main.name
}

output "ecs_service_name" {
  description = "The name of the created ECS service."
  value       = aws_ecs_service.app_service.name
}