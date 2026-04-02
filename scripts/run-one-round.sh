#!/bin/bash
# ═══════════════════════════════════════════════════
# 蜂巢协议 — 一轮完整测试 (Axon 主网)
# ═══════════════════════════════════════════════════
#
# 流程：
#   1. 获取实时 BTC 价格
#   2. Operator 开轮 (startRound)
#   3. 5 个 Agent 提交预测 (commit)
#   4. Operator 推进到 reveal 阶段
#   5. 5 个 Agent 揭示预测 (reveal)
#   6. 等待 30 秒观察价格变化
#   7. Operator 结算 (settle)
#   8. 验证链上结果 (Score/Round)

set -e

# ─── 环境 ─────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../.env"

RPC="https://mainnet-rpc.axonchain.ai/"
HIVE_ROUND="$HIVE_ROUND_ADDRESS"
HIVE_SCORE="$HIVE_SCORE_ADDRESS"
HIVE_AGENT="$HIVE_AGENT_ADDRESS"
OPERATOR_KEY="$OPERATOR_PRIVATE_KEY"

NAMES=("Random" "Momentum" "Sentiment" "LLM" "Contrarian")
KEYS=("$AGENT_KEY_RANDOM" "$AGENT_KEY_MOMENTUM" "$AGENT_KEY_SENTIMENT" "$AGENT_KEY_LLM" "$AGENT_KEY_CONTRARIAN")

# 每个 Agent 的预测和信心度 (BRONZE 最高 70)
# prediction: 0=UP, 1=DOWN
PREDS=(1 0 1 0 0)        # Random=DOWN, Momentum=UP, Sentiment=DOWN, LLM=UP, Contrarian=UP
CONFS=(40 60 35 55 50)     # 各自的信心度

# 固定 salt（测试用）
SALTS=(
  "0x0000000000000000000000000000000000000000000000000000000000000001"
  "0x0000000000000000000000000000000000000000000000000000000000000002"
  "0x0000000000000000000000000000000000000000000000000000000000000003"
  "0x0000000000000000000000000000000000000000000000000000000000000004"
  "0x0000000000000000000000000000000000000000000000000000000000000005"
)

echo ""
echo "╔═══════════════════════════════════════════════════════╗"
echo "║     蜂巢协议 — 一轮完整测试 (Axon Mainnet)           ║"
echo "╚═══════════════════════════════════════════════════════╝"
echo ""
echo "  HiveRound: $HIVE_ROUND"
echo "  HiveScore: $HIVE_SCORE"
echo "  HiveAgent: $HIVE_AGENT"
echo ""

# ═══ Step 1: 获取 BTC 实时价格 ═══
echo "━━━ [1/8] 获取 BTC 实时价格 ━━━"
BTC_JSON=$(curl -s "https://api.binance.com/api/v3/ticker/price?symbol=BTCUSDT")
BTC_PRICE=$(echo "$BTC_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin)['price'])")
# 价格 × 1e8 转为链上精度
BTC_INT=$(python3 -c "print(int(float('$BTC_PRICE') * 1e8))")
echo "  BTC 价格: \$$BTC_PRICE"
echo "  链上精度: $BTC_INT"
echo ""

# ═══ Step 2: Operator 开轮 ═══
echo "━━━ [2/8] Operator 开轮 (startRound) ━━━"
START_TX=$(cast send "$HIVE_ROUND" "startRound(uint256)" "$BTC_INT" \
  --private-key "$OPERATOR_KEY" --rpc-url "$RPC" --gas-limit 200000 2>&1)
echo "$START_TX" | head -3

sleep 3

ROUND_ID=$(cast call "$HIVE_ROUND" "currentRoundId()(uint256)" --rpc-url "$RPC" --block latest 2>&1)
echo "  轮次 ID: $ROUND_ID"
echo ""

# ═══ Step 3: 5 个 Agent 提交 commit ═══
echo "━━━ [3/8] Agent 提交预测 (commit) ━━━"

for i in "${!NAMES[@]}"; do
  NAME="${NAMES[$i]}"
  KEY="${KEYS[$i]}"
  PRED="${PREDS[$i]}"
  CONF="${CONFS[$i]}"
  SALT="${SALTS[$i]}"

  # 构造 abi.encodePacked(uint8 prediction, uint8 confidence, bytes32 salt)
  PRED_HEX=$(printf "%02x" "$PRED")
  CONF_HEX=$(printf "%02x" "$CONF")
  SALT_STRIPPED="${SALT#0x}"
  PACKED="0x${PRED_HEX}${CONF_HEX}${SALT_STRIPPED}"

  # keccak256
  COMMIT_HASH=$(cast keccak "$PACKED")
  DIR=$([ "$PRED" -eq 0 ] && echo "UP" || echo "DOWN")

  echo "  $NAME: $DIR conf=$CONF → hash=${COMMIT_HASH:0:18}..."

  cast send "$HIVE_ROUND" "commit(uint256,bytes32)" "$ROUND_ID" "$COMMIT_HASH" \
    --private-key "$KEY" --rpc-url "$RPC" --gas-limit 300000 > /dev/null 2>&1

  sleep 2
done
echo ""

# ═══ Step 4: Operator 推进到 reveal ═══
echo "━━━ [4/8] 推进到 REVEAL 阶段 ━━━"
cast send "$HIVE_ROUND" "advanceToReveal(uint256)" "$ROUND_ID" \
  --private-key "$OPERATOR_KEY" --rpc-url "$RPC" --gas-limit 100000 > /dev/null 2>&1
echo "  ✅ 已推进到 REVEAL"
sleep 3
echo ""

# ═══ Step 5: 5 个 Agent 揭示 reveal ═══
echo "━━━ [5/8] Agent 揭示预测 (reveal) ━━━"

for i in "${!NAMES[@]}"; do
  NAME="${NAMES[$i]}"
  KEY="${KEYS[$i]}"
  PRED="${PREDS[$i]}"
  CONF="${CONFS[$i]}"
  SALT="${SALTS[$i]}"
  DIR=$([ "$PRED" -eq 0 ] && echo "UP" || echo "DOWN")

  echo "  $NAME: 揭示 $DIR conf=$CONF"

  cast send "$HIVE_ROUND" "reveal(uint256,uint8,uint8,bytes32)" \
    "$ROUND_ID" "$PRED" "$CONF" "$SALT" \
    --private-key "$KEY" --rpc-url "$RPC" --gas-limit 500000 > /dev/null 2>&1

  sleep 2
done

# 读取链上权重
UP_W=$(cast call "$HIVE_ROUND" "getRound(uint256)((uint8,uint256,uint256,uint256,uint256,uint256,uint256,int256,uint256))" "$ROUND_ID" --rpc-url "$RPC" --block latest 2>&1)
echo ""
echo "  链上权重数据:"
echo "  $UP_W"
echo ""

# ═══ Step 6: 等待价格变化 ═══
echo "━━━ [6/8] 等待 30 秒观察价格变化 ━━━"
for s in $(seq 30 -5 5); do
  echo -n "  ⏳ ${s}s..."
  sleep 5
done
echo " 完成!"
echo ""

# ═══ Step 7: 获取收盘价 + 结算 ═══
echo "━━━ [7/8] 获取收盘价 + 结算 (settle) ━━━"
BTC_CLOSE_JSON=$(curl -s "https://api.binance.com/api/v3/ticker/price?symbol=BTCUSDT")
BTC_CLOSE=$(echo "$BTC_CLOSE_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin)['price'])")
BTC_CLOSE_INT=$(python3 -c "print(int(float('$BTC_CLOSE') * 1e8))")

echo "  开盘: \$$BTC_PRICE ($BTC_INT)"
echo "  收盘: \$$BTC_CLOSE ($BTC_CLOSE_INT)"

# 判断方向
if [ "$BTC_CLOSE_INT" -gt "$BTC_INT" ]; then
  DIRECTION="UP"
elif [ "$BTC_CLOSE_INT" -lt "$BTC_INT" ]; then
  DIRECTION="DOWN"
else
  DIRECTION="FLAT"
fi
echo "  方向: $DIRECTION"

# 群体决策是 UP (Momentum+LLM+Contrarian 权重占 68.75%)
GROUP_BET="UP"
echo "  群体决策: $GROUP_BET"

# 计算模拟 P&L
# 金库 10,000 USDT × 2% = 200 USDT 下注额
BET_SIZE=200000000  # 200 USDT (6 decimals)

if [ "$DIRECTION" = "$GROUP_BET" ]; then
  # 正确 → 盈利 (模拟 95% 赔率)
  PROFIT_LOSS=190000000   # +190 USDT
  RESULT="✅ 蜂群预测正确！"
elif [ "$DIRECTION" = "FLAT" ]; then
  PROFIT_LOSS=0
  RESULT="➖ 价格未变"
else
  # 错误 → 亏损
  PROFIT_LOSS=-200000000  # -200 USDT
  RESULT="❌ 蜂群预测错误"
fi

echo "  $RESULT"
echo "  P&L: $PROFIT_LOSS ($(python3 -c "print(f'{$PROFIT_LOSS / 1e6:.2f}')") USDT)"
echo ""

# 结算
echo "  ⏳ 链上结算..."
cast send "$HIVE_ROUND" "settle(uint256,uint256,int256)" \
  "$ROUND_ID" "$BTC_CLOSE_INT" "$PROFIT_LOSS" \
  --private-key "$OPERATOR_KEY" --rpc-url "$RPC" --gas-limit 2000000 > /dev/null 2>&1
echo "  ✅ 结算完成"
echo ""

# ═══ Step 8: 验证链上结果 ═══
echo "━━━ [8/8] 验证链上结果 ━━━"
sleep 3

echo ""
echo "  ─── 轮次数据 ───"
ROUND_DATA=$(cast call "$HIVE_ROUND" "getRound(uint256)((uint8,uint256,uint256,uint256,uint256,uint256,uint256,int256,uint256))" "$ROUND_ID" --rpc-url "$RPC" --block latest 2>&1)
echo "  $ROUND_DATA"

echo ""
echo "  ─── Agent HiveScore ───"
for i in "${!NAMES[@]}"; do
  ADDR=$(cast wallet address "${KEYS[$i]}")
  SCORE=$(cast call "$HIVE_SCORE" "getScore(address)(uint256)" "$ADDR" --rpc-url "$RPC" --block latest 2>&1)
  STREAK=$(cast call "$HIVE_SCORE" "getStreak(address)(int256)" "$ADDR" --rpc-url "$RPC" --block latest 2>&1)
  STAKE=$(cast call "$HIVE_AGENT" "getStake(address)(uint256)" "$ADDR" --rpc-url "$RPC" --block latest 2>&1)

  DIR=$([ "${PREDS[$i]}" -eq 0 ] && echo "UP  " || echo "DOWN")
  echo "  ${NAMES[$i]:0:11}  $DIR  Score=$SCORE  Streak=$STREAK  Stake=$STAKE"
done

echo ""
echo "╔═══════════════════════════════════════════════════════╗"
echo "║     ✅ 一轮测试完成！                                 ║"
echo "╚═══════════════════════════════════════════════════════╝"
echo ""
echo "  轮次: #$ROUND_ID"
echo "  开盘: \$$BTC_PRICE → 收盘: \$$BTC_CLOSE ($DIRECTION)"
echo "  群体决策: $GROUP_BET"
echo "  结果: $RESULT"
echo "  P&L: $(python3 -c "print(f'{$PROFIT_LOSS / 1e6:.2f}')") USDT"
echo ""
