# Retrieve AWS credentials from env variables AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY
provider "aws" {
  access_key = ""
  secret_key = ""
  region = "${var.region}"
}


############
## Network
############

# VPC
resource "aws_vpc" "kubernetes" {
  cidr_block = "${var.vpc_cidr}"
  enable_dns_hostnames = true

  tags {
    Name = "${var.vpc_name}"
    Owner = "${var.owner}"
  }
}

# Subnet (public)
resource "aws_subnet" "kubernetes" {
  vpc_id = "${aws_vpc.kubernetes.id}"
  cidr_block = "${var.vpc_cidr}"
  availability_zone = "${var.zone}"

  tags {
    Name = "kubernetes"
    Owner = "${var.owner}"
  }
}

resource "aws_internet_gateway" "gw" {
  vpc_id = "${aws_vpc.kubernetes.id}"
  tags {
    Name = "kubernetes"
    Owner = "${var.owner}"
  }
}

#########################
## Routing
#########################

resource "aws_route_table" "kubernetes" {
    vpc_id = "${aws_vpc.kubernetes.id}"

    # Default route through Internet Gateway
    route {
      cidr_block = "0.0.0.0/0"
      gateway_id = "${aws_internet_gateway.gw.id}"
    }

    tags {
      Name = "kubernetes"
      Owner = "${var.owner}"
    }
}

resource "aws_route_table_association" "kubernetes" {
  subnet_id = "${aws_subnet.kubernetes.id}"
  route_table_id = "${aws_route_table.kubernetes.id}"
}

############
## Instances
############

# etcd nodes
resource "aws_instance" "etcd" {
    count = 3
    ami = "${var.default_ami}"
    instance_type = "${var.default_instance_type}"

    subnet_id = "${aws_subnet.kubernetes.id}"
    private_ip = "${cidrhost(var.vpc_cidr, 10 + count.index)}"
    associate_public_ip_address = true # Instances have public, dynamic IP

    availability_zone = "${var.zone}"
    vpc_security_group_ids = ["${aws_security_group.kubernetes.id}"]
    key_name = "${var.default_keypair_name}"

    tags {
      Owner = "${var.owner}"
      Name = "etcd-${count.index}"
      ansibleFilter = "${var.ansibleFilter}"
      ansibleNodeType = "etcd"
      ansibleNodeName = "etcd${count.index}"
    }

    # Install Python 2
    # Add private DNS hostname to /etc/hosts (may not work on distro different from Ubuntu)
    provisioner "remote-exec" {
      inline = ["${var.install_python_command}"]
//      inline = ["${var.install_python_command}", "sudo sed -i \"1c127.0.0.1 localhost ${self.private_dns}\" /etc/hosts", "sudo hostname ${self.private_dns}"]
      connection {
        user = "${var.default_instance_user}"
        host = "${self.public_ip}"
        agent = true
      }
    }
}


# Kubernetes Controller nodes
resource "aws_instance" "controller" {

    count = 3
    ami = "${var.default_ami}"
    instance_type = "${var.default_instance_type}"

    subnet_id = "${aws_subnet.kubernetes.id}"
    private_ip = "${cidrhost(var.vpc_cidr, 20 + count.index)}"
    associate_public_ip_address = true # Instances have public, dynamic IP
    source_dest_check = false # TODO Required??

    availability_zone = "${var.zone}"
    vpc_security_group_ids = ["${aws_security_group.kubernetes.id}"]
    key_name = "${var.default_keypair_name}"

    tags {
      Owner = "${var.owner}"
      Name = "controller-${count.index}"
      ansibleFilter = "${var.ansibleFilter}"
      ansibleNodeType = "controller"
      ansibleNodeName = "controller${count.index}"
    }

    # Install Python 2
    # Add private DNS hostname to /etc/hosts (may not work on distro different from Ubuntu)
    provisioner "remote-exec" {
      inline = ["${var.install_python_command}"]
      connection {
        user = "${var.default_instance_user}"
        host = "${self.public_ip}"
        agent = true
      }
    }
}

# Kubernetes Worker nodes
resource "aws_instance" "worker" {
    count = 3
    ami = "${var.default_ami}"
    instance_type = "${var.default_instance_type}"

    subnet_id = "${aws_subnet.kubernetes.id}"
    private_ip = "${cidrhost(var.vpc_cidr, 30 + count.index)}"
    associate_public_ip_address = true # Instances have public, dynamic IP
    source_dest_check = false # TODO Required??

    availability_zone = "${var.zone}"
    vpc_security_group_ids = ["${aws_security_group.kubernetes.id}"]
    key_name = "${var.default_keypair_name}"

    tags {
      Owner = "${var.owner}"
      Name = "worker-${count.index}"
      ansibleFilter = "${var.ansibleFilter}"
      ansibleNodeType = "worker"
      ansibleNodeName = "worker${count.index}"
    }

    # Install Python 2
    # Add private DNS hostname to /etc/hosts (may not work on distro different from Ubuntu)
    provisioner "remote-exec" {
      inline = ["${var.install_python_command}"]
      connection {
        user = "${var.default_instance_user}"
        host = "${self.public_ip}"
        agent = true
      }
    }
}


###############################
## Kubernetes API Load Balancer
###############################

resource "aws_elb" "kubernetes_api" {
    name = "${var.elb_name}"
    instances = ["${aws_instance.controller.*.id}"]
    subnets = ["${aws_subnet.kubernetes.id}"]
    cross_zone_load_balancing = false

    security_groups = ["${aws_security_group.kubernetes_api.id}"]

    listener {
      lb_port = 6443
      instance_port = 6443
      lb_protocol = "TCP"
      instance_protocol = "TCP"
    }

    health_check {
      healthy_threshold = 2
      unhealthy_threshold = 2
      timeout = 15
      target = "HTTP:8080/healthz"
      interval = 30
    }

    tags {
      Name = "kubernetes"
      Owner = "${var.owner}"
    }
}



############
## Security
############

resource "aws_security_group" "kubernetes" {
  vpc_id = "${aws_vpc.kubernetes.id}"
  name = "kubernetes"

  # Allow all outbound
  egress {
    from_port = 0
    to_port = 0
    protocol = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Allow ICMP from control host IP
  ingress {
    from_port = 8
    to_port = 0
    protocol = "icmp"
    cidr_blocks = ["${var.control_cidr}"]
  }

  # Allow all internal
  ingress {
    from_port = 0
    to_port = 0
    protocol = "-1"
    cidr_blocks = ["${var.control_cidr}"]
  }

  # Allow all traffic from the API ELB
  ingress {
    from_port = 0
    to_port = 0
    protocol = "-1"
    security_groups = ["${aws_security_group.kubernetes_api.id}"]
  }

  # Allow all traffic from control host IP
  ingress {
    from_port = 0
    to_port = 0
    protocol = "-1"
    cidr_blocks = ["${var.control_cidr}"]
  }

  tags {
    Owner = "${var.owner}"
    Name = "kubernetes"
  }
}

resource "aws_security_group" "kubernetes_api" {
  vpc_id = "${aws_vpc.kubernetes.id}"
  name = "kubernetes-api"

  # Allow inbound traffic to the port used by Kubernetes API HTTPS
  ingress {
    from_port = 6443
    to_port = 6443
    protocol = "TCP"
    cidr_blocks = ["${var.control_cidr}"]
  }

  # Allow all outbound traffic
  egress {
    from_port = 0
    to_port = 0
    protocol = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags {
    Owner = "${var.owner}"
    Name = "kubernetes-api"
  }
}



####################
## Generate ssh.cfg
####################

# Generate ../ssh.cfg
data "template_file" "ssh_cfg" {
    template = "${file("${path.module}/template/ssh.cfg")}"
    depends_on = ["aws_instance.etcd", "aws_instance.controller", "aws_instance.worker"]
    vars {
      user = "${var.default_instance_user}"

      etcd0_ip = "${aws_instance.etcd.0.public_ip}"
      etcd1_ip = "${aws_instance.etcd.1.public_ip}"
      etcd2_ip = "${aws_instance.etcd.2.public_ip}"
      controller0_ip = "${aws_instance.controller.0.public_ip}"
      controller1_ip = "${aws_instance.controller.1.public_ip}"
      controller2_ip = "${aws_instance.controller.2.public_ip}"
      worker0_ip = "${aws_instance.worker.0.public_ip}"
      worker1_ip = "${aws_instance.worker.1.public_ip}"
      worker2_ip = "${aws_instance.worker.2.public_ip}"
    }
}
resource "null_resource" "ssh_cfg" {
  triggers {
    template_rendered = "${ data.template_file.ssh_cfg.rendered }"
  }
  provisioner "local-exec" {
    command = "echo '${ data.template_file.ssh_cfg.rendered }' > ../ssh.cfg"
  }
}

#########################
## Generate certificates
#########################

# Generate Certificates
data "template_file" "certificates" {
    template = "${file("${path.module}/template/kubernetes-csr.json")}"
    depends_on = ["aws_elb.kubernetes_api","aws_instance.etcd","aws_instance.controller","aws_instance.worker"]
    vars {
      kubernetes_api_elb_dns_name = "${aws_elb.kubernetes_api.dns_name}"
      kubernetes_cluster_dns = "${var.kubernetes_cluster_dns}"
      etcd0_ip = "${aws_instance.etcd.0.private_ip}"
      etcd1_ip = "${aws_instance.etcd.1.private_ip}"
      etcd2_ip = "${aws_instance.etcd.2.private_ip}"
      controller0_ip = "${aws_instance.controller.0.private_ip}"
      controller1_ip = "${aws_instance.controller.1.private_ip}"
      controller2_ip = "${aws_instance.controller.2.private_ip}"
      worker0_ip = "${aws_instance.worker.0.private_ip}"
      worker1_ip = "${aws_instance.worker.1.private_ip}"
      worker2_ip = "${aws_instance.worker.2.private_ip}"
    }
}
resource "null_resource" "certificates" {
  triggers {
    template_rendered = "${ data.template_file.certificates.rendered }"
  }
  provisioner "local-exec" {
    command = "echo '${ data.template_file.certificates.rendered }' > ../cert/kubernetes-csr.json"
  }
  provisioner "local-exec" {
    command = "cd ../cert; cfssl gencert -initca ca-csr.json | cfssljson -bare ca; cfssl gencert -ca=ca.pem -ca-key=ca-key.pem -config=ca-config.json -profile=kubernetes kubernetes-csr.json | cfssljson -bare kubernetes"
  }
}

############
## Outputs
############

output "kubernetes_api_dns_name" {
  value = "${aws_elb.kubernetes_api.dns_name}"
}

output "kubernetes_workers_public_ip" {
  value = "${join(",", aws_instance.worker.*.public_ip)}"
}
