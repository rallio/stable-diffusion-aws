#!/bin/bash

set -e

# Install packages
sudo apt update
sudo apt install -y \
  git python3-venv python3-pip python3-dev build-essential net-tools \
  nginx \
  htop rsync ncdu 

# Mount instance storage
cat <<EOF | sudo tee /usr/lib/systemd/system/instance-storage.service
[Unit]
Description=Format and mount ephemeral storage
After=local-fs.target

[Service]
Type=oneshot
RemainAfterExit=true
ExecStart=/usr/sbin/mkfs.ext4 /dev/nvme1n1
ExecStart=/usr/bin/mkdir -p /mnt/ephemeral
ExecStart=/usr/bin/mount /dev/nvme1n1 /mnt/ephemeral
ExecStart=/usr/bin/chmod 777 /mnt/ephemeral
ExecStart=fallocate -l 8G /mnt/ephemeral/swapfile
ExecStart=chmod 600 /mnt/ephemeral/swapfile
ExecStart=mkswap /mnt/ephemeral/swapfile
ExecStart=swapon /mnt/ephemeral/swapfile
ExecStop=swapoff /mnt/ephemeral/swapfile
ExecStop=/usr/bin/umount /mnt/ephemeral

[Install]
WantedBy=multi-user.target
EOF
sudo systemctl enable instance-storage
sudo systemctl start instance-storage

# Reserve less space for root
sudo tune2fs -m 1 /dev/nvme0n1p1

export TMPDIR=/mnt/ephemeral/tmp
export XDG_CACHE_HOME=/mnt/ephemeral/cache
echo 'export TMPDIR=/mnt/ephemeral/tmp' | tee -a /home/ubuntu/.bashrc
echo 'export XDG_CACHE_HOME=/mnt/ephemeral/cache' | tee -a /home/ubuntu/.bashrc

sudo mkdir "$TMPDIR"
sudo mkdir "$XDG_CACHE_HOME"
sudo chmod 777 "$TMPDIR" "$XDG_CACHE_HOME"

cd /home/ubuntu
sudo -u ubuntu git clone https://github.com/AUTOMATIC1111/stable-diffusion-webui.git

# Download initial models
sudo -u ubuntu mkdir -p /home/ubuntu/stable-diffusion-webui/models/Stable-diffusion/
cd /home/ubuntu/stable-diffusion-webui/models/Stable-diffusion/

# AbsoluteReality
sudo -u ubuntu wget --no-verbose https://huggingface.co/Lykon/AbsoluteReality/resolve/main/AbsoluteReality_1.8.1_pruned.safetensors -O v1_absolutereality_v1.safetensors

# VAE
cd /home/ubuntu/stable-diffusion-webui/models/VAE/
sudo -u ubuntu wget --no-verbose https://huggingface.co/stabilityai/sd-vae-ft-mse-original/resolve/main/vae-ft-mse-840000-ema-pruned.safetensors -O vae-ft-mse-840000-ema-pruned.vae.safetensors

#  Loras
sudo -u ubuntu mkdir -p /home/ubuntu/stable-diffusion-webui/models/Lora
cd /home/ubuntu/stable-diffusion-webui/models/Lora/
sudo -u ubuntu wget --no-verbose https://huggingface.co/OedoSoldier/detail-tweaker-lora/resolve/main/add_detail.safetensors -O add_detail.safetensors

# Embeddings
sudo -u ubuntu mkdir -p /home/ubuntu/stable-diffusion-webui/embeddings
cd /home/ubuntu/stable-diffusion-webui/embeddings/
sudo -u ubuntu wget --no-verbose https://huggingface.co/datasets/gsdf/EasyNegative/resolve/main/EasyNegative.safetensors

# Upscalers
sudo -u ubuntu mkdir -p /home/ubuntu/stable-diffusion-webui/models/ESRGAN
cd /home/ubuntu/stable-diffusion-webui/models/ESRGAN/
sudo -u ubuntu wget --no-verbose https://huggingface.co/FacehugmanIII/4x_foolhardy_Remacri/resolve/main/4x_foolhardy_Remacri.pth
sudo -u ubuntu cp 4x_foolhardy_Remacri.pth "Remacri 4x.pth"

# Extensions
cd /home/ubuntu/stable-diffusion-webui/extensions/
sudo -u ubuntu git clone https://github.com/ArtVentureX/sd-webui-agent-scheduler
sudo -u ubuntu git clone https://github.com/Bing-su/adetailer.git

# The scheduler extension needs this
sudo -u ubuntu mkdir -p /mnt/ephemeral/tmp/gradio

# Install custom webui-user.sh
cat <<EOF | sudo -u ubuntu tee /home/ubuntu/stable-diffusion-webui/webui-user.sh
#!/bin/bash
export COMMANDLINE_ARGS="--xformers --medvram --no-half-vae --api"
EOF

# Install service
cat <<EOF | sudo tee /usr/lib/systemd/system/sdwebgui.service
[Unit]
Description=Stable Diffusion AUTOMATIC1111 Web UI service
After=network.target
StartLimitIntervalSec=0

[Service]
Type=simple
Restart=always
RestartSec=1
User=ubuntu
Environment=TMPDIR=/mnt/ephemeral/tmp
Environment=XDG_CACHE_HOME=/mnt/ephemeral/cache
WorkingDirectory=/home/ubuntu/stable-diffusion-webui/
ExecStart=/usr/bin/env bash /home/ubuntu/stable-diffusion-webui/webui.sh
StandardOutput=append:/var/log/sdwebui.log
StandardError=append:/var/log/sdwebui.log

[Install]
WantedBy=multi-user.target
EOF

# Enable and start service
sudo systemctl enable sdwebgui
sudo systemctl start sdwebgui

# Add password file for API authentication.
#
# rallio:5f620298-2d25-4f4b-8eb2-13e95aa2ea25
cat <<'EOF' | sudo -u ubuntu tee /home/ubuntu/htpasswd
rallio:$apr1$cQQSyP54$SDgb7unvwtzOflUKlqdw9/
EOF

# Add nginx config
cat <<'EOF' | sudo -u root tee /etc/nginx/sites-enabled/automatic1111
server {
  listen 7861;
  location / {
      auth_basic             "Restricted";
      auth_basic_user_file   /home/ubuntu/htpasswd;
      proxy_pass             http://localhost:7860;
      proxy_read_timeout     900;
  }
}
EOF

# Remove default nginx config
sudo rm -f /etc/nginx/sites-enabled/default

# Reload nginx
sudo service nginx reload
