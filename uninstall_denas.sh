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

echo -e "${GREEN}
===============================================
            DeNAS 服务卸载脚本
===============================================
${NC}"

# ==================== 检查配置文件 ====================
CONFIG_FILE="/etc/denas.conf"
if [ ! -f "$CONFIG_FILE" ]; then
  echo -e "${RED}错误：未找到配置文件 $CONFIG_FILE${NC}"
  echo -e "${YELLOW}请手动输入共享目录路径:${NC}"
  read -rp "输入共享目录路径: " SHARE_DIR
else
  # shellcheck disable=1090
  source "$CONFIG_FILE"
  echo -e "${GREEN}从配置文件中读取到:${NC}"
  echo -e "共享目录: ${YELLOW}$SHARE_DIR${NC}"
  echo -e "SMB共享名: ${YELLOW}$SMB_SHARE_NAME${NC}"
  echo -e "SMB用户: ${YELLOW}$SMB_USER${NC}"
fi

# ==================== 用户确认 ====================
read -rp "确定要彻底卸载DeNAS服务吗？此操作将删除所有配置且不可恢复！(y/N): " CONFIRM
if [[ ! "$CONFIRM" =~ [yY] ]]; then
  echo -e "${YELLOW}已取消卸载。${NC}"
  exit 0
fi

# ==================== 主卸载流程 ====================
echo -e "${YELLOW}[1/4] 停止服务...${NC}"
systemctl stop smbd nmbd nfs-kernel-server caddy 2>/dev/null
systemctl disable smbd nmbd nfs-kernel-server caddy 2>/dev/null

echo -e "${YELLOW}[2/4] 卸载软件包...${NC}"
apt purge -y samba nfs-kernel-server caddy php-fpm php-zip
apt autoremove -y

echo -e "${YELLOW}[3/4] 删除配置文件...${NC}"
rm -rf /var/www/h5ai
rm -f /etc/caddy/Caddyfile
rm -f /etc/samba/smb.conf    # 直接删除（不备份）
rm -f /etc/exports           # 直接删除（不备份）

# 共享目录处理
if [ -d "$SHARE_DIR" ]; then
  read -rp "是否删除共享目录 $SHARE_DIR 及其所有内容？(y/N): " DEL_DATA
  if [[ "$DEL_DATA" =~ [yY] ]]; then
    rm -rf "$SHARE_DIR"
    echo -e "${RED}已彻底删除共享目录数据。${NC}"
  else
    echo -e "${YELLOW}重置共享目录权限为 root:root...${NC}"
    chown -R root:root "$SHARE_DIR"
    chmod -R 755 "$SHARE_DIR"
  fi
else
  echo -e "${YELLOW}共享目录 $SHARE_DIR 不存在，跳过处理。${NC}"
fi

echo -e "${YELLOW}[4/4] 清理用户...${NC}"
if [ -n "$SMB_USER" ] && id "$SMB_USER" &>/dev/null; then
  pdbedit -x "$SMB_USER" 2>/dev/null
  userdel "$SMB_USER" 2>/dev/null
  echo -e "已移除用户 ${YELLOW}$SMB_USER${NC}"
fi

# 删除安装记录
rm -f "$CONFIG_FILE"

echo -e "${GREEN}
===============================================
           卸载完成！以下内容已被永久删除：
   - 所有相关服务及软件包
   - 全部配置文件（无备份）
   $( [ -d "$SHARE_DIR" ] && echo "   - 共享目录权限已重置" || echo "   - 共享目录不存在" )
===============================================
${NC}"