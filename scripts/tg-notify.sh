#!/bin/bash
# ═══════════════════════════════════════════════════════════════
# 蜂巢协议 — Telegram 通知
# ═══════════════════════════════════════════════════════════════
#
# 用法:
#   bash scripts/tg-notify.sh "消息内容"
#   bash scripts/tg-notify.sh "$(cat <<MSG
#   多行消息
#   MSG
#   )"
#
# 环境变量（或硬编码）:
#   TG_BOT_TOKEN, TG_CHAT_ID, TG_THREAD_ID

TG_BOT_TOKEN="${TG_BOT_TOKEN:-8310104753:AAHmuR64fDdAxzdnn6gcxmywhh5S9YkowP4}"
TG_CHAT_ID="${TG_CHAT_ID:--1003349791999}"
TG_THREAD_ID="${TG_THREAD_ID:-9228}"

MSG="$1"
[ -z "$MSG" ] && exit 0

curl -s "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage" \
  -d chat_id="$TG_CHAT_ID" \
  -d message_thread_id="$TG_THREAD_ID" \
  -d parse_mode="Markdown" \
  -d text="$MSG" > /dev/null 2>&1
