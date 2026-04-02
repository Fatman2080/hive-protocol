#!/bin/bash
# ═══════════════════════════════════════════════════
# 蜂巢协议 — Polymarket 实盘交易 + Axon 链上结算
# ═══════════════════════════════════════════════════
#
# 流程：
#   1. 获取 BTC 实时价格
#   2. 发现下一个 Polymarket BTC 15m 市场
#   3. Operator 开轮 (startRound)
#   4. 5 个 Agent 提交/揭示预测 (commit + reveal)
#   5. 根据蜂群共识，Polymarket 实盘下注
#   6. 等待 15 分钟窗口结算
#   7. 获取收盘价，计算真实 P&L
#   8. Operator 链上结算 (settle)
#   9. 验证结果
#
# 用法:
#   bash scripts/run-polymarket-round.sh [BET_AMOUNT_USDC]
#
# 默认下注 $10 USDC。

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../.env"

RPC="https://mainnet-rpc.axonchain.ai/"
HIVE_ROUND="$HIVE_ROUND_ADDRESS"
HIVE_SCORE="$HIVE_SCORE_ADDRESS"
HIVE_AGENT="$HIVE_AGENT_ADDRESS"
OPERATOR_KEY="$OPERATOR_PRIVATE_KEY"

BET_AMOUNT="${1:-10}"  # USDC

NAMES=("Random" "Momentum" "Sentiment" "LLM" "Contrarian")
KEYS=("$AGENT_KEY_RANDOM" "$AGENT_KEY_MOMENTUM" "$AGENT_KEY_SENTIMENT" "$AGENT_KEY_LLM" "$AGENT_KEY_CONTRARIAN")

SALTS=(
  "0x0000000000000000000000000000000000000000000000000000000000000001"
  "0x0000000000000000000000000000000000000000000000000000000000000002"
  "0x0000000000000000000000000000000000000000000000000000000000000003"
  "0x0000000000000000000000000000000000000000000000000000000000000004"
  "0x0000000000000000000000000000000000000000000000000000000000000005"
)

echo ""
echo "╔═══════════════════════════════════════════════════════════════════╗"
echo "║     蜂巢协议 — Polymarket 实盘轮次 (BTC 15m)                     ║"
echo "╚═══════════════════════════════════════════════════════════════════╝"
echo ""
echo "  下注金额: \$$BET_AMOUNT USDC"
echo "  HiveRound: $HIVE_ROUND"
echo "  HiveScore: $HIVE_SCORE"
echo ""

# ═══ Step 1: 获取 BTC 实时价格 ═══
echo "━━━ [1/9] 获取 BTC 实时价格 ━━━"
BTC_JSON=$(curl -s "https://api.binance.com/api/v3/ticker/price?symbol=BTCUSDT")
BTC_PRICE=$(echo "$BTC_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin)['price'])")
BTC_INT=$(python3 -c "print(int(float('$BTC_PRICE') * 1e8))")
echo "  BTC: \$$BTC_PRICE (chain: $BTC_INT)"
echo ""

# ═══ Step 2: 发现 Polymarket BTC 15m 市场 ═══
echo "━━━ [2/9] 发现 Polymarket 市场 ━━━"
MARKET_JSON=$(node "$SCRIPT_DIR/polymarket-trade.mjs" --find-market 2>/dev/null)
MARKET_SLUG=$(echo "$MARKET_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin)['slug'])")
MARKET_Q=$(echo "$MARKET_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin)['question'])")
UP_PRICE=$(echo "$MARKET_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin)['upPrice'])")
DOWN_PRICE=$(echo "$MARKET_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin)['downPrice'])")
echo "  市场: $MARKET_Q"
echo "  UP: $UP_PRICE  |  DOWN: $DOWN_PRICE"

# 查余额
BAL_JSON=$(node "$SCRIPT_DIR/polymarket-trade.mjs" --check-balance 2>/dev/null)
BALANCE=$(echo "$BAL_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin).get('balance_usdc', 0))")
echo "  金库余额: \$$BALANCE USDC"
echo ""

# ═══ Step 3: Operator 开轮 ═══
echo "━━━ [3/9] Operator 开轮 (startRound) ━━━"
cast send "$HIVE_ROUND" "startRound(uint256)" "$BTC_INT" \
  --private-key "$OPERATOR_KEY" --rpc-url "$RPC" --gas-limit 200000 > /dev/null 2>&1
sleep 3

ROUND_ID=$(cast call "$HIVE_ROUND" "currentRoundId()(uint256)" --rpc-url "$RPC" --block latest 2>&1)
echo "  轮次 #$ROUND_ID 已开启"
echo ""

# ═══ Step 4: Agent 预测 ═══
echo "━━━ [4/9] 生成 Agent 预测 ━━━"

# 简单策略: 基于价格动量 + 市场赔率
# Random: 随机   Momentum: 跟价格趋势  Sentiment: 跟市场  LLM: 反市场  Contrarian: 反多数
RAND_PRED=$((RANDOM % 2))
if python3 -c "exit(0 if float('$UP_PRICE') > 0.55 else 1)" 2>/dev/null; then
  MOMENTUM_PRED=0  # UP
else
  MOMENTUM_PRED=1  # DOWN
fi
if python3 -c "exit(0 if float('$UP_PRICE') > float('$DOWN_PRICE') else 1)" 2>/dev/null; then
  SENTIMENT_PRED=0  # 跟市场多数
else
  SENTIMENT_PRED=1
fi
LLM_PRED=$(( 1 - SENTIMENT_PRED ))  # 反市场
CONTRARIAN_PRED=0  # 默认 UP

PREDS=($RAND_PRED $MOMENTUM_PRED $SENTIMENT_PRED $LLM_PRED $CONTRARIAN_PRED)
CONFS=(35 55 40 60 50)

# Commit
echo "━━━ [5/9] Agent 提交 (commit) ━━━"
for i in "${!NAMES[@]}"; do
  KEY="${KEYS[$i]}"
  PRED="${PREDS[$i]}"
  CONF="${CONFS[$i]}"
  SALT="${SALTS[$i]}"

  PRED_HEX=$(printf "%02x" "$PRED")
  CONF_HEX=$(printf "%02x" "$CONF")
  SALT_STRIPPED="${SALT#0x}"
  PACKED="0x${PRED_HEX}${CONF_HEX}${SALT_STRIPPED}"
  COMMIT_HASH=$(cast keccak "$PACKED")
  DIR=$([ "$PRED" -eq 0 ] && echo "UP  " || echo "DOWN")

  echo "  ${NAMES[$i]}: $DIR conf=${CONF}"

  cast send "$HIVE_ROUND" "commit(uint256,bytes32)" "$ROUND_ID" "$COMMIT_HASH" \
    --private-key "$KEY" --rpc-url "$RPC" --gas-limit 300000 > /dev/null 2>&1
  sleep 2
done
echo ""

# Advance to Reveal
cast send "$HIVE_ROUND" "advanceToReveal(uint256)" "$ROUND_ID" \
  --private-key "$OPERATOR_KEY" --rpc-url "$RPC" --gas-limit 100000 > /dev/null 2>&1
sleep 3

# Reveal
echo "━━━ [6/9] Agent 揭示 (reveal) ━━━"
for i in "${!NAMES[@]}"; do
  KEY="${KEYS[$i]}"
  PRED="${PREDS[$i]}"
  CONF="${CONFS[$i]}"
  SALT="${SALTS[$i]}"
  DIR=$([ "$PRED" -eq 0 ] && echo "UP  " || echo "DOWN")

  echo "  ${NAMES[$i]}: $DIR conf=${CONF}"

  cast send "$HIVE_ROUND" "reveal(uint256,uint8,uint8,bytes32)" \
    "$ROUND_ID" "$PRED" "$CONF" "$SALT" \
    --private-key "$KEY" --rpc-url "$RPC" --gas-limit 500000 > /dev/null 2>&1
  sleep 2
done

# 计算蜂群共识方向
UP_VOTES=0; DOWN_VOTES=0; UP_WEIGHT=0; DOWN_WEIGHT=0
for i in "${!NAMES[@]}"; do
  if [ "${PREDS[$i]}" -eq 0 ]; then
    UP_VOTES=$((UP_VOTES + 1))
    UP_WEIGHT=$((UP_WEIGHT + CONFS[$i]))
  else
    DOWN_VOTES=$((DOWN_VOTES + 1))
    DOWN_WEIGHT=$((DOWN_WEIGHT + CONFS[$i]))
  fi
done

if [ "$UP_WEIGHT" -ge "$DOWN_WEIGHT" ]; then
  SWARM_BET="UP"
else
  SWARM_BET="DOWN"
fi

echo ""
echo "  ┌────────────────────────────────────┐"
echo "  │ 蜂群共识: $SWARM_BET (UP:${UP_VOTES}×${UP_WEIGHT} vs DOWN:${DOWN_VOTES}×${DOWN_WEIGHT}) │"
echo "  └────────────────────────────────────┘"
echo ""

# ═══ Step 7: Polymarket 实盘下注 ═══
echo "━━━ [7/9] Polymarket 实盘下注 ━━━"
echo "  方向: $SWARM_BET"
echo "  金额: \$$BET_AMOUNT USDC"

TRADE_JSON=$(node "$SCRIPT_DIR/polymarket-trade.mjs" --direction "$SWARM_BET" --amount "$BET_AMOUNT" 2>"$SCRIPT_DIR/.trade.stderr")
TRADE_SUCCESS=$(echo "$TRADE_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin).get('success', False))")

if [ "$TRADE_SUCCESS" = "True" ]; then
  TRADE_STATUS=$(echo "$TRADE_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin).get('status',''))")
  TRADE_TX=$(echo "$TRADE_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin).get('txHash',''))")
  FILL_PRICE=$(echo "$TRADE_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin).get('fillPrice', 0))")
  SHARES=$(echo "$TRADE_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin).get('shares', 0))")
  echo "  ✅ 下注成功！"
  echo "  Status: $TRADE_STATUS"
  echo "  Fill price: $FILL_PRICE"
  echo "  Shares: $SHARES"
  echo "  Polygon TX: ${TRADE_TX:0:20}..."
else
  TRADE_ERR=$(echo "$TRADE_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin).get('error','unknown'))" 2>/dev/null || echo "unknown")
  echo "  ⚠️  下注失败: $TRADE_ERR"
  echo "  继续用模拟 P&L 结算..."
  FILL_PRICE=0
fi
echo ""

# ═══ Step 8: 等待 15 分钟窗口结算 ═══
echo "━━━ [8/9] 等待市场结算 ━━━"

# 计算当前 slot 剩余时间
NOW=$(date +%s)
SLOT_SIZE=900
CURRENT_SLOT_END=$((($NOW / $SLOT_SIZE + 1) * $SLOT_SIZE))
WAIT_SECS=$(($CURRENT_SLOT_END - $NOW + 30))  # 额外 30 秒等结算

if [ "$WAIT_SECS" -gt 960 ]; then
  WAIT_SECS=960  # 最多等 16 分钟
fi

echo "  等待 ${WAIT_SECS}s 到市场结算..."
for s in $(seq $WAIT_SECS -30 30); do
  echo -n "  ⏳ ${s}s..."
  sleep 30
done
echo " ✅"
echo ""

# 获取收盘价
BTC_CLOSE_JSON=$(curl -s "https://api.binance.com/api/v3/ticker/price?symbol=BTCUSDT")
BTC_CLOSE=$(echo "$BTC_CLOSE_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin)['price'])")
BTC_CLOSE_INT=$(python3 -c "print(int(float('$BTC_CLOSE') * 1e8))")

echo "  开盘: \$$BTC_PRICE → 收盘: \$$BTC_CLOSE"

if [ "$BTC_CLOSE_INT" -gt "$BTC_INT" ]; then
  ACTUAL_DIR="UP"
elif [ "$BTC_CLOSE_INT" -lt "$BTC_INT" ]; then
  ACTUAL_DIR="DOWN"
else
  ACTUAL_DIR="FLAT"
fi
echo "  实际方向: $ACTUAL_DIR"
echo "  蜂群下注: $SWARM_BET"

# 计算 P&L (6 decimals)
if [ "$FILL_PRICE" != "0" ] && [ -n "$FILL_PRICE" ]; then
  # 真实 P&L: 如果正确，每股赚 (1 - fillPrice); 如果错误，每股亏 fillPrice
  if [ "$ACTUAL_DIR" = "$SWARM_BET" ]; then
    PROFIT_LOSS=$(python3 -c "
fp = float('$FILL_PRICE')
shares = int('$SHARES')
pnl = shares * (1.0 - fp) * 1e6
print(int(pnl))
")
    RESULT="✅ 蜂群预测正确！"
  elif [ "$ACTUAL_DIR" = "FLAT" ]; then
    PROFIT_LOSS=0
    RESULT="➖ 价格未变 (退回)"
  else
    PROFIT_LOSS=$(python3 -c "
fp = float('$FILL_PRICE')
shares = int('$SHARES')
pnl = -(shares * fp * 1e6)
print(int(pnl))
")
    RESULT="❌ 蜂群预测错误"
  fi
else
  # 模拟 P&L
  BET_SIZE_MICRO=$((BET_AMOUNT * 1000000))
  if [ "$ACTUAL_DIR" = "$SWARM_BET" ]; then
    PROFIT_LOSS=$((BET_SIZE_MICRO * 95 / 100))
    RESULT="✅ 蜂群预测正确（模拟）"
  elif [ "$ACTUAL_DIR" = "FLAT" ]; then
    PROFIT_LOSS=0
    RESULT="➖ 价格未变（模拟）"
  else
    PROFIT_LOSS=$((-BET_SIZE_MICRO))
    RESULT="❌ 蜂群预测错误（模拟）"
  fi
fi

PNL_USD=$(python3 -c "print(f'{$PROFIT_LOSS / 1e6:.2f}')")
echo ""
echo "  $RESULT"
echo "  P&L: \$$PNL_USD USDC"
echo ""

# ═══ Step 9: Axon 链上结算 ═══
echo "━━━ [9/9] Axon 链上结算 ━━━"
echo "  ⏳ settle(roundId=$ROUND_ID, closePrice=$BTC_CLOSE_INT, pnl=$PROFIT_LOSS)..."

cast send "$HIVE_ROUND" "settle(uint256,uint256,int256)" \
  "$ROUND_ID" "$BTC_CLOSE_INT" "$PROFIT_LOSS" \
  --private-key "$OPERATOR_KEY" --rpc-url "$RPC" --gas-limit 2000000 > /dev/null 2>&1

echo "  ✅ 链上结算完成"
echo ""

sleep 3

# 验证
echo "  ─── Agent HiveScore ───"
for i in "${!NAMES[@]}"; do
  ADDR=$(cast wallet address "${KEYS[$i]}")
  SCORE=$(cast call "$HIVE_SCORE" "getScore(address)(uint256)" "$ADDR" --rpc-url "$RPC" --block latest 2>&1)
  STREAK=$(cast call "$HIVE_SCORE" "getStreak(address)(int256)" "$ADDR" --rpc-url "$RPC" --block latest 2>&1)
  DIR=$([ "${PREDS[$i]}" -eq 0 ] && echo "UP  " || echo "DOWN")
  echo "  ${NAMES[$i]}  $DIR  Score=$SCORE  Streak=$STREAK"
done

# 查最终余额
FINAL_BAL=$(node "$SCRIPT_DIR/polymarket-trade.mjs" --check-balance 2>/dev/null)
FINAL_USD=$(echo "$FINAL_BAL" | python3 -c "import sys,json; print(json.load(sys.stdin).get('balance_usdc', 'N/A'))")

echo ""
echo "╔═══════════════════════════════════════════════════════════════════╗"
echo "║     ✅ Polymarket 实盘轮次完成！                                  ║"
echo "╚═══════════════════════════════════════════════════════════════════╝"
echo ""
echo "  轮次: #$ROUND_ID"
echo "  市场: $MARKET_Q"
echo "  开盘: \$$BTC_PRICE → 收盘: \$$BTC_CLOSE ($ACTUAL_DIR)"
echo "  蜂群共识: $SWARM_BET"
echo "  $RESULT"
echo "  P&L: \$$PNL_USD USDC"
echo "  金库余额: \$$FINAL_USD USDC"
echo ""
