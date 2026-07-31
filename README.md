# deploy-strongswan

## Requirements

### Ubuntu Instance Preparation

Before running Terraform, you must prepare the target Ubuntu instance by creating a limited user account that Terraform Cloud will use to execute the remote configuration script, and ensuring the firewall allows the necessary traffic.

Run the following commands on your Ubuntu server via SSH. 

#### 1. Create the Terraform Service Account
This user requires passwordless `sudo` privileges to install packages (`strongswan`, `iproute2`) and modify system files in `/etc/ipsec.*`.

```bash
# Create a limited user named 'terraform' without a password
sudo adduser --disabled-password --gecos "" terraform

# Grant the user passwordless sudo privileges
echo "terraform ALL=(ALL) NOPASSWD:ALL" | sudo tee /etc/sudoers.d/90-terraform
sudo chmod 0440 /etc/sudoers.d/90-terraform

# Create the SSH directory structure
sudo mkdir -p /home/terraform/.ssh
sudo chmod 700 /home/terraform/.ssh

# Add your Terraform Cloud public SSH key
# REPLACE the string below with your actual public key!
echo "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQ... YOUR_PUBLIC_KEY" | sudo tee /home/terraform/.ssh/authorized_keys

# Secure the keys and set ownership
sudo chmod 600 /home/terraform/.ssh/authorized_keys
sudo chown -R terraform:terraform /home/terraform/.ssh

# Allow SSH access for Terraform Cloud (Port 22)
sudo ufw allow 22/tcp

# Allow IPsec IKE and NAT Traversal 
sudo ufw allow 500,4500/udp

# Allow IPsec ESP (Encapsulating Security Payload) protocol
sudo ufw allow to any proto esp

# Enable the firewall (Type 'y' when warned about disrupting SSH)
sudo ufw enable

# Verify the rules are active
sudo ufw status
