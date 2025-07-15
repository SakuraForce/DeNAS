#!/bin/bash

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m' # No Color

# 检查root权限
if [ "$(id -u)" -ne 0 ]; then
  echo -e "${RED}错误：此脚本必须以root用户运行！${NC}" >&2
  exit 1
fi

# 打印标题
echo -e "${GREEN}
===============================================
            DeNAS 自动化部署脚本
===============================================
${NC}"

# 记录开始时间
START_TIME=$(date +%s)

# ==================== 用户输入 ====================
echo -e "${YELLOW}[步骤1/5] 请输入以下配置信息：${NC}"

# 共享目录路径
read -rp "1. 输入NAS共享目录路径（默认：/mnt/denas/shared）: " SHARE_DIR
SHARE_DIR=${SHARE_DIR:-"/mnt/denas/shared"}

# SMB配置
read -rp "2. 输入SMB共享名称（默认：shared）: " SMB_SHARE_NAME
SMB_SHARE_NAME=${SMB_SHARE_NAME:-"shared"}

# NFS配置
read -rp "3. 输入允许访问NFS的IP段（默认：*）: " NFS_CLIENTS
NFS_CLIENTS=${NFS_CLIENTS:-"*"}

# ==================== 检查并安装依赖 ====================
echo -e "${YELLOW}[步骤2/5] 检查并安装依赖包...${NC}"

# 定义必要软件包
REQUIRED_PACKAGES=(
  "samba"
  "nfs-kernel-server"
  "caddy"
  "unzip"
  "php-fpm"
  "php-zip"
  "curl"
  "wget"
)

# 安装缺失的包
for pkg in "${REQUIRED_PACKAGES[@]}"; do
  if ! dpkg -l | grep -q "^ii  $pkg "; then
    echo -e "${YELLOW}安装 $pkg ...${NC}"
    apt install -y "$pkg" || {
      echo -e "${RED}安装 $pkg 失败！${NC}"
      exit 1
    }
  fi
done

# ==================== 配置共享目录 ====================
echo -e "${YELLOW}[步骤3/5] 配置共享目录...${NC}"
mkdir -p "$SHARE_DIR"
chown -R nobody:nogroup "$SHARE_DIR"
chmod -R 2777 "$SHARE_DIR"

# ==================== 配置SMB ====================
echo -e "${YELLOW}[步骤4/5] 配置Samba...${NC}"

# 配置共享 - 允许匿名访问
grep -q "\[$SMB_SHARE_NAME\]" /etc/samba/smb.conf || {
  cat >> /etc/samba/smb.conf <<EOF
[$SMB_SHARE_NAME]
   path = $SHARE_DIR
   browseable = yes
   read only = no
   guest ok = yes
   guest only = yes
   create mask = 0664
   directory mask = 0775
   force group = nogroup
EOF
}

systemctl restart smbd nmbd

# ==================== 配置NFS ====================
echo -e "${YELLOW}[步骤5/5] 配置NFS...${NC}"
grep -q "$SHARE_DIR" /etc/exports || {
  echo "$SHARE_DIR $NFS_CLIENTS(rw,sync,no_subtree_check,no_root_squash)" >> /etc/exports
}
exportfs -a
systemctl restart nfs-kernel-server

# ==================== h5ai & Caddy 配置 ====================
echo -e "${YELLOW}[h5ai 配置]${NC}"

# 询问域名和端口
read -rp "输入Caddy访问域名（留空使用IP）: " CADDY_DOMAIN
read -rp "输入h5ai端口号（默认80）: " CADDY_PORT
CADDY_PORT=${CADDY_PORT:-80}

# 确定监听地址
if [ -n "$CADDY_DOMAIN" ]; then
  CADDY_ADDRESS="$CADDY_DOMAIN:$CADDY_PORT"
else
  CADDY_ADDRESS=":$CADDY_PORT"
fi

# 下载h5ai到共享目录
echo -e "${YELLOW}下载h5ai...${NC}"
H5AI_DIR="$SHARE_DIR/_h5ai"
mkdir -p "$H5AI_DIR"
wget -qO /tmp/h5ai.zip https://github.com/lrsjng/h5ai/releases/download/v0.30.0/h5ai-0.30.0.zip
unzip -qo /tmp/h5ai.zip -d "$H5AI_DIR"
rm /tmp/h5ai.zip

# 设置权限
chown -R www-data:www-data "$H5AI_DIR"
chmod -R 755 "$H5AI_DIR"

# 生成Caddy配置
echo -e "${YELLOW}生成Caddy配置...${NC}"
mkdir -p /etc/caddy
cat > /etc/caddy/Caddyfile <<EOF
$CADDY_ADDRESS {
    root * $H5AI_DIR
    file_server {
        index /public/index.php index.php
    }
    php_fastcgi unix//run/php/php-fpm.sock {
        index /public/index.php
    }
    @redirected {
        path /private/*
    }
    redir @redirected /
    log {
        output file /var/log/caddy/h5ai.log
    }
}
EOF

# 创建日志目录
mkdir -p /var/log/caddy
chown -R caddy:caddy /var/log/caddy

# 重新启动Caddy
systemctl restart caddy

# ==================== 记录安装配置 ====================
echo -e "${YELLOW}[额外步骤] 记录安装配置...${NC}"
cat > /etc/denas.conf <<EOF
# DeNAS 配置文件
SHARE_DIR="$SHARE_DIR"
SMB_SHARE_NAME="$SMB_SHARE_NAME"
EOF

chmod 600 /etc/denas.conf

# ==================== 生成报告 ====================
END_TIME=$(date +%s)
RUNTIME=$((END_TIME - START_TIME))

echo -e "${GREEN}
===============================================
           部署成功！用时 ${RUNTIME} 秒
===============================================
${NC}"
echo -e "共享目录: ${YELLOW}$SHARE_DIR${NC}"
echo -e "SMB 访问:"
echo -e "  - Windows: ${YELLOW}\\\\$(hostname -I | awk '{print $1}')\\$SMB_SHARE_NAME${NC}"
echo -e "  - 匿名访问已启用"
echo -e "NFS 挂载命令: ${YELLOW}sudo mount -t nfs $(hostname -I | awk '{print $1}'):$SHARE_DIR /mnt/local_mount${NC}"
echo -e "h5ai 访问地址: ${YELLOW}http://$(hostname -I | awk '{print $1}'):$CADDY_ADDRESS"
echo -e "${GREEN}===============================================${NC}"

exit 0