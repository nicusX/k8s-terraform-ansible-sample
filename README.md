# Kubernetes not the hardest way (or "Provisioning a Kubernetes Cluster on AWS using Terraform and Ansible")

The goal of this sample project is provisioning AWS infrastructure and Kubernetes cluster, using Terraform and Ansible.
It is not meant to be production-ready, but to provide a realistic example, beyond the usual "Hello, world" ones.

Please refer to the companion blog posts: https://opencredo.com/kubernetes-aws-terraform-ansible-1/ ‎

### Target platform

The setup is based on [Kubernetes the hard way](https://github.com/kelseyhightower/kubernetes-the-hard-way). This project follows the same steps (except installing DNS add-on), translated from Google Cloud to AWS and made automatic.

Infrastructure includes:

- AWS VPC
- 3 instances for HA Kubernetes Control Plane: Kubernetes API, Scheduler and Controller Manager
- 3 instances for HA etcd cluster
- 3 Kubernetes worker instances (aka minions or nodes)
- Kubenet Pod networking (using CNI)
- Sample *nginx* service deployed to check everything works


There are many known simplifications, compared to a production-ready solution (See "Known simplifications", below)


## Requirements

Requirements on control machine:

- Terraform (tested with Terraform 0.7.0; NOT compatible with Terraform 0.6.x)
- Python (tested with Python 2.7.12)
- Python netaddr module
- Ansible (tested with Ansible 2.1.0.0)
- `cfssl` and `cfssljson`  https://github.com/cloudflare/cfssl
- Kubernetes CLI
- SSH Agent

### OSX installation

- Terraform: see https://www.terraform.io/intro/getting-started/install.html (the version in brew is outdated!)
- Python: `brew install python`
- Python netaddr module: `pip install netaddr`
- Ansible: `pip install ansible` or http://docs.ansible.com/ansible/intro_installation.html
- CFSSL (includes CFSSLjson): `brew install cfssl`
- Kubernetes CLI: `brew install Kubernetes-cli`
- SSH Agent: already running

### Linux installation

The same as OSX, except you will use the package manager of the distribution you are using.
Remember Ansible requires Python 2.5+ and is not compatible with Python 3.

### Windows installation

Seriously? ;)


## Credentials


### AWS KeyPair

You need a valid AWS Identity (`.pem`) file and Public Key. Terraform will import the [KeyPair](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/ec2-key-pairs.html) and Ansible will use the Identity to SSH into the machines.

Please read [AWS Documentation](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/ec2-key-pairs.html#how-to-generate-your-own-key-and-import-it-to-aws) about supported formats.

### Terraform and Ansible authentication

Both Terraform and Ansible expect AWS credentials in environment variables:
```
$ export AWS_ACCESS_KEY_ID=<access-key-id>
$ export AWS_SECRET_ACCESS_KEY="<secret-key>"
```

Ansible expects ssh identity loaded into ssh agent:
```
$ ssh-add <keypair-name>.pem
```

## Setup variables defining the environment

Before running Terraform, you must define set some Terraform variables:

- `control_cidr`: The CIDR of your IP. All instances will accept only traffic from this address only. Note this is a CIDR, not a single IP. e.g. `123.45.67.89/32` (mandatory)
- `default_keypair_public_key`: Valid public key corresponding to the Identity you will use to SSH into VMs. e.g. `"ssh-rsa AAA....xyz"` (mandatory)


You may also optionally redefine these variables:

- `default_keypair_name`: AWS key-pair name for all instances.  (Default: "k8s-not-the-hardest-way")
- `vpc_name`: VPC Name. Must be unique in the AWS Account (Default: "kubernetes")
- `elb_name`: ELB Name for Kubernetes API. Can only contain characters valid for DNS names. Must be unique in the AWS Account (Default: "kubernetes")
- `owner`: `Owner` tag added to all AWS resources. No functional use. It useful if you are sharing the same AWS account with others, to filter your resources on AWS console. (Default: "kubernetes")



The easiest way to do it is creating a `terraform.tfvars` [variable file](https://www.terraform.io/docs/configuration/variables.html#variable-files) in `./terraform` directory. Terraform automatically includes this file.

Example of `terraform.tfvars` variable file:
```
# Mandatory
default_keypair_public_key = "ssh-rsa AAA...zzz"
control_cidr = "123.45.67.89/32"
# Optional
default_keypair_name = "lorenzo-glf"
vpc_name = "Lorenzo ETCD"
elb_name = "lorenzo-etcd"
owner = "Lorenzo"
```


### Changing AWS Region

By default, this uses "eu-west-1" AWS Region.

To use a different Region, you have to change two additional Terraform variables:

- `region`: AWS Region (default: "eu-west-1"). Also see "Changing AWS Region", below.
- `zone`: AWS Availability Zone, in the selected Region (default: "eu-west-1a")
- `default_ami`: Choose an AMI with Ubuntu 16.04 LTS HVM, EBS-SSD, available in the new Region

You also have to **manually** modify the `./ansible/hosts/ec2.ini`, changing `regions = eu-west-1` to the Region you are using.

## Provision infrastructure with Terraform

Run Terraform commands from `./terraform` subdirectory

```
$ terraform plan
$ terraform apply
```


Terraform outputs the public DNS name to access Kubernetes API and Workers public IP.
e.g.
```
Apply complete! Resources: 12 added, 2 changed, 0 destroyed.
  ...
Outputs:

  kubernetes_api_dns_name = lorenzo-kubernetes-api-elb-1566716572.eu-west-1.elb.amazonaws.com
  kubernetes_workers_public_ip = 54.171.180.238,54.229.249.240,54.229.251.124
```

Take note of both DNS name and workers IP addresses. You will need them later (though, you may retrieve this information with `terraform output`).

### Generated SSH config

Terraform also generates `ssh.cfg` file locally, containing the aliases for accessing all VMs by name (`controller0..2`, `etcd0..2`, `worker0..2`).

This configuration file is useful for directly SSH into machines. It is NOT used by Ansible.

e.g. to access instance `worker0`
```
$ ssh -F ssh.cfg worker0
```


## Install Kubernetes with Ansible

Run Ansible commands from `./ansible` subdirectory.

### Install and set up Kubernetes cluster

Install Kubernetes services and etcd.
```
$ ansible-playbook infra.yaml
```

### Setup Kubernetes CLI

This step set up the Kubernetes CLI (`kubectl`) configuration on the control machine.
The configuration includes the DNS name of Kubernetes API endpoint, as returned by Terraform.

```
$ ansible-playbook kubectl.yaml --extra-vars "kubernetes_api_endpoint=<kubernetes-api-dns-name>"
```
The following steps uses Kubernetes CLI.

#### Verify Kubernetes CLI is working

Use Kubernetes CLI (`kubectl`) to verify all components and minions (workers) are up and running.

```
$ kubectl get componentstatuses
NAME                 STATUS    MESSAGE              ERROR
controller-manager   Healthy   ok
scheduler            Healthy   ok
etcd-2               Healthy   {"health": "true"}
etcd-1               Healthy   {"health": "true"}
etcd-0               Healthy   {"health": "true"}

$ kubectl get nodes
NAME                                       STATUS    AGE
ip-10-43-0-30.eu-west-1.compute.internal   Ready     6m
ip-10-43-0-31.eu-west-1.compute.internal   Ready     6m
ip-10-43-0-32.eu-west-1.compute.internal   Ready     6m
```

### Setup Kubernetes cluster routing

Set up additional routes for routing traffic between inside Pods cluster.

```
$ ansible-playbook kubernetes-routing.yaml
```

### Smoke test: Deploy nginx service

Deploy a ngnix service inside Kubernetes.

```
$ ansible-playbook kubernetes-nginx.yaml
```

#### Verify nginx service is running

Use Kubernetes CLI (`kubectl`) to verify pods and service are up and running.

```
$ kubectl get pods -o wide
NAME                     READY     STATUS    RESTARTS   AGE       IP           NODE
nginx-2032906785-9chju   1/1       Running   0          3m        10.200.1.2   ip-10-43-0-31.eu-west-1.compute.internal
nginx-2032906785-anu2z   1/1       Running   0          3m        10.200.2.3   ip-10-43-0-30.eu-west-1.compute.internal
nginx-2032906785-ynuhi   1/1       Running   0          3m        10.200.0.3   ip-10-43-0-32.eu-west-1.compute.internal

> kubectl get svc nginx --output=json
{
    "kind": "Service",
    "apiVersion": "v1",
    "metadata": {
        "name": "nginx",
        "namespace": "default",
...
```

Retrieve the port nginx has been exposed on:

```
$ kubectl get svc nginx --output=jsonpath='{range .spec.ports[0]}{.nodePort}'
32700
```

This port is exposed on each worker (node, minion). Refer to Terraform output for workers public IP addresses.

Now you should be able to access the nginx default page:
```
$ curl http://<worker-0-public-ip>:<exposed-port>
<!DOCTYPE html>
<html>
<head>
<title>Welcome to nginx!</title>
...
```

# Known simplifications

There are some known simplifications, compared to a production-ready solution:

- Networking setup is very simple: ALL instances have a public IP (though only accessible from a configurable Control IP).
- Infrastructure managed by direct SSH into instances (no VPN, no Bastion).
- Very basic Service Account and Secret (to change them, modify: `./ansible/roles/controller/files/token.csv` and `./ansible/roles/worker/templates/kubeconfig.j2`)
- No Load Balancer for the exposed NodePorts. No Load Balancer
- No fixed internal or external DNS naming (only dynamic names generated by AWS)
- No support for Kubernetes logging
- Simplified Ansible lifecycle. Playbooks support changes in a simplistic way, including possibly unnecessary restarts.
- Instances have static private IP addresses
- All instances use Ubuntu 16.04
