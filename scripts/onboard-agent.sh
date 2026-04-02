#!/bin/bash
# ═══════════════════════════════════════════════════════════════
# 蜂巢协议 — Agent 准入（Operator 执行）
# ═══════════════════════════════════════════════════════════════
#
# 为新 Agent 设置初始声誉，解锁 Bronze 注册资格。
# Agent 拿到资格后自己调 register(axonAmount) 完成注册。
#
# 用法:
#   bash scripts/onboard-agent.sh <agent_address>
#   bash scripts/onboard-agent.sh <agent_address> --reputation 30  # 直接给白银
#
# 前置条件:
#   - .env 中 OPERATOR_PRIVATE_KEY 是 HiveAgent 的 admin
#   - Agent 需要自己持有足够的 AXON 代币和 Gas
# ═══════════════════════════════════════════════════════════════

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$(dirname "$SCRIPT_DIR")/.env"

RPC="https://mainnet-rpc.axonchain.ai/"
HIVE_AGENT="$HIVE_AGENT_ADDRESS"

AGENT_ADDR="${1:?用法: bash onboard-agent.sh <agent_address>}"
REP=10

while [[ $# -gt 1 ]]; do
  case $2 in
    --reputation) REP="$3"; shift 2 ;;
    *) shift ;;
  esac
done

echo "═══ 蜂巢协议 — Agent 准入 ═══"
echo "  Agent: $AGENT_ADDR"
echo "  设置声誉: $REP"
echo ""

# 检查是否已注册
IS_ACTIVE=$(cast call "$HIVE_AGENT" "isActive(address)(bool)" "$AGENT_ADDR" --rpc-url "$RPC" 2>&1 | awk '{print $1}')
if [ "$IS_ACTIVE" = "true" ]; then
  echo "⚠️  该 Agent 已经注册并激活，无需再次准入。"
  STAKE=$(cast call "$HIVE_AGENT" "getStake(address)(uint256)" "$AGENT_ADDR" --rpc-url "$RPC" 2>&1 | awk '{print $1}')
  echo "  当前质押: $(python3 -c "print(f'{int(\"$STAKE\") / 1e18:.0f}')") AXON"
  exit 0
fi

# 设置声誉
echo "[1] 设置声誉值..."
cast send "$HIVE_AGENT" "setReputation(address,uint256)" "$AGENT_ADDR" "$REP" \
  --private-key "$OPERATOR_PRIVATE_KEY" --rpc-url "$RPC" --gas-limit 100000 2>&1 | head -3

echo ""

# 验证
NEW_REP=$(cast call "$HIVE_AGENT" "getReputation(address)(uint256)" "$AGENT_ADDR" --rpc-url "$RPC" 2>&1 | awk '{print $1}')
echo "[2] 验证: 声誉已设为 $NEW_REP"

# 计算可用等级
if [ "$REP" -ge 100 ]; then
  TIER="Diamond (质押 ≥ 5000 AXON)"
elif [ "$REP" -ge 60 ]; then
  TIER="Gold (质押 ≥ 2000 AXON)"
elif [ "$REP" -ge 30 ]; then
  TIER="Silver (质押 ≥ 500 AXON)"
elif [ "$REP" -ge 10 ]; then
  TIER="Bronze (质押 ≥ 100 AXON)"
else
  TIER="无 (声誉不足)"
fi

echo ""
echo "═══ 准入完成 ═══"
echo "  Agent: $AGENT_ADDR"
echo "  声誉: $NEW_REP"
echo "  可用等级: $TIER"
echo ""
echo "Agent 接下来需要自己执行:"
echo "  1. 持有足够 AXON (至少 100 AXON for Bronze)"
echo "  2. approve AXON 给 HiveAgent 合约:"
echo "     cast send $AXON_TOKEN_ADDRESS 'approve(address,uint256)' $HIVE_AGENT <amount> --private-key <agent_pk> --rpc-url $RPC"
echo "  3. 注册:"
echo "     cast send $HIVE_AGENT 'register(uint256)' <amount> --private-key <agent_pk> --rpc-url $RPC"
echo ""
echo "注册后即可参与预测轮次 (commit / reveal)。"
