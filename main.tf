//Provider for AWS
//My Simple Terraform Project
//My Git commit

provider "aws" {
      region  = "us-east-2"
      profile = "terraform-learn"
  }

//Create VPC 
resource "aws_vpc" "vpc01" {
  
      //count = length(var.main_vpc_cidr )
      cidr_block       = "10.0.0.0/16"
      //instance_tenancy = "default"[count.index] 

}
//Use data resource to fetch infomartion about the AZs
data "aws_availability_zones" "available"{

     state = "available"
}

//Create Private Subnets
resource "aws_subnet" "vpc1_pvt_subnet" {
      vpc_id     = aws_vpc.vpc01.id
      count      = length(data.aws_availability_zones.available.names)
      availability_zone = data.aws_availability_zones.available.names[count.index]
      cidr_block = "10.0.${0+count.index}.0/24"
      map_public_ip_on_launch = false

      tags = {
        "Name" = "PrivateSubnet-${count.index}"
      }
}

//Create Public Subnets
resource "aws_subnet" "vpc1_pub_subnet02" {
      vpc_id     = aws_vpc.vpc01.id
      count = length(data.aws_availability_zones.available.names)
      availability_zone = data.aws_availability_zones.available.names[count.index]
      cidr_block = "10.0.${100+count.index}.0/24"
      map_public_ip_on_launch = true
      tags = {
        "Name" = "PublicSubnet-${count.index}"
      }

  }

//Create Internet Gateway
resource "aws_internet_gateway" "igw" {

     vpc_id = aws_vpc.vpc01.id
     tags = {
       "Name" = "InternetGW"
     }

}

//Route Table for Public Subnet to go to internet via IGW
resource "aws_route_table" "public_subnet_rt" {
  vpc_id = aws_vpc.vpc01.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }
}

//Route Association of Route Table and Public Subnet
resource "aws_route_table_association" "nat_gateway" {
  subnet_id = aws_subnet.vpc1_pub_subnet02[0].id
  route_table_id = aws_route_table.public_subnet_rt.id
}

//Get Elastic IP for NAT Gatway
resource "aws_eip" "eip_nat_gw" {
   
     vpc = true
}

output "nat_gateway_ip" {
  value = aws_eip.eip_nat_gw.public_ip
}


//Create a NAT Gateway
resource "aws_nat_gateway" "nat_gw" {

     allocation_id = aws_eip.eip_nat_gw.id
     subnet_id = aws_subnet.vpc1_pub_subnet02[0].id
     tags = {
        Name = "gw NAT"
     }
     depends_on = [aws_internet_gateway.igw]
}

//Create EC2 Instance in Private Subnet


resource "tls_private_key" "ssh" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "aws_key_pair" "ssh" {
  key_name = "DummyMachine"
  public_key = tls_private_key.ssh.public_key_openssh
}

resource "local_file" "private_key" {
  content         = tls_private_key.ssh.private_key_pem
  filename        = "linode.pem"
}

output "ssh_private_key_pem" {
  value = tls_private_key.ssh.private_key_pem
  sensitive = true
}

output "ssh_public_key_pem" {
  value = tls_private_key.ssh.public_key_pem
}


resource "aws_security_group" "SGforEC2" {
  name = "SGforEc2"
  description = "EC2toNATGW"
  vpc_id = aws_vpc.vpc01.id
  ingress {
    cidr_blocks = ["0.0.0.0/0"]
    from_port = 80
    to_port = 80
    protocol = "tcp"
  }
  egress {
    cidr_blocks = ["0.0.0.0/0"]
    from_port = 0
    to_port = 0
    protocol = "-1"
  }
  tags = {
    "Name" = "SSH Access"
  }
}

resource "aws_instance" "ec2instance" {
  instance_type = "t2.micro"
  ami = "ami-001089eb624938d9f"
  count = 2
  subnet_id = aws_subnet.vpc1_pvt_subnet[count.index].id
  security_groups = [aws_security_group.SGforEC2.id]
  key_name = aws_key_pair.ssh.key_name
  disable_api_termination = false
  ebs_optimized = false
  user_data = <<EOF
              #!/bin/bash
              # Use this for your user data (script from top to bottom)
              # install httpd (Linux 2 version)
              yum update -y
              yum install -y httpd
              mount /dev/xvdf /var/www/html
              systemctl start httpd
              systemctl enable httpd
              echo "<h1>Hello World from $(hostname -f)</h1>" > /var/www/html/index.html
              EOF
  root_block_device {
    volume_size = "10"
  }
  ebs_block_device {
    volume_size = "1"
    device_name = "/dev/xvdf"
  }
  tags = {
    "Name" = "Machine${1+count.index}"
  }
}

resource "aws_route_table" "pvt_sub_route" {
  vpc_id = aws_vpc.vpc01.id
  route {
    cidr_block = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.nat_gw.id
  }
}

resource "aws_route_table_association" "pvt_sub_route_ass" {

   count = length(aws_subnet.vpc1_pvt_subnet)
   route_table_id = aws_route_table.pvt_sub_route.id
   subnet_id = aws_subnet.vpc1_pvt_subnet[count.index].id
  
}

//Deploy ALB

resource "aws_security_group" "SGforLB" {
  name = "SGforLB"
  description = "SGforLB"
  vpc_id = aws_vpc.vpc01.id
  ingress {
    cidr_blocks = ["0.0.0.0/0"]
    from_port = 80
    to_port = 80
    protocol = "tcp"
  }
  egress {
    cidr_blocks = ["0.0.0.0/0"]
    from_port = 0
    to_port = 0
    protocol = "-1"
  }
  tags = {
    "Name" = " Web Access"
  }
}

resource "aws_lb_target_group" "app-front-tg" {
    name     = "TG01"
    port     = 80
    protocol = "HTTP"
    vpc_id   = aws_vpc.vpc01.id

  health_check {
    path = "/ebs"
    port     = 80
    protocol = "HTTP"
    timeout  = 5
    interval = 10
  }
}

resource "aws_lb_target_group_attachment" "app" {
  count            = 2
  target_group_arn = aws_lb_target_group.app-front-tg.arn
  target_id        = aws_instance.ec2instance[count.index].id
  port             = 80

}

resource "aws_lb" "app-front" {
  name               = "main-app-lb"
  internal           = false
  load_balancer_type = "application"
  subnets            = [for subnet in aws_subnet.vpc1_pub_subnet02 : subnet.id]
  security_groups    = [aws_security_group.SGforLB.id]
}

resource "aws_lb_listener" "app" {
  load_balancer_arn = aws_lb.app-front.arn
  port              = "80"
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app-front-tg.arn
  }
}



















