#!/bin/bash

# ==========================================================
# 脚本名称: tg_report.sh (Telegram 每日战报模块)
# 核心功能: 分析日志并推送 24 小时统计数据到 TG
# ==========================================================

INSTALL_DIR="/opt/ip_sentinel"
CONFIG_FILE="${INSTALL_DIR}/config.conf"
LOG_FILE="${INSTALL_DIR}/logs/sentinel.log"

# 1. 加载配置并自检
if [ ! -f "$CONFIG_FILE" ]; then exit 1; fi
source "$CONFIG_FILE"

if [ -z "$TG_TOKEN" ] || [ -z "$CHAT_ID" ]; then
    echo "⚠️ 未配置 Telegram 机器人参数，取消播报。"
    exit 0
fi

# 2. 截取过去 24 小时的日志
LOG_CONTENT=$(find "$LOG_FILE" -mtime -1 -exec cat {} \; 2>/dev/null)

if [ -z "$LOG_CONTENT" ]; then
    MSG="⚠️ **IP-Sentinel 警告**%0A过去 24 小时内没有检测到 [${REGION_NAME}] 节点的运行日志，请检查守护进程！"
else
    # 3. 数据精准分析
    TOTAL_SESSIONS=$(echo "$LOG_CONTENT" | grep "\[START\]" -c)
    SUCCESS_COUNT=$(echo "$LOG_CONTENT" | grep "✅" -c)
    FAILED_COUNT=$(echo "$LOG_CONTENT" | grep "❌" -c)
    UNKNOWN_COUNT=$(echo "$LOG_CONTENT" | grep "⚠️" -c)
    
    LAST_SCORE=$(echo "$LOG_CONTENT" | grep "\[SCORE\]" | tail -n 1 | awk -F'] ' '{print $2}')
    
    if [ "$TOTAL_SESSIONS" -gt 0 ]; then
        RATE=$(awk "BEGIN {printf \"%.1f\", ($SUCCESS_COUNT/$TOTAL_SESSIONS)*100}")
    else
        RATE=0
    fi

    # 动态国旗
    case "$REGION_CODE" in
        "JP") FLAG="🇯🇵" ;;
        "US") FLAG="🇺🇸" ;;
        "DE") FLAG="🇩🇪" ;;
        "SG") FLAG="🇸🇬" ;;
        *) FLAG="🌐" ;;
    esac

    # 4. 组装 Markdown 消息体
    read -r -d '' MSG <<EOT
📊 **IP-Sentinel 每日简报 (${FLAG} ${REGION_NAME})**
----------------------------
🚀 过去24H执行: ${TOTAL_SESSIONS} 次
✅ 成功伪装: ${SUCCESS_COUNT} 次
❌ 判定送中: ${FAILED_COUNT} 次
⚠️ 未知跳转: ${UNKNOWN_COUNT} 次
📈 当前成功率: **${RATE}%**

🎯 最近一次结论: 
${LAST_SCORE:-"暂无数据"}
----------------------------
💡 哨兵正在后台默默守护您的 IP。
EOT
fi

# 5. 调用 API 推送
curl -s -m 10 -X POST "https://api.telegram.org/bot${TG_TOKEN}/sendMessage" \
    -d "chat_id=${CHAT_ID}" \
    -d "text=${MSG}" \
    -d "parse_mode=Markdown" > /dev/null

echo "✅ Telegram 统计数据发送指令已执行！请检查手机。"