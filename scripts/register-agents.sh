#!/bin/bash
# 蜂巢协议 — Axon 主网 Agent 注册
# 用 Foundry cast 直接发交易，避免 viem BigInt 兼容问题

set -e

RPC="https://mainnet-rpc.axonchain.ai/"
AXON_TOKEN="0x1D0954d3A1f6C478802F6A85F1DA69ee9eb4916e"
HIVE_AGENT="0x4222fE51db0b8e2c79460fF963Fe2B56B54Cbc45"
STAKE="200000000000000000000"  # 200 * 1e18

# Agent 私钥和地址 (从 .env 读取)
source "$(dirname "$0")/../.env"

NAMES=("Random" "Momentum" "Sentiment" "LLM" "Contrarian")
KEYS=("$AGENT_KEY_RANDOM" "$AGENT_KEY_MOMENTUM" "$AGENT_KEY_SENTIMENT" "$AGENT_KEY_LLM" "$AGENT_KEY_CONTRARIAN")

echo "═══════════════════════════════════════════════════"
echo "  蜂巢协议 — Axon 主网 Agent 注册 (cast)"
echo "═══════════════════════════════════════════════════"
echo "  AXON Token: $AXON_TOKEN"
echo "  HiveAgent:  $HIVE_AGENT"
echo "  质押量:     200 AXON / Agent"
echo ""

for i in "${!NAMES[@]}"; do
  NAME="${NAMES[$i]}"
  KEY="${KEYS[$i]}"
  ADDR=$(cast wallet address "$KEY")

  echo "─── $NAME ($ADDR) ───"

  # 检查是否已注册
  ACTIVE=$(cast call "$HIVE_AGENT" "isActive(address)(bool)" "$ADDR" --rpc-url "$RPC" --block latest 2>&1)
  if [[ "$ACTIVE" == "true" ]]; then
    STAKE_AMT=$(cast call "$HIVE_AGENT" "getStake(address)(uint256)" "$ADDR" --rpc-url "$RPC" --block latest 2>&1)
    echo "  ✅ 已注册, stake=$STAKE_AMT"
    continue
  fi

  # 检查 AXON 余额
  BAL=$(cast call "$AXON_TOKEN" "balanceOf(address)(uint256)" "$ADDR" --rpc-url "$RPC" --block latest 2>&1)
  echo "  AXON 余额: $BAL"

  # Step 1: approve
  echo "  ⏳ approve..."
  APPROVE_TX=$(cast send "$AXON_TOKEN" "approve(address,uint256)" "$HIVE_AGENT" "$STAKE" \
    --private-key "$KEY" --rpc-url "$RPC" --gas-limit 100000 2>&1)
  echo "  $APPROVE_TX" | head -1

  sleep 2

  # Step 2: register(uint256, address) — 传自身地址作为 bscAddr
  echo "  ⏳ register..."
  REG_TX=$(cast send "$HIVE_AGENT" "register(uint256,address)" "$STAKE" "$ADDR" \
    --private-key "$KEY" --rpc-url "$RPC" --gas-limit 500000 2>&1)
  echo "  $REG_TX" | head -1

  sleep 2

  # 验证
  ACTIVE2=$(cast call "$HIVE_AGENT" "isActive(address)(bool)" "$ADDR" --rpc-url "$RPC" --block latest 2>&1)
  TIER=$(cast call "$HIVE_AGENT" "getTier(address)(uint8)" "$ADDR" --rpc-url "$RPC" --block latest 2>&1)
  echo "  结果: active=$ACTIVE2, tier=$TIER"
  echo ""
done

echo "═══════════════════════════════════════════════════"
echo "  注册完成！"
echo "═══════════════════════════════════════════════════"
