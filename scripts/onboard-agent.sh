#!/bin/bash
# ═══════════════════════════════════════════════════════════════
# 蜂巢协议 — Agent 自助准入 (v2 — 无质押，读主网余额)
# ═══════════════════════════════════════════════════════════════
#
# 检查 Agent 主网余额是否满足准入门槛 (≥100 AXON)，
# 满足则直接调 register() 完成注册。
#
# 用法:
#   bash scripts/onboard-agent.sh <agent_private_key>
#
# 流程:
#   1. 查余额 → 判断等级
#   2. 调 HiveAgent.register() → 链上注册
#   3. TG 通知
# ═══════════════════════════════════════════════════════════════

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$(dirname "$SCRIPT_DIR")/.env"

RPC="https://mainnet-rpc.axonchain.ai/"
HIVE_AGENT="$HIVE_AGENT_ADDRESS"

AGENT_KEY="${1:?用法: bash onboard-agent.sh <agent_private_key>}"
AGENT_ADDR=$(cast wallet address "$AGENT_KEY")

echo "═══ 蜂巢协议 — Agent 准入 (v2) ═══"
echo "  Agent: $AGENT_ADDR"
echo ""

# 检查是否已注册
IS_ACTIVE=$(cast call "$HIVE_AGENT" "isActive(address)(bool)" "$AGENT_ADDR" --rpc-url "$RPC" 2>&1 | awk '{print $1}')
if [ "$IS_ACTIVE" = "true" ]; then
  echo "⚠️  该 Agent 已注册激活。"
  BAL=$(cast balance "$AGENT_ADDR" --rpc-url "$RPC" -e 2>&1 | awk '{print $1}')
  echo "  主网余额: $BAL AXON"
  exit 0
fi

# 查余额
BAL_WEI=$(cast balance "$AGENT_ADDR" --rpc-url "$RPC" 2>&1)
BAL_AXON=$(python3 -c "print(f'{int(\"$BAL_WEI\") / 1e18:.2f}')")
echo "  主网余额: $BAL_AXON AXON"

BAL_INT=$(python3 -c "print(int(float('$BAL_AXON')))")
if [ "$BAL_INT" -lt 100 ]; then
  echo "❌ 余额不足 (需要 ≥ 100 AXON)"
  exit 1
fi

# 判断等级
if [ "$BAL_INT" -ge 5000 ]; then
  TIER="Diamond"
elif [ "$BAL_INT" -ge 2000 ]; then
  TIER="Gold"
elif [ "$BAL_INT" -ge 500 ]; then
  TIER="Silver"
else
  TIER="Bronze"
fi

echo "  等级: $TIER"
echo ""

# 注册
echo "[1] 调用 register()..."
cast send "$HIVE_AGENT" "register()" \
  --private-key "$AGENT_KEY" --rpc-url "$RPC" --gas-limit 200000 --legacy --gas-price 8000000000 2>&1 | head -3

echo ""
echo "═══ 注册完成 ═══"
echo "  Agent: $AGENT_ADDR"
echo "  余额: $BAL_AXON AXON"
echo "  等级: $TIER"
echo "  HiveScore: 0 (初始值)"
echo ""
echo "现在可以参与预测轮次了 (commit → reveal → settle)"

# TG 通知
bash "$SCRIPT_DIR/tg-notify.sh" "🆕 *新 Agent 注册*
地址: \`${AGENT_ADDR}\`
余额: ${BAL_AXON} AXON | 等级: ${TIER}
HiveScore: 0 (初始)"
