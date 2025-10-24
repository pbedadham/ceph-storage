# 🧰 Ceph Cluster on AWS (Terraform + Ansible)

## 📋 Overview

This project provisions a **secure AWS environment** using Terraform and installs a **3-node Ceph cluster** (via `cephadm`) with Ansible.

### Components

* **Terraform**:

  * 1 × **VPC**
  * 1 × **Public subnet** (bastion + NAT gateway)
  * 1 × **Private subnet** (for Ceph nodes)
  * 1 × **Internet Gateway** + **NAT Gateway**
  * 1 × **Bastion host** (public IP)
  * 3 × **Private EC2 nodes** (Ceph cluster)
* **Ansible**:

  * Prepares all Ceph nodes
  * Installs `cephadm` and bootstraps cluster
  * Adds all 3 nodes into the Ceph orchestrator
  * Optionally deploys OSDs, MONs, MGRs

---

## 🪄 Prerequisites

* **Local tools**

  * Terraform ≥ 1.5.0
  * Ansible ≥ 9.0.0
  * AWS CLI configured with valid credentials
  * SSH key pair (`~/.ssh/id_rsa` and `~/.ssh/id_rsa.pub`)
* **AWS Permissions**

  * IAM permissions to create EC2, VPC, Subnet, IGW, NAT Gateway, and Elastic IP.

---

## 🧱 Step 1 — Create Infrastructure with Terraform

### 1. Clone or copy files

```
terraform/
 ├── main.tf
 ├── variables.tf
 ├── outputs.tf
```

### 2. Initialize Terraform

```bash
cd terraform
terraform init
```

### 3. Plan and Apply

```bash
terraform plan -out plan.out
terraform apply "plan.out"
```

### 4. Check Outputs

Terraform will display:

```
bastion_public_ip = 3.91.x.x
private_node_ips  = ["10.0.2.10", "10.0.2.11", "10.0.2.12"]
nat_gateway_public_ip = 54.201.x.x
```

✅ **Result**:

* Bastion (public subnet, reachable via SSH)
* 3 Private nodes (no public IP, routed via NAT)

---

## 🔐 Step 2 — SSH Access Configuration

### SSH via Bastion

From your **local machine**:

```bash
ssh -A ec2-user@<BASTION_PUBLIC_IP>
```

If agent forwarding is disabled, copy your private key manually:

```bash
scp -i ~/.ssh/id_rsa ~/.ssh/id_rsa ec2-user@<BASTION_PUBLIC_IP>:~/.ssh/id_rsa
chmod 600 ~/.ssh/id_rsa
```

Then inside the bastion:

```bash
ssh ec2-user@10.0.2.10
```

---

## 🧩 Step 3 — Configure Ansible

### File Layout

```
ansible/
 ├── ansible.cfg
 ├── inventory.ini
 ├── group_vars/
 │   └── ceph.yml
 └── ceph_deploy.yml
```

### Example Inventory (`inventory.ini`)

```ini
[bastion]
bastion ansible_host=<BASTION_PUBLIC_IP> ansible_user=ec2-user

[ceph]
node1 ansible_host=10.0.2.10 ansible_user=ec2-user
node2 ansible_host=10.0.2.11 ansible_user=ec2-user
node3 ansible_host=10.0.2.12 ansible_user=ec2-user

[ceph:vars]
ansible_ssh_common_args='-o ProxyJump=ec2-user@<BASTION_PUBLIC_IP>'
ansible_become=true
ansible_become_method=sudo
```

### `ansible.cfg`

```ini
[defaults]
inventory = ./inventory.ini
host_key_checking = False
stdout_callback = yaml
bin_ansible_callbacks = True
forks = 20
interpreter_python = auto_silent
```

---

## ⚙️ Step 4 — Ceph Deployment

### 1. Install Requirements

```bash
pip install "ansible>=9.0.0"
```

### 2. Run the Playbook

```bash
ansible-playbook -i inventory.ini ceph_deploy.yml
```

### 3. Verify

SSH into node1 (bootstrap node):

```bash
ssh -A ec2-user@<BASTION_PUBLIC_IP>
ssh ec2-user@10.0.2.10
sudo ceph -s
```

You should see something like:

```
cluster:
  id:  <uuid>
  health: HEALTH_OK

services:
  mon: 3 daemons
  mgr: 2 daemons
  osd: 3 osds
```

---

## 🧠 Step 5 — Optional Enhancements

| Feature                  | Description                                                              |
| ------------------------ | ------------------------------------------------------------------------ |
| **Bastion hardening**    | Restrict SSH CIDR in Terraform SG                                        |
| **Ceph dashboard**       | Access via `ceph dashboard create-self-signed-cert && ceph mgr services` |
| **OSD provisioning**     | Set `osd_all_available_devices: true` in `group_vars/ceph.yml`           |
| **Ansible Proxy Config** | Add `ProxyJump` section to `~/.ssh/config` for seamless access           |

---

## 🧹 Step 6 — Cleanup

Destroy everything:

```bash
terraform destroy
```

---

## 🧩 Directory Tree Summary

```
aws-ceph/
├── terraform/
│   ├── main.tf
│   ├── variables.tf
│   ├── outputs.tf
└── ansible/
    ├── ansible.cfg
    ├── inventory.ini
    ├── group_vars/
    │   └── ceph.yml
    └── ceph_deploy.yml
```

---

## 📚 References

* [Cephadm Documentation](https://docs.ceph.com/en/latest/cephadm/)
* [RHEL / Amazon Linux Ceph Packages](https://access.redhat.com/articles/ceph)
* [AWS EC2 Key Pairs](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/ec2-key-pairs.html)
* [Terraform AWS Provider](https://registry.terraform.io/providers/hashicorp/aws/latest/docs)

---

## ✅ Quick Recap

| Step | Task                                                     | Tool      |
| ---- | -------------------------------------------------------- | --------- |
| 1    | Provision VPC, subnets, bastion, and 3 private EC2 nodes | Terraform |
| 2    | SSH via bastion to test connectivity                     | SSH       |
| 3    | Configure Ansible inventory and vars                     | Ansible   |
| 4    | Deploy Ceph cluster (bootstrap + join)                   | Ansible   |
| 5    | Verify cluster health                                    | Ceph CLI  |

