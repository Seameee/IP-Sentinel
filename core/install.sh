#!/bin/bash

# ==========================================================
# 脚本名称: install.sh (IP-Sentinel 一键部署脚本 V3.0 终极版)
# 核心功能: 解析 JSON 冷数据、部署核心引擎、配置高频调度与互动守护
# ==========================================================

# 你的专属 Forgejo 仓库 Raw 数据直链前缀
REPO_RAW_URL="https://git.94211762.xyz/hotyue/IP-Sentinel/raw/branch/main"
INSTALL_DIR="/opt/ip_sentinel"
CONFIG_FILE="${INSTALL_DIR}/config.conf"

echo "========================================================"
echo "      🛡️ 欢迎使用 IP-Sentinel (VPS IP 自动养护哨兵)"
echo "========================================================"

# 1. 依赖检查与安装
echo -e "\n[1/6] 正在安装必要环境依赖 (curl, jq, cron, procps)..."
if [ -f /etc/debian_version ]; then
    apt-get update -y >/dev/null 2>&1
    apt-get install -y curl jq cron procps >/dev/null 2>&1
elif [ -f /etc/redhat-release ]; then
    yum install -y curl jq cronie procps-ng >/dev/null 2>&1
    systemctl enable crond && systemctl start crond
else
    echo "⚠️ 未知系统，请确保已手动安装 curl, jq 和 pgrep"
fi

# 2. 本地工作目录初始化
mkdir -p "${INSTALL_DIR}/core"
mkdir -p "${INSTALL_DIR}/data/keywords"
mkdir -p "${INSTALL_DIR}/logs"

# 3. 交互式引导
echo -e "\n[2/6] 请选择你要伪装的目标区域:"
echo "  1) 🇯🇵 日本 (东京 - JP)"
echo "  2) 🇺🇸 美国 (美西 - US)"
read -p "请输入选择 [1-2] (默认1): " REGION_CHOICE

case ${REGION_CHOICE:-1} in
    2) REGION_CODE="US" ;;
    *) REGION_CODE="JP" ;;
esac

echo -e "\n[3/6] 是否配置 Telegram 机器人进行互动控制与战报接收？(y/n)"
read -p "请输入选择 [y/n] (默认n): " TG_CHOICE
TG_TOKEN=""
CHAT_ID=""
if [[ "$TG_CHOICE" =~ ^[Yy]$ ]]; then
    read -p "请输入 Telegram Bot Token: " TG_TOKEN
    read -p "请输入你的 Chat ID: " CHAT_ID
fi

# 4. 远程拉取冷数据并解析固化
echo -e "\n[4/6] 正在从你的数据仓库拉取 [${REGION_CODE}] 节点的底层规则..."
REGION_JSON=$(curl -sL "${REPO_RAW_URL}/data/regions/${REGION_CODE}.json")

# 使用 jq 提取 JSON 里的核心值
REGION_NAME=$(echo "$REGION_JSON" | jq -r '.region_name')
BASE_LAT=$(echo "$REGION_JSON" | jq -r '.google_module.base_lat')
BASE_LON=$(echo "$REGION_JSON" | jq -r '.google_module.base_lon')
LANG_PARAMS=$(echo "$REGION_JSON" | jq -r '.google_module.lang_params')
VALID_URL_SUFFIX=$(echo "$REGION_JSON" | jq -r '.google_module.valid_url_suffix')

if [ -z "$BASE_LAT" ] || [ "$BASE_LAT" == "null" ]; then
    echo "❌ 拉取或解析规则失败！请检查 Forgejo 仓库是否公开或网络是否畅通。"
    exit 1
fi

# 写入本地静态配置文件
cat > "$CONFIG_FILE" << EOF
# IP-Sentinel 本地固化配置 (生成时间: $(date '+%Y-%m-%d %H:%M:%S'))
REGION_CODE="$REGION_CODE"
REGION_NAME="$REGION_NAME"
BASE_LAT="$BASE_LAT"
BASE_LON="$BASE_LON"
LANG_PARAMS="$LANG_PARAMS"
VALID_URL_SUFFIX="$VALID_URL_SUFFIX"

TG_TOKEN="$TG_TOKEN"
CHAT_ID="$CHAT_ID"
INSTALL_DIR="$INSTALL_DIR"
LOG_FILE="${INSTALL_DIR}/logs/sentinel.log"
EOF

# 5. 拉取全套组件 (引擎、业务、更新、战报、守护进程及热数据)
echo -e "\n[5/6] 正在部署核心引擎、互动组件与热数据..."
curl -sL "${REPO_RAW_URL}/core/runner.sh" -o "${INSTALL_DIR}/core/runner.sh"
curl -sL "${REPO_RAW_URL}/core/mod_google.sh" -o "${INSTALL_DIR}/core/mod_google.sh"
curl -sL "${REPO_RAW_URL}/core/updater.sh" -o "${INSTALL_DIR}/core/updater.sh"
curl -sL "${REPO_RAW_URL}/core/tg_report.sh" -o "${INSTALL_DIR}/core/tg_report.sh"
curl -sL "${REPO_RAW_URL}/core/tg_daemon.sh" -o "${INSTALL_DIR}/core/tg_daemon.sh"
chmod +x ${INSTALL_DIR}/core/*.sh

curl -sL "${REPO_RAW_URL}/data/user_agents.txt" -o "${INSTALL_DIR}/data/user_agents.txt"
curl -sL "${REPO_RAW_URL}/data/keywords/kw_${REGION_CODE}.txt" -o "${INSTALL_DIR}/data/keywords/kw_${REGION_CODE}.txt"

# 6. 配置系统定时任务 (高频调度与看门狗)
echo -e "\n[6/6] 正在注入系统定时任务与看门狗进程..."
crontab -l 2>/dev/null | grep -v "ip_sentinel" > /tmp/cron_backup

# 【升级点】核心养护模块: 改为每 30 分钟触发一次
echo "*/30 * * * * ${INSTALL_DIR}/core/runner.sh >/dev/null 2>&1" >> /tmp/cron_backup
# 养料更新模块: 每周日凌晨 3 点静默去云端更新热数据
echo "0 3 * * 0 ${INSTALL_DIR}/core/updater.sh >/dev/null 2>&1" >> /tmp/cron_backup

# 【升级点】TG 相关任务
if [[ -n "$TG_TOKEN" ]] && [[ -n "$CHAT_ID" ]]; then
    # 每天早上 8 点发送昨天的统计战报
    echo "0 8 * * * ${INSTALL_DIR}/core/tg_report.sh >/dev/null 2>&1" >> /tmp/cron_backup
    # 守护进程看门狗: 每分钟检查一次 tg_daemon.sh，如果掉了就拉起来
    echo "* * * * * pgrep -f tg_daemon.sh >/dev/null || nohup bash ${INSTALL_DIR}/core/tg_daemon.sh >/dev/null 2>&1 &" >> /tmp/cron_backup
    
    # 安装时立刻启动一次守护进程
    pgrep -f tg_daemon.sh >/dev/null || nohup bash "${INSTALL_DIR}/core/tg_daemon.sh" >/dev/null 2>&1 &
fi

crontab /tmp/cron_backup
rm -f /tmp/cron_backup

echo "========================================================"
echo "🎉 IP-Sentinel 部署流程彻底完成！"
echo "📍 你的本地守护区域已锁定为: $REGION_NAME"
echo "⚙️ 哨兵现已开启 [每30分钟] 的高频高拟真养护循环。"
if [[ -n "$TG_TOKEN" ]]; then
    echo "📱 Telegram 互动控制中心已上线！"
    echo "   马上打开 TG 给你的机器人发送 /help 试试吧！"
fi
echo "========================================================"