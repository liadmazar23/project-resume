provider "aws" {
  region = "us-west-2"
}

resource "aws_instance" "jenkins" {
  ami           = "ami-0604d81f2fd264c7b" # Amazon Linux 2 AMI
  instance_type = "t2.micro"
  key_name      = "us-west-2-key" # Replace with your key name

  root_block_device {
      volume_type = "gp2"
      volume_size = 8
  }

  ebs_block_device {
      device_name = "/dev/sdf"
      volume_size = 10
  }

  security_groups = [aws_security_group.jenkins_sg.name]

  tags = {
      Name = "Jenkins Server"
  }

  user_data = <<-EOF
  #!/bin/bash
  exec > >(tee /var/log/user-data.log|logger -t user-data -s 2>/dev/console) 2>&1
  
  # Update the package database
  sudo yum update -y
  
  # Install Docker
  sudo yum install -y docker

  # Start and enable Docker service
  sudo systemctl start docker
  sudo systemctl enable docker

  # Add the ec2-user to the docker group
  sudo usermod -aG docker ec2-user

  # Format and mount the EBS volume
  sudo mkfs -t ext4 /dev/sdg
  sudo mkdir -p /mnt/jenkins_data
  sudo mount /dev/sdg /mnt/jenkins_data
  sudo chown -R ec2-user:ec2-user /mnt/jenkins_data

  # Run Jenkins container as ec2-user
  sudo su - ec2-user -c 'docker run -d -p 8080:8080 -p 50000:50000 --name jenkins -v /mnt/jenkins_data:/var/jenkins_home jenkins/jenkins:lts'

  # Run Nginx container as ec2-user
  sudo su - ec2-user -c 'docker run -d -p 4040:80 --name nginx nginx'

  # Wait for Jenkins to start
  sleep 60

  # Check if Jenkins is running
  for i in {1..10}; do
    if curl -s http://localhost:8080/login | grep -q "Jenkins"; then
      echo "Jenkins is up and running"
      break
    else
      echo "Waiting for Jenkins to start..."
      sleep 10
    fi
  done
  EOF

  provisioner "remote-exec" {
      inline = [
          "sleep 120",  # Wait for Jenkins to initialize and create the password file
          "if [ -f /mnt/jenkins_data/secrets/initialAdminPassword ]; then sudo cat /mnt/jenkins_data/secrets/initialAdminPassword > /tmp/jenkins_initial_admin_password.txt; else echo 'Jenkins initialAdminPassword file not found' && exit 1; fi"
      ]

      connection {
          type        = "ssh"
          user        = "ec2-user"
          private_key = file(var.private_key_path)
          host        = self.public_ip
      }
  }

  provisioner "local-exec" {
      command = <<-EOF
          scp -o StrictHostKeyChecking=no -i ${var.private_key_path} ec2-user@${self.public_ip}:/tmp/jenkins_initial_admin_password.txt ./jenkins_initial_admin_password.txt
          echo "Jenkins initial admin password is:"
          cat ./jenkins_initial_admin_password.txt
          rm ./jenkins_initial_admin_password.txt
      EOF
  }
}

resource "aws_ebs_volume" "jenkins_data" {
  availability_zone = aws_instance.jenkins.availability_zone
  size              = 10
}

resource "aws_volume_attachment" "ebs_attachment" {
  device_name = "/dev/sdg"
  volume_id   = aws_ebs_volume.jenkins_data.id
  instance_id = aws_instance.jenkins.id
}

resource "aws_security_group" "jenkins_sg" {
  name_prefix = "jenkins-sg-"

  ingress {
      from_port   = 22
      to_port     = 22
      protocol    = "tcp"
      cidr_blocks = ["46.117.189.39/32"]
  }

  ingress {
      from_port   = 8080
      to_port     = 8080
      protocol    = "tcp"
      cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
      from_port   = 4040
      to_port     = 4040
      protocol    = "tcp"
      cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
      from_port   = 0
      to_port     = 0
      protocol    = "-1"
      cidr_blocks = ["0.0.0.0/0"]
  }
}

variable "private_key_path" {
  description = "Path to the private key file used for SSH access"
}

output "jenkins_public_ip" {
  value = aws_instance.jenkins.public_ip
}