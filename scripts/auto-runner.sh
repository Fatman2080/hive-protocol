#!/bin/bash
# ═══════════════════════════════════════════════════════════════
# 蜂巢协议 — 自动运行守护进程 v2
# ═══════════════════════════════════════════════════════════════
#
# 每 15 分钟自动执行一轮完整流程：
#   市场发现 → Agent 预测 → Polymarket 下注 → 等待结算 →
#   条件代币赎回 → 链上结算 → 利润分发 → 下一轮
#
# 用法:
#   bash scripts/auto-runner.sh                           # 前台运行
#   nohup bash scripts/auto-runner.sh &                   # 后台运行
#   bash scripts/auto-runner.sh --bet 20 --max-price 0.60 # 自定义参数
#   bash scripts/auto-runner.sh --max-rounds 10
#
# 停止: kill $(cat /tmp/hive-runner.pid)
# 日志: tail -f logs/hive-auto.log
# ═══════════════════════════════════════════════════════════════

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
LOG_DIR="$PROJECT_DIR/logs"
PID_FILE="/tmp/hive-runner.pid"

source "$PROJECT_DIR/.env"

# ─── 参数 ─────────────────────────────────────────────
BET_PCT=2                 # 金库余额的百分比（白皮书: 2%）
BET_MIN=5                 # 最低下注额 $5（余额太小时兜底）
BET_MAX=500               # 单轮下注上限
MAX_PRICE=0.65            # 拒绝高于此价格的下注
MAX_ROUNDS=0              # 0 = 无限
COOLDOWN_ON_ERROR=60
MAX_CONSECUTIVE_ERRORS=5
POLYGON_RPC="https://polygon-bor-rpc.publicnode.com"

while [[ $# -gt 0 ]]; do
  case $1 in
    --bet-pct)    BET_PCT="$2"; shift 2 ;;
    --bet-min)    BET_MIN="$2"; shift 2 ;;
    --bet-max)    BET_MAX="$2"; shift 2 ;;
    --max-price)  MAX_PRICE="$2"; shift 2 ;;
    --max-rounds) MAX_ROUNDS="$2"; shift 2 ;;
    *)            shift ;;
  esac
done

# ─── 初始化 ───────────────────────────────────────────
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/hive-auto.log"
echo $$ > "$PID_FILE"

RPC="https://mainnet-rpc.axonchain.ai/"
HIVE_ROUND="$HIVE_ROUND_ADDRESS"
HIVE_SCORE="$HIVE_SCORE_ADDRESS"
HIVE_AGENT="$HIVE_AGENT_ADDRESS"
OPERATOR_KEY="$OPERATOR_PRIVATE_KEY"
USDC_E="0x2791Bca1f2de4661ED88A30C99A7a9449Aa84174"

NAMES=("Random" "Momentum" "Sentiment" "LLM" "Contrarian")
KEYS=("$AGENT_KEY_RANDOM" "$AGENT_KEY_MOMENTUM" "$AGENT_KEY_SENTIMENT" "$AGENT_KEY_LLM" "$AGENT_KEY_CONTRARIAN")

ROUND_COUNT=0
ERROR_COUNT=0
TOTAL_PNL=0

# ─── 工具函数 ─────────────────────────────────────────
log() {
  local ts=$(date '+%Y-%m-%d %H:%M:%S')
  echo "[$ts] $*" | tee -a "$LOG_FILE"
}

log_section() {
  log "━━━ $* ━━━"
}

# cast call 输出 "123 [1.23e2]"，只取第一个数字
cast_num() {
  echo "$1" | awk '{print $1}'
}

# 读取 Proxy Wallet USDC.e 余额 (微元)
get_proxy_balance() {
  local raw=$(cast call "$USDC_E" "balanceOf(address)(uint256)" "$POLYMARKET_FUNDER" \
    --rpc-url "$POLYGON_RPC" 2>/dev/null || echo "0")
  cast_num "$raw"
}

# ─── 等待到下一个 15 分钟窗口的合适时机 ──────────────
wait_for_next_slot() {
  local now=$(date +%s)
  local slot_size=900
  local current_slot_start=$(( (now / slot_size) * slot_size ))
  local next_slot_start=$(( current_slot_start + slot_size ))

  local target_time=$(( next_slot_start + 60 ))
  local wait_secs=$(( target_time - now ))

  if [ "$wait_secs" -le 0 ]; then
    target_time=$(( next_slot_start + slot_size + 60 ))
    wait_secs=$(( target_time - now ))
  fi

  local target_str=$(date -r "$target_time" '+%H:%M:%S' 2>/dev/null || date -d "@$target_time" '+%H:%M:%S' 2>/dev/null || echo "?")
  log "等待下一个 15 分钟窗口... ${wait_secs}s 后 ($target_str) 开始"

  sleep "$wait_secs"
}

# ─── 单轮完整流程 ─────────────────────────────────────
run_one_round() {
  local round_start=$(date +%s)

  # [1] BTC 价格
  log_section "获取 BTC 价格"
  local btc_json=$(curl -s "https://api.binance.com/api/v3/ticker/price?symbol=BTCUSDT")
  local btc_price=$(echo "$btc_json" | python3 -c "import sys,json; print(json.load(sys.stdin)['price'])")
  local btc_int=$(python3 -c "print(int(float('$btc_price') * 1e8))")
  log "BTC: \$$btc_price"

  # [2] 发现市场
  log_section "发现 Polymarket 市场"
  local market_json=$(node "$SCRIPT_DIR/polymarket-trade.mjs" --find-market 2>/dev/null)
  if [ -z "$market_json" ] || echo "$market_json" | python3 -c "import sys,json; d=json.load(sys.stdin); exit(0 if 'error' in d else 1)" 2>/dev/null; then
    log "未找到活跃市场，跳过本轮"
    return 1
  fi

  local market_q=$(echo "$market_json" | python3 -c "import sys,json; print(json.load(sys.stdin)['question'])")
  local up_price=$(echo "$market_json" | python3 -c "import sys,json; print(json.load(sys.stdin)['upPrice'])")
  local down_price=$(echo "$market_json" | python3 -c "import sys,json; print(json.load(sys.stdin)['downPrice'])")
  local condition_id=$(echo "$market_json" | python3 -c "import sys,json; print(json.load(sys.stdin).get('conditionId', ''))" 2>/dev/null || echo "")
  log "市场: $market_q  UP:$up_price  DOWN:$down_price"

  # [3] 开轮
  log_section "Operator 开轮"
  cast send "$HIVE_ROUND" "startRound(uint256)" "$btc_int" \
    --private-key "$OPERATOR_KEY" --rpc-url "$RPC" --gas-limit 200000 > /dev/null 2>&1
  sleep 3

  local round_id_raw=$(cast call "$HIVE_ROUND" "currentRoundId()(uint256)" --rpc-url "$RPC" --block latest 2>&1)
  local round_id=$(cast_num "$round_id_raw")
  log "轮次 #$round_id 已开启"

  # [4] Agent 预测生成
  log_section "Agent 预测"
  local rand_pred=$((RANDOM % 2))
  local momentum_pred=0
  if python3 -c "exit(0 if float('$up_price') <= 0.55 else 1)" 2>/dev/null; then
    momentum_pred=1
  fi
  local sentiment_pred=0
  if python3 -c "exit(0 if float('$up_price') <= float('$down_price') else 1)" 2>/dev/null; then
    sentiment_pred=1
  fi
  local llm_pred=$(( 1 - sentiment_pred ))
  local contrarian_pred=0

  local preds=($rand_pred $momentum_pred $sentiment_pred $llm_pred $contrarian_pred)
  local confs=(35 55 40 60 50)
  local salts=(
    "0x$(openssl rand -hex 32)"
    "0x$(openssl rand -hex 32)"
    "0x$(openssl rand -hex 32)"
    "0x$(openssl rand -hex 32)"
    "0x$(openssl rand -hex 32)"
  )

  # [5] Commit
  log_section "Agent Commit"
  for i in "${!NAMES[@]}"; do
    local key="${KEYS[$i]}"
    local pred="${preds[$i]}"
    local conf="${confs[$i]}"
    local salt="${salts[$i]}"

    local pred_hex=$(printf "%02x" "$pred")
    local conf_hex=$(printf "%02x" "$conf")
    local salt_stripped="${salt#0x}"
    local packed="0x${pred_hex}${conf_hex}${salt_stripped}"
    local commit_hash=$(cast keccak "$packed")
    local dir=$([ "$pred" -eq 0 ] && echo "UP" || echo "DN")

    log "  ${NAMES[$i]}: $dir conf=$conf"

    cast send "$HIVE_ROUND" "commit(uint256,bytes32)" "$round_id" "$commit_hash" \
      --private-key "$key" --rpc-url "$RPC" --gas-limit 300000 > /dev/null 2>&1
    sleep 2
  done

  cast send "$HIVE_ROUND" "advanceToReveal(uint256)" "$round_id" \
    --private-key "$OPERATOR_KEY" --rpc-url "$RPC" --gas-limit 100000 > /dev/null 2>&1
  sleep 3

  # [6] Reveal
  log_section "Agent Reveal"
  for i in "${!NAMES[@]}"; do
    local key="${KEYS[$i]}"
    local pred="${preds[$i]}"
    local conf="${confs[$i]}"
    local salt="${salts[$i]}"

    cast send "$HIVE_ROUND" "reveal(uint256,uint8,uint8,bytes32)" \
      "$round_id" "$pred" "$conf" "$salt" \
      --private-key "$key" --rpc-url "$RPC" --gas-limit 500000 > /dev/null 2>&1
    sleep 2
  done

  # 计算蜂群共识
  local up_weight=0 down_weight=0
  for i in "${!NAMES[@]}"; do
    if [ "${preds[$i]}" -eq 0 ]; then
      up_weight=$((up_weight + confs[$i]))
    else
      down_weight=$((down_weight + confs[$i]))
    fi
  done

  local swarm_bet="UP"
  [ "$down_weight" -gt "$up_weight" ] && swarm_bet="DOWN"
  log "蜂群共识: $swarm_bet (UP=$up_weight vs DOWN=$down_weight)"

  # [7] 记录下注前余额 & 按比例计算下注额
  local bal_before=$(get_proxy_balance)
  local bal_usd=$(python3 -c "print(f'{int(\"$bal_before\") / 1e6:.2f}')")
  local BET_AMOUNT=$(python3 -c "
b = int('$bal_before') / 1e6
amt = b * $BET_PCT / 100
amt = max(amt, $BET_MIN)
amt = min(amt, $BET_MAX)
print(f'{amt:.2f}')
")
  log "Proxy 余额 (下注前): \$$bal_usd → 本轮下注: \$$BET_AMOUNT (${BET_PCT}%)"

  # [8] Polymarket 下注（带最大价格限制）
  log_section "Polymarket 下注 $swarm_bet \$$BET_AMOUNT (max_price=$MAX_PRICE)"
  local trade_json=$(node "$SCRIPT_DIR/polymarket-trade.mjs" \
    --direction "$swarm_bet" --amount "$BET_AMOUNT" --max-price "$MAX_PRICE" 2>>"$LOG_FILE")
  local trade_success=$(echo "$trade_json" | python3 -c "import sys,json; print(json.load(sys.stdin).get('success', False))" 2>/dev/null || echo "False")
  local trade_error=$(echo "$trade_json" | python3 -c "import sys,json; print(json.load(sys.stdin).get('error', ''))" 2>/dev/null || echo "")

  local fill_price=0 shares=0 bet_placed=false
  if [ "$trade_success" = "True" ]; then
    fill_price=$(echo "$trade_json" | python3 -c "import sys,json; print(json.load(sys.stdin).get('fillPrice', 0))")
    shares=$(echo "$trade_json" | python3 -c "import sys,json; print(json.load(sys.stdin).get('shares', 0))")
    log "下注成功 fillPrice=$fill_price shares=$shares"
    bet_placed=true
  elif [ "$trade_error" = "price_too_high" ]; then
    local rejected_price=$(echo "$trade_json" | python3 -c "import sys,json; print(json.load(sys.stdin).get('fillPrice', '?'))" 2>/dev/null || echo "?")
    log "赔率不利 (price=$rejected_price > max=$MAX_PRICE)，跳过本轮下注"
  else
    log "下注失败: $trade_error"
  fi

  # [9] 等待市场结算
  log_section "等待市场结算"
  local now=$(date +%s)
  local slot_size=900
  local current_slot_end=$((( now / slot_size + 1) * slot_size ))
  local wait_secs=$(( current_slot_end - now + 30 ))
  [ "$wait_secs" -gt 960 ] && wait_secs=960

  log "等待 ${wait_secs}s..."
  sleep "$wait_secs"

  # [10] 赎回条件代币
  if [ "$bet_placed" = true ]; then
    log_section "赎回条件代币"
    sleep 30
    node "$SCRIPT_DIR/redeem-wins.mjs" --hours 1 2>>"$LOG_FILE" | tee -a "$LOG_FILE"
    log "赎回完成"
  fi

  # [11] 计算实际 P&L（基于余额变化）
  local bal_after=$(get_proxy_balance)
  log "Proxy 余额 (赎回后): \$$(python3 -c "print(f'{int(\"$bal_after\") / 1e6:.2f}')")"

  local profit_loss=$(python3 -c "print(int('$bal_after') - int('$bal_before'))")
  local pnl_usd=$(python3 -c "print(f'{$profit_loss / 1e6:.2f}')")

  # 收盘价（用于链上结算记录）
  local btc_close_json=$(curl -s "https://api.binance.com/api/v3/ticker/price?symbol=BTCUSDT")
  local btc_close=$(echo "$btc_close_json" | python3 -c "import sys,json; print(json.load(sys.stdin)['price'])")
  local btc_close_int=$(python3 -c "print(int(float('$btc_close') * 1e8))")

  local actual_dir="FLAT"
  [ "$btc_close_int" -gt "$btc_int" ] && actual_dir="UP"
  [ "$btc_close_int" -lt "$btc_int" ] && actual_dir="DOWN"

  local result_text="平局"
  if [ "$bet_placed" = true ]; then
    [ "$profit_loss" -gt 0 ] && result_text="盈利"
    [ "$profit_loss" -lt 0 ] && result_text="亏损"
  else
    result_text="未下注"
  fi

  log "开盘: \$$btc_price → 收盘: \$$btc_close ($actual_dir)"
  log "结果: $result_text | P&L: \$$pnl_usd"

  # [12] 链上结算
  log_section "Axon 链上结算"
  cast send "$HIVE_ROUND" "settle(uint256,uint256,int256)" \
    "$round_id" "$btc_close_int" "$profit_loss" \
    --private-key "$OPERATOR_KEY" --rpc-url "$RPC" --gas-limit 2000000 > /dev/null 2>&1
  log "链上结算完成"

  sleep 3

  # [13] HiveScore 更新验证
  for i in "${!NAMES[@]}"; do
    local addr=$(cast wallet address "${KEYS[$i]}")
    local score_raw=$(cast call "$HIVE_SCORE" "getScore(address)(uint256)" "$addr" --rpc-url "$RPC" --block latest 2>&1)
    local streak_raw=$(cast call "$HIVE_SCORE" "getStreak(address)(int256)" "$addr" --rpc-url "$RPC" --block latest 2>&1)
    log "  ${NAMES[$i]} Score=$(cast_num "$score_raw") Streak=$(cast_num "$streak_raw")"
  done

  # [14] 利润分发（仅盈利时）
  if [ "$profit_loss" -gt 0 ]; then
    log_section "利润分发"
    node "$SCRIPT_DIR/distribute-bsc.mjs" \
      --round-id "$round_id" \
      --total-profit "$pnl_usd" 2>>"$LOG_FILE" | tee -a "$LOG_FILE"
  else
    log "本轮 P&L ≤ 0，跳过利润分发"
  fi

  # 更新统计
  TOTAL_PNL=$(python3 -c "print(f'{$TOTAL_PNL + $profit_loss / 1e6:.2f}')")
  ROUND_COUNT=$((ROUND_COUNT + 1))

  local elapsed=$(( $(date +%s) - round_start ))
  log "═══ 轮次 #$round_id 完成 | P&L: \$$pnl_usd | 累计: \$$TOTAL_PNL | 耗时: ${elapsed}s ═══"
  echo "" >> "$LOG_FILE"

  return 0
}

# ─── 主循环 ───────────────────────────────────────────
log ""
log "╔═══════════════════════════════════════════════════════════╗"
log "║    蜂巢协议 — 自动运行守护进程 v2                        ║"
log "╚═══════════════════════════════════════════════════════════╝"
log "  PID: $$"
log "  每轮下注: 金库 × ${BET_PCT}% (最低 \$${BET_MIN}, 上限 \$${BET_MAX})"
log "  最大可接受价格: $MAX_PRICE"
log "  最大轮数: $([ $MAX_ROUNDS -eq 0 ] && echo '无限' || echo $MAX_ROUNDS)"
log "  日志文件: $LOG_FILE"
log "  停止方式: kill \$(cat $PID_FILE)"
log ""

trap 'log "收到终止信号，安全退出..."; rm -f "$PID_FILE"; exit 0' SIGINT SIGTERM

while true; do
  if [ "${MAX_ROUNDS:-0}" -gt 0 ] && [ "$ROUND_COUNT" -ge "${MAX_ROUNDS:-0}" ]; then
    log "已达最大轮数 ${MAX_ROUNDS}，退出"
    break
  fi

  if [ "$ERROR_COUNT" -ge "$MAX_CONSECUTIVE_ERRORS" ]; then
    log "连续 $ERROR_COUNT 次错误，暂停 5 分钟..."
    sleep 300
    ERROR_COUNT=0
  fi

  wait_for_next_slot

  if run_one_round; then
    ERROR_COUNT=0
  else
    ERROR_COUNT=$((ERROR_COUNT + 1))
    log "本轮执行失败 (连续错误: $ERROR_COUNT/$MAX_CONSECUTIVE_ERRORS)"
    sleep "$COOLDOWN_ON_ERROR"
  fi
done

log "═══ 自动运行结束 | 总轮数: $ROUND_COUNT | 总 P&L: \$$TOTAL_PNL ═══"
rm -f "$PID_FILE"
