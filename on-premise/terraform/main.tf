# main.tf

# Configure the Terraform provider for Proxmox
# Ensure you have the Proxmox API token or username/password configured
# as environment variables (e.g., PM_USER, PM_PASS, PM_HOST, PM_TLS_INSECURE)
# or replace with explicit values (not recommended for production).
terraform {
  required_providers {
    proxmox = {
      source  = "telmate/proxmox"
      version = "~> 2.9" # Use a compatible version
    }
  }
}

variable "proxmox_api_token_id" {
  type = string
}

variable "proxmox_api_token_secret" {
  type = string
}

provider "proxmox" {
  # Replace with your Proxmox host IP or hostname
  pm_tls_insecure = false # Set to false if you have valid TLS certs
  pm_api_url      = "https://mini01.bananalocal.net:8006/api2/json"

  # Option 1: Use environment variables (recommended for security)
  # pm_user = var.proxmox_user # e.g., "terraform-user@pve"
  # pm_password = var.proxmox_password # e.g., "your-api-token-secret" or "your-password"
  pm_api_token_id = var.proxmox_api_token_id # e.g., "terraform-user@pve!terraform-token"
  pm_api_token_secret = var.proxmox_api_token_secret # e.g., "your-api-token-secret"
}

# Define variables for easy customization
variable "proxmox_node" {
  description = "The Proxmox node where the LXC will be created."
  type        = string
  default     = "mini01" # Replace with your Proxmox node name (e.g., pve, node1)
}

variable "lxc_hostname" {
  description = "Hostname for the new LXC container."
  type        = string
  default     = "juice-shop.eborsec.co.uk"
}

variable "lxc_vmid" {
  description = "Virtual Machine ID for the new LXC container. Leave 0 to auto-generate."
  type        = number
  default     = 0 # Set a specific ID if needed, e.g., 101
}

variable "lxc_template" {
  description = "The Proxmox CT template to use (e.g., local:vztmpl/ubuntu-22.04-standard_22.04-1_amd64.tar.zst)."
  type        = string
  default     = "local:vztmpl/debian-12-standard_12.7-1_amd64.tar.zst"
}

variable "lxc_memory_mb" {
  description = "Memory allocated to the LXC container in MB."
  type        = number
  default     = 1024 # 1GB
}

variable "lxc_cores" {
  description = "Number of CPU cores allocated to the LXC container."
  type        = number
  default     = 1
}

variable "lxc_disk_gb" {
  description = "Root filesystem size for the LXC container in GB."
  type        = number
  default     = 10
}

# Create the LXC container
resource "proxmox_lxc" "ansible_lxc_host" {
  target_node = var.proxmox_node
  hostname    = var.lxc_hostname
  vmid        = var.lxc_vmid
  ostemplate  = var.lxc_template
  memory      = var.lxc_memory_mb
  cores       = var.lxc_cores
  ssh_public_keys = <<-EOT
    ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMuN6Z28U7R7yRmeBdq3ZedcVqN9cimBUKCF64XNQbBQ james@manjaro
  EOT
  unprivileged = true
  features {
    nesting = true
  }

  rootfs {
    storage = "local-lvm" # Adjust to your storage name (e.g., local-lvm, your-storage-name)
    size    = "${var.lxc_disk_gb}G"
  }

  network {
    name   = "eth0"
    bridge = "vmbr0"
    ip     = "dhcp"
  }

  # Start the container after creation
  start = true
}

# Output the IP address of the created LXC container
output "lxc_ip_address" {
  description = "The IP address of the newly created LXC container."
  value       = proxmox_lxc.ansible_lxc_host.network[0].ip
}