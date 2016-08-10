# Kubernetes not the hardest way (or "Provisioning a Kubernetes Cluster on AWS using Terraform and Ansible")

The goal of this sample project is provisioning AWS infrastructure and Kubernetes cluster, using Terraform and Ansible.
This is not meant to be production-ready, but to provide a realistic example, beyond the usual "Hello, world" ones.

Please refer to the companion blog posts: https://opencredo.com/kubernetes-aws-terraform-ansible-1/ ‎

### Target platform

The setup is based on [Kubernetes the hard way](https://github.com/kelseyhightower/kubernetes-the-hard-way). This project follows the same steps, but translating from Google Cloud to AWS and making them automatic, with Terraform and Ansible.

Infrastructure includes:

- AWS VPC
- 3 nodes HA Kubernetes Control Plane: Kubernetes API, Scheduler and Controller Manager
- 3 nodes HA etcd cluster
- 3 Kubernetes minion (worker) nodes
- Kubernetes DNS plugin
- CNI based networking
- Sample *nginx* service will be deployed, to check everything works


Still, there are some known simplifications, compared to a production-ready solution (See "Known simplifications", below)


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


## Credentials

### AWS Keypair

The easiest way to generate keypairs is using AWS console. This also creates the identity file (`.pem`) in the correct format for AWS (not trivial to do it by CLI).

**The keypair must be already loaded in AWS.**
**The identity file must be downloaded on the machine running Terraform and Ansible.**
The keypair name must be specified as part of the environment (see below).

### Terraform and Ansible authentication

Both Terraform and Ansible expects AWS credentials in environment variables:
```
> export AWS_ACCESS_KEY_ID=<access-key-id>
> export AWS_SECRET_ACCESS_KEY="<secret-key>"
```

Ansible expects ssh identity loaded into ssh agent:
```
ssh-add <keypair-name>.pem
```

## Setup variables defining the environment

Before running Terraform, you MUST set some variables defining the environment.

- `default_keypair_name`: AWS KeyPair name for all instances. The KeyPair must be already loaded in AWS (mandatory)
- `control_cidr`: The CIDR of your IP. All nodes will accept only traffic from this address only. Note this is a CIDR, not a single IP. e.g. `123.45.67.89/32` (mandatory)
- `vpc_name`: VPC Name. Must be unique in the AWS Account (Default: "kubernetes")
- `elb_name`: ELB Name for Kubernetes API. Can only contain characters valid for DNS names. Must be unique in the AWS Account (Default: "kubernetes")
- `owner`: `Owner` tag added to all AWS resources. No functional use. This is useful if you are sharing the same AWS account with others, to quickly filter your resources on AWS console. (Default: "kubernetes")


You may either set a `TF_VAR_<var-name>` environment variables for each of them, or create a `.tfvars` file (e.g. `environment.tfvars`) and pass it as parameter to Terraform:
```
> terraform plan -var-file=environment.tfvars
```  

Example of `environment.tfvars`:
```
default_keypair_name = "lorenzo-glf"
control_cidr = "123.45.67.89/32"
vpc_name = "Lorenzo Kubernetes"
elb_name = "lorenzo-kubernetes"
owner = "Lorenzo"
```

### Changing AWS Region

By default, this uses "eu-west-1" AWS Region.

To use a different Region, you have to change two additional Terraform variables:

- `region`: AWS Region (default: "eu-west-1"). Also see "Changing AWS Region", below.
- `zone`: AWS Availability Zone, in the selected Region (default: "eu-west-1a")
- `default_ami`: Choose an AMI with Unbuntu 16.04 LTS HVM, EBS-SSD, available in the new Region

You also have to **manually** modify the `./ansible/hosts/ec2.ini`, changing `regions = eu-west-1` to the Region you are using.

## Provision infrastructure with Terraform

(run Terraform commands from `./terraform` subdirectory)

```
> terraform apply -var-file=environment.tfvars
```
(if you are setting up the environment using `TF_VAR_*` env variable, you may omit `-var-file=environment.tfvars`)


Terraform outputs the DNS name to access Kubernetes API and Workers public IP.
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

Terraform also generates `ssh.cfg` file locally, containing the aliases for accessing all the nodes by name (`controller0..2`, `etcd0..2`, `worker0..2`).

e.g. to access instance `worker0`
```
> ssh -F ssh.cfg worker0
```
This configuration file is for direct connection to instances only. It is NOT used by Ansible.


## Install Kubernetes with Ansible

(run all Ansible commands from `./ansible` subdirectory)

### Install and set up Kubernetes cluster

Install Kubernetes services and etcd.
```
> ansible-playbook infra.yaml
```

### Setup Kubernetes CLI

This step set up the Kubernetes CLI (`kubectl`) configuration on the control machine.
Configuration includes the DNS name of the Kubernetes API, as returned by Terraform.

These configuration is required to run following steps that uses Kubernetes CLI.

```
> ansible-playbook kubectl.yaml --extra-vars "kubernetes_api_endpoint=<kubernetes-api-dns-name>"
```
The following steps uses Kubernetes CLI.

#### Verify Kubernetes CLI is working

Use Kubernetes CLI (`kubectl`) to verify all components and minions (workers) are up and running.

```
> kubectl get componentstatuses
NAME                 STATUS    MESSAGE              ERROR
controller-manager   Healthy   ok
scheduler            Healthy   ok
etcd-2               Healthy   {"health": "true"}
etcd-1               Healthy   {"health": "true"}
etcd-0               Healthy   {"health": "true"}

> kubectl get nodes
NAME                                       STATUS    AGE
ip-10-43-0-30.eu-west-1.compute.internal   Ready     6m
ip-10-43-0-31.eu-west-1.compute.internal   Ready     6m
ip-10-43-0-32.eu-west-1.compute.internal   Ready     6m
```

### Setup Kubernetes cluster routing

Set up additional routes for routing traffic between inside Pods cluster.

```
> ansible-playbook kubernetes-routing.yaml
```

### Setup Kubernetes DNS add-on

Install DNS add-on.

```
> ansible-playbook kubernetes-dns.yaml
```

#### Verify DNS plugin is working

Use Kubernetes CLI (`kubectl`) to verify the system service is up and running.

```
> kubectl --namespace=kube-system get svc
NAME       CLUSTER-IP   EXTERNAL-IP   PORT(S)         AGE
kube-dns   10.32.0.10   <none>        53/UDP,53/TCP   15m

> kubectl --namespace=kube-system get pods
NAME                 READY     STATUS    RESTARTS   AGE
kube-dns-v18-79maa   3/3       Running   0          41s
kube-dns-v18-bcs1f   3/3       Running   0          41s
```
### Deploy nginx service

Deploy a ngnix service inside Kubernetes.

```
> ansible-playbook kubernetes-nginx.yaml
```

#### Verify nginx service is running

Use Kubernetes CLI (`kubectl`) to verify pods and service are up and running.

```
> kubectl get pods -o wide
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
> kubectl get svc nginx --output=jsonpath='{range .spec.ports[0]}{.nodePort}'
32700
```

This port is exposed on each worker (minion) node of the cluster (refer to Terraform output for workers public IP addresses).

Now you should be able to access the nginx default page:
```
> curl http://<worker-0-public-ip>:<exposed-port>
<!DOCTYPE html>
<html>
<head>
<title>Welcome to nginx!</title>
...
```

# Known simplifications

There are some known simplifications, compared to a production-ready solution:

- Networking setup is very simple: ALL nodes have a public IP (though only accessible from a configurable Control IP).
- Not a proper High Availability setup: all nodes are in the same Availability Zone; no internal load balancer for the Kubernetes master.
- Infrastructure managed by direct SSH into nodes (no VPN, no Bastion).
- Exposed Kubernetes NodePorts are accessible from the Control IP only.
- Very basic Service Account and Secret (to change them: `./ansible/roles/controller/files/token.csv`)
- No Load Balancer for the exposed NodePorts.
- No DNS
- No support for Kubernetes logging
- Simplified Ansible lifecycle: playbooks support changes in a simplistic way, including possibly unnecessary restarts.
- Nodes have static private IP addresses. This allows nodes restarted by any external agent to rejoin the cluster without further actions (using internal DNS would allow to use dynamic IP without issues)
- All nodes use Ubuntu (16.04), possibly not the most advisable distribution for production
