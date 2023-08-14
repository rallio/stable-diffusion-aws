#!/bin/sh

set -e

CUDA_VERSION="12.2.0"
CUDA_FULL_VERSION="12.2.0_535.54.03"
INSTALL_AUTOMATIC1111="$(curl -s http://169.254.169.254/latest/meta-data/tags/instance/INSTALL_AUTOMATIC1111)"
INSTALL_INVOKEAI="$(curl -s http://169.254.169.254/latest/meta-data/tags/instance/INSTALL_INVOKEAI)"
GUI_TO_START="$(curl -s http://169.254.169.254/latest/meta-data/tags/instance/GUI_TO_START)"

echo "Configuration: INSTALL_AUTOMATIC1111=$INSTALL_AUTOMATIC1111, INSTALL_INVOKEAI=$INSTALL_INVOKEAI, GUI_TO_START=$GUI_TO_START"

sudo apt update
# sudo apt upgrade -y
# Essential packages
sudo apt install git python3-venv python3-pip python3-dev build-essential net-tools linux-headers-cloud-amd64 -y
# Useful tools
sudo apt install -y tmux htop rsync ncdu linux-source linux-headers-`uname -r`
# Remove if you don't want my tmux config
# sudo -u admin wget --no-verbose https://raw.githubusercontent.com/mikeage/dotfiles/master/.tmux.conf -P /home/admin/
# sudo -u admin wget --no-verbose https://raw.githubusercontent.com/mikeage/dotfiles/master/.tmux.conf.local -P /home/admin/
# I like alacritty
# wget https://raw.githubusercontent.com/alacritty/alacritty/master/extra/alacritty.info && tic -xe alacritty,alacritty-direct alacritty.info && rm alacritty.info

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
ExecStart=dd if=/dev/zero of=/mnt/ephemeral/swapfile bs=1G count=8
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

# install CUDA (from https://developer.nvidia.com/cuda-downloads)
cd /mnt/ephemeral
sudo -u admin wget --no-verbose https://developer.download.nvidia.com/compute/cuda/$CUDA_VERSION/local_installers/cuda_${CUDA_FULL_VERSION}_linux.run
sudo sh cuda_${CUDA_FULL_VERSION}_linux.run --silent
sudo -u admin rm cuda_${CUDA_FULL_VERSION}_linux.run

export TMPDIR=/mnt/ephemeral/tmp
export XDG_CACHE_HOME=/mnt/ephemeral/cache
echo 'export TMPDIR=/mnt/ephemeral/tmp' | tee -a /home/admin/.bashrc
echo 'export XDG_CACHE_HOME=/mnt/ephemeral/cache' | tee -a /home/admin/.bashrc

sudo mkdir $TMPDIR
sudo mkdir $XDG_CACHE_HOME
sudo chmod 777 $TMPDIR $XDG_CACHE_HOME

sudo -u admin -E pip install --upgrade pip --no-warn-script-location

if [ "$INSTALL_AUTOMATIC1111" = "true" ]; then
cd /home/admin
sudo -u admin git clone https://github.com/AUTOMATIC1111/stable-diffusion-webui.git

# Download initial models
sudo -u admin mkdir -p /home/admin/stable-diffusion-webui/models/Stable-diffusion/
cd /home/admin/stable-diffusion-webui/models/Stable-diffusion/
sudo -u admin wget --no-verbose https://huggingface.co/stabilityai/stable-diffusion-2-1-base/resolve/main/v2-1_512-ema-pruned.ckpt
sudo -u admin wget --no-verbose https://huggingface.co/stabilityai/stable-diffusion-2-1/resolve/main/v2-1_768-ema-pruned.ckpt
sudo -u admin wget --no-verbose https://raw.githubusercontent.com/Stability-AI/stablediffusion/main/configs/stable-diffusion/v2-inference.yaml -O v2-1_512-ema-pruned.yaml
sudo -u admin wget --no-verbose https://raw.githubusercontent.com/Stability-AI/stablediffusion/main/configs/stable-diffusion/v2-inference-v.yaml -O v2-1_768-ema-pruned.yaml
# AbsoluteReality
# match the filename we use in our Ruby wrapper
sudo -u admin wget --no-verbose https://huggingface.co/Lykon/AbsoluteReality/resolve/main/AbsoluteReality_1.8.1_pruned.safetensors -O v1_absolutereality_v1.safetensors

# Download VAE
cd /home/admin/stable-diffusion-webui/models/VAE/
# Again we match the filename we use in our Ruby wrapper
sudo -u admin wget --no-verbose https://huggingface.co/stabilityai/sd-vae-ft-mse-original/resolve/main/vae-ft-mse-840000-ema-pruned.safetensors -O vae-ft-mse-840000-ema-pruned.vae.safetensors

#  Loras
mkdir -p /home/admin/stable-diffusion-webui/models/Lora
cd /home/admin/stable-diffusion-webui/models/Lora/
sudo -u admin wget --no-verbose https://huggingface.co/OedoSoldier/detail-tweaker-lora/resolve/main/add_detail.safetensors -O add_detail.safetensors

# Embeddings
mkdir -p /home/admin/stable-diffusion-webui/embeddings
cd /home/admin/stable-diffusion-webui/embeddings/
sudo -u admin wget --no-verbose https://huggingface.co/datasets/gsdf/EasyNegative/resolve/main/EasyNegative.safetensors

# Upscalers
mkdir -p /home/admin/stable-diffusion-webui/models/ESRGAN
cd /home/admin/stable-diffusion-webui/models/ESRGAN/
sudo -u admin wget --no-verbose https://huggingface.co/FacehugmanIII/4x_foolhardy_Remacri/resolve/main/4x_foolhardy_Remacri.pth
# This matches what we're already using
cp 4x_foolhardy_Remacri.pth "Remacri 4x.pth"

# Extensions
cd /home/admin/stable-diffusion-webui/extensions/
git clone https://github.com/ArtVentureX/sd-webui-agent-scheduler
git clone https://github.com/Bing-su/adetailer.git

# The scheduler extension needs this
mkdir -p /mnt/ephemeral/tmp/gradio



cat <<EOF | sudo tee /usr/lib/systemd/system/sdwebgui.service
[Unit]
Description=Stable Diffusion AUTOMATIC1111 Web UI service
After=network.target
StartLimitIntervalSec=0

[Service]
Type=simple
Restart=always
RestartSec=1
User=admin
Environment=TMPDIR=/mnt/ephemeral/tmp
Environment=XDG_CACHE_HOME=/mnt/ephemeral/cache
WorkingDirectory=/home/admin/stable-diffusion-webui/
ExecStart=/usr/bin/env bash /home/admin/stable-diffusion-webui/webui.sh
StandardOutput=append:/var/log/sdwebui.log
StandardError=append:/var/log/sdwebui.log

[Install]
WantedBy=multi-user.target
EOF
# sudo systemctl enable sdwebgui
fi

if [ "$INSTALL_INVOKEAI" = "true" ]; then
export INVOKEAI_ROOT=/home/admin/invokeai
echo 'export INVOKEAI_ROOT=/home/admin/invokeai' | tee -a /home/admin/.bashrc
sudo -u admin -E mkdir $INVOKEAI_ROOT
sudo -u admin -E /home/admin/.local/bin/pip install "InvokeAI[xformers]" --use-pep517 --extra-index-url https://download.pytorch.org/whl/cu117 --no-warn-script-location
sudo apt install -y python3-opencv libopencv-dev
sudo -u admin -E /home/admin/.local/bin/pip install pypatchmatch --no-warn-script-location
sudo -u admin -E /home/admin/.local/bin/invokeai-configure --yes --skip-sd-weights
# Manually add the SD 1.5 and 2.1 model
sudo -u admin -E /home/admin/.local/bin/invokeai-model-install --yes --add runwayml/stable-diffusion-v1-5
#sudo -u admin -E /home/admin/.local/bin/invokeai-model-install --yes --add stabilityai/stable-diffusion-2-1-base # 512 version
sudo -u admin -E /home/admin/.local/bin/invokeai-model-install --yes --add stabilityai/stable-diffusion-2-1

cat <<EOF | sudo tee /usr/lib/systemd/system/invokeai.service
[Unit]
Description=Invoke AI GUI
After=network.target
StartLimitIntervalSec=0

[Service]
Type=simple
Restart=always
RestartSec=1
User=admin
Environment=INVOKEAI_ROOT=/home/admin/invokeai
Environment=TMPDIR=/mnt/ephemeral/tmp
Environment=XDG_CACHE_HOME=/mnt/ephemeral/cache
WorkingDirectory=/home/admin/invokeai
ExecStart=/home/admin/.local/bin/invokeai-web
StandardOutput=append:/var/log/invokeai.log
StandardError=append:/var/log/invokeai.log

[Install]
WantedBy=multi-user.target
EOF
# sudo systemctl enable invokeai

# Customize a few parameters
sudo wget https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64 -O /usr/local/bin/yq && sudo chmod +x /usr/local/bin/yq
sudo -u admin -E yq e -i '.InvokeAI.Features.nsfw_checker = false' $INVOKEAI_ROOT/invokeai.yaml
# Default is 2.75, but that's also assuming an 8GB card
sudo -u admin -E yq e -i '.InvokeAI.Memory/Performance.max_vram_cache_size = 8' $INVOKEAI_ROOT/invokeai.yaml

fi

if [ "$GUI_TO_START" = "automatic1111" ]; then
sudo systemctl enable sdwebgui
sudo systemctl start sdwebgui
# journalctl -u sdwebgui --follow --no-tail
# tail -f /var/log/sdwebui.log
fi
if [ "$GUI_TO_START" = "invokeai" ]; then
sudo systemctl enable invokeai
sudo systemctl start invokeai
fi
