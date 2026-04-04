#!/bin/bash
# ═══════════════════════════════════════════════════════════════
# 蜂巢协议 — 自动运行守护进程 v3 (纯 Operator 模式)
# ═══════════════════════════════════════════════════════════════
#
# 纯 Operator：不提交任何预测，仅管理轮次和下注
#   市场发现 → 开轮 → 等待外部 Agent 预测 → HiveScore 加权共识 →
#   Polymarket 下注 → 等待结算 → 等待 Oracle resolve → 赎回 →
#   链上结算 → 利润分发 → 下一轮
#
# 用法:
#   bash scripts/auto-runner.sh                           # 前台运行
#   bash scripts/auto-runner.sh --bet 20 --max-price 0.60
#
# 停止: kill $(cat /tmp/hive-runner.pid)
# 日志: tail -f logs/hive-auto.log
# ═══════════════════════════════════════════════════════════════

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
LOG_DIR="$PROJECT_DIR/logs"
PID_FILE="/tmp/hive-runner.pid"

# PID 锁防止双实例
if [ -f "$PID_FILE" ]; then
  OLD_PID=$(cat "$PID_FILE" 2>/dev/null)
  if [ -n "$OLD_PID" ] && kill -0 "$OLD_PID" 2>/dev/null; then
    echo "另一个 auto-runner 实例正在运行 (PID $OLD_PID)，退出"
    exit 1
  fi
  rm -f "$PID_FILE"
fi

# 立即写 PID 文件（在 source .env 之前）
echo $$ > "$PID_FILE"

set +u
source "$PROJECT_DIR/.env"
set -u

# ─── 参数 ─────────────────────────────────────────────
BET_PCT=2
BET_MIN=5
BET_MAX=500
MAX_PRICE=0.65
MAX_ROUNDS=0
COMMIT_WAIT=180           # 等待 Agent commit 的秒数 (3分钟)
REVEAL_WAIT=180           # 等待 Agent reveal 的秒数 (3分钟)
REDEEM_MAX_WAIT=300       # 等待 Oracle resolve 的最大秒数 (5分钟)
COOLDOWN_ON_ERROR=60
MAX_CONSECUTIVE_ERRORS=5
POLYGON_RPC="https://polygon-bor-rpc.publicnode.com"

while [[ $# -gt 0 ]]; do
  case $1 in
    --bet-pct)      BET_PCT="$2"; shift 2 ;;
    --bet-min)      BET_MIN="$2"; shift 2 ;;
    --bet-max)      BET_MAX="$2"; shift 2 ;;
    --max-price)    MAX_PRICE="$2"; shift 2 ;;
    --max-rounds)   MAX_ROUNDS="$2"; shift 2 ;;
    --commit-wait)  COMMIT_WAIT="$2"; shift 2 ;;
    --reveal-wait)  REVEAL_WAIT="$2"; shift 2 ;;
    *)              shift ;;
  esac
done

# ─── 初始化 ───────────────────────────────────────────
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/hive-auto.log"

RPC="https://mainnet-rpc.axonchain.ai/"
HIVE_ROUND="$HIVE_ROUND_ADDRESS"
HIVE_SCORE="$HIVE_SCORE_ADDRESS"
HIVE_AGENT="$HIVE_AGENT_ADDRESS"
OPERATOR_KEY="$OPERATOR_PRIVATE_KEY"
USDC_E="0x2791Bca1f2de4661ED88A30C99A7a9449Aa84174"

ROUND_COUNT=0
ERROR_COUNT=0
TOTAL_PNL=0
LAST_AGENT_COUNT=0

# ─── 工具函数 ─────────────────────────────────────────
log() {
  local ts=$(date '+%Y-%m-%d %H:%M:%S')
  echo "[$ts] $*" | tee -a "$LOG_FILE"
}

log_section() {
  log "━━━ $* ━━━"
}

tg() {
  bash "$SCRIPT_DIR/tg-notify.sh" "$1" &
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

# HiveRound: 上一轮若停在 COMMIT/REVEAL 未 settle，下一轮 startRound 会永久 revert。
# 用当前 BTC 价作 closePrice、profitLoss=0 强制收尾（与合约「信号不足则跳过」语义一致）。
finalize_stuck_round_on_axon() {
  local close_price_int="$1"
  local rid_raw
  rid_raw=$(cast call "$HIVE_ROUND" "currentRoundId()(uint256)" --rpc-url "$RPC" --block latest 2>&1)
  local rid
  rid=$(cast_num "$rid_raw")
  if [ "${rid:-0}" -eq 0 ]; then
    return 0
  fi

  local rd
  rd=$(cast call "$HIVE_ROUND" \
    "getRound(uint256)((uint8,uint256,uint256,uint256,uint256,uint256,uint256,int256,uint256))" \
    "$rid" --rpc-url "$RPC" --block latest 2>&1)
  local phase
  phase=$(echo "$rd" | python3 -c "
import sys
s = sys.stdin.read().strip()
if not s or 'Error' in s:
    print(99); sys.exit(0)
s = s.strip().strip('()')
first = s.split(',')[0].strip()
print(int(first.split()[0]))
" 2>/dev/null || echo "99")

  # SETTLED=3；99=解析失败则勿动
  if [ "$phase" -eq 3 ] || [ "$phase" -eq 99 ]; then
    return 0
  fi

  log_section "链上恢复: Round #$rid 停在 phase=$phase，advance+settle 解除阻塞"
  if [ "$phase" -eq 1 ]; then
    cast send "$HIVE_ROUND" "advanceToReveal(uint256)" "$rid" \
      --private-key "$OPERATOR_KEY" --rpc-url "$RPC" --gas-limit 500000 --legacy --gas-price 8000000000 >/dev/null 2>&1 \
      || log "advanceToReveal 可能已失败（继续尝试 settle）"
    sleep 2
  fi

  local settle_out
  settle_out=$(cast send "$HIVE_ROUND" "settle(uint256,uint256,int256)" \
    "$rid" "$close_price_int" "0" \
    --private-key "$OPERATOR_KEY" --rpc-url "$RPC" --gas-limit 8000000 --legacy --gas-price 8000000000 2>&1)
  local st
  st=$(echo "$settle_out" | grep "^status" | awk '{print $2}')
  if [ "$st" = "0" ]; then
    log "⚠️ 恢复 settle 失败: $(echo "$settle_out" | tail -3 | tr '\n' ' ')"
  else
    log "✓ Round #$rid 已链上结算（恢复）"
  fi
  sleep 2
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

  # [0] 检测新 Agent 注册
  local cur_agent_count_raw=$(cast call "$HIVE_AGENT" "activeAgentCount()(uint256)" --rpc-url "$RPC" --block latest 2>&1)
  local cur_agent_count=$(cast_num "$cur_agent_count_raw")
  if [ "$LAST_AGENT_COUNT" -gt 0 ] && [ "$cur_agent_count" -gt "$LAST_AGENT_COUNT" ]; then
    local new_count=$(( cur_agent_count - LAST_AGENT_COUNT ))
    log "检测到 ${new_count} 个新 Agent 注册 (总活跃: $cur_agent_count)"
    tg "🎉 *新 Agent 注册!*
新增: *${new_count}* 个 Agent
总活跃 Agent: *${cur_agent_count}*"
  fi
  LAST_AGENT_COUNT=$cur_agent_count

  # [1] BTC 价格
  log_section "获取 BTC 价格"
  local btc_json=$(curl -s "https://api.binance.com/api/v3/ticker/price?symbol=BTCUSDT")
  local btc_price=$(echo "$btc_json" | python3 -c "import sys,json; print(json.load(sys.stdin)['price'])")
  local btc_int=$(python3 -c "print(int(float('$btc_price') * 1e8))")
  log "BTC: \$$btc_price"

  finalize_stuck_round_on_axon "$btc_int"

  # [2] 发现市场
  log_section "发现 Polymarket 市场"
  local market_json=$(node "$SCRIPT_DIR/polymarket-trade.mjs" --find-market 2>/dev/null)
  if [ -z "$market_json" ] || echo "$market_json" | python3 -c "import sys,json; d=json.load(sys.stdin); exit(0 if 'error' in d else 1)" 2>/dev/null; then
    log "未找到活跃市场，跳过本轮"
    tg "⏭️ 未找到活跃 Polymarket 市场，跳过本轮"
    return 1
  fi

  local market_q=$(echo "$market_json" | python3 -c "import sys,json; print(json.load(sys.stdin)['question'])")
  local up_price=$(echo "$market_json" | python3 -c "import sys,json; print(json.load(sys.stdin)['upPrice'])")
  local down_price=$(echo "$market_json" | python3 -c "import sys,json; print(json.load(sys.stdin)['downPrice'])")
  local condition_id=$(echo "$market_json" | python3 -c "import sys,json; print(json.load(sys.stdin).get('conditionId', ''))" 2>/dev/null || echo "")
  log "市场: $market_q  UP:$up_price  DOWN:$down_price"

  # [3] 开轮
  log_section "Operator 开轮"
  local start_out=$(cast send "$HIVE_ROUND" "startRound(uint256)" "$btc_int" \
    --private-key "$OPERATOR_KEY" --rpc-url "$RPC" --gas-limit 500000 --legacy --gas-price 8000000000 2>&1)
  local start_status=$(echo "$start_out" | grep "^status" | awk '{print $2}')
  if [ "$start_status" = "0" ]; then
    log "⚠️ startRound 失败 — cast 输出:"
    echo "$start_out" | while IFS= read -r line; do log "  $line"; done
    tg "⚠️ startRound 失败，跳过本轮"
    return 1
  fi
  sleep 3

  local round_id_raw=$(cast call "$HIVE_ROUND" "currentRoundId()(uint256)" --rpc-url "$RPC" --block latest 2>&1)
  local round_id=$(cast_num "$round_id_raw")
  log "轮次 #$round_id 已开启"

  tg "📡 *Round #${round_id} 开始*
BTC: \$${btc_price}
市场: ${market_q}
赔率: UP ${up_price} | DN ${down_price}"

  # [4] 等待外部 Agent Commit
  log_section "等待 Agent Commit (${COMMIT_WAIT}s)"
  tg "📡 *Round #${round_id} 等待 Agent 提交预测*
窗口: ${COMMIT_WAIT}s"
  sleep "$COMMIT_WAIT"

  # 查看 commit 数量
  local rd_pre=$(cast call "$HIVE_ROUND" \
    "getRound(uint256)((uint8,uint256,uint256,uint256,uint256,uint256,uint256,int256,uint256))" \
    "$round_id" --rpc-url "$RPC" --block latest 2>&1)
  local commit_count=$(echo "$rd_pre" | python3 -c "
import sys; s=sys.stdin.read().strip().strip('()')
print(s.split(',')[5].strip().split()[0])
" 2>/dev/null || echo "0")
  log "收到 ${commit_count} 个 commit"

  if [ "${commit_count:-0}" -eq 0 ]; then
    log "无 Agent commit，跳过本轮（先链上结算空轮）"
    tg "⏭️ *Round #${round_id} 跳过*
无 Agent 提交预测"
    finalize_stuck_round_on_axon "$btc_int"
    return 1
  fi

  # [5] Advance to Reveal
  log_section "推进到 Reveal 阶段"
  cast send "$HIVE_ROUND" "advanceToReveal(uint256)" "$round_id" \
    --private-key "$OPERATOR_KEY" --rpc-url "$RPC" --gas-limit 100000 --legacy --gas-price 8000000000 > /dev/null 2>&1
  sleep 3

  # [6] 等待外部 Agent Reveal
  log_section "等待 Agent Reveal (${REVEAL_WAIT}s)"
  sleep "$REVEAL_WAIT"

  # [7] 计算 HiveScore 加权共识
  log_section "HiveScore 加权共识"

  local participants_raw=$(cast call "$HIVE_ROUND" "getParticipants(uint256)(address[])" "$round_id" --rpc-url "$RPC" 2>/dev/null || echo "[]")
  local participants=$(echo "$participants_raw" | tr -d '[],' | tr ' ' '\n' | grep '^0x' || true)

  local weighted_up=0 weighted_down=0 raw_up=0 raw_down=0
  local participant_count=0 revealed_count=0
  local agent_lines=""

  for addr in $participants; do
    participant_count=$((participant_count + 1))
    local commit_data=$(cast call "$HIVE_ROUND" \
      "getCommit(uint256,address)(bytes32,bool,uint8,uint8,uint256)" \
      "$round_id" "$addr" --rpc-url "$RPC" 2>/dev/null || echo "")
    [ -z "$commit_data" ] && continue

    # 合约返回: (commitHash, revealed, prediction, confidence, weight)
    local revealed=$(echo "$commit_data" | python3 -c "
import sys
lines = sys.stdin.read().strip().split('\n')
print(lines[1].strip() if len(lines) >= 2 else 'false')
" 2>/dev/null || echo "false")
    [ "$revealed" != "true" ] && continue
    revealed_count=$((revealed_count + 1))

    local pred=$(echo "$commit_data" | python3 -c "
import sys; lines = sys.stdin.read().strip().split('\n')
print(lines[2].strip().split()[0])
" 2>/dev/null || echo "0")
    local conf=$(echo "$commit_data" | python3 -c "
import sys; lines = sys.stdin.read().strip().split('\n')
print(lines[3].strip().split()[0])
" 2>/dev/null || echo "0")

    local score_raw=$(cast call "$HIVE_SCORE" "getScore(address)(uint256)" "$addr" --rpc-url "$RPC" 2>/dev/null | awk '{print $1}')
    local score=${score_raw:-0}
    # HiveScore 加权：Score=0 的 Agent 基础权重 1，有 Score 的按 Score 加权
    local multiplier=$((score > 0 ? score : 1))
    local w=$((conf * multiplier))

    local dir_label="UP"
    [ "$pred" -eq 1 ] && dir_label="DN"

    if [ "$pred" -eq 0 ]; then
      weighted_up=$((weighted_up + w))
      raw_up=$((raw_up + conf))
    else
      weighted_down=$((weighted_down + w))
      raw_down=$((raw_down + conf))
    fi

    local short_addr="${addr:0:10}"
    agent_lines+="
${short_addr}  ${dir_label}  conf=${conf}  score=${score}  w=${w}"
  done

  if [ "$revealed_count" -eq 0 ]; then
    log "无 Agent reveal，跳过本轮（先链上结算）"
    tg "⏭️ *Round #${round_id} 跳过*
无 Agent 完成 reveal"
    finalize_stuck_round_on_axon "$btc_int"
    return 1
  fi

  local swarm_bet="UP"
  [ "$weighted_down" -gt "$weighted_up" ] && swarm_bet="DOWN"
  log "HiveScore 加权共识 ($revealed_count 个 Agent): $swarm_bet (UP=$weighted_up vs DOWN=$weighted_down)"
  log "  原始权重对比: UP=$raw_up vs DOWN=$raw_down"

  local up_pct=$(python3 -c "
u=$weighted_up; d=$weighted_down
t=u+d
print(f'{u*100/t:.0f}' if t>0 else '0')
")

  # 检查是否达到合约的 60% 超级多数阈值（与 HiveRound.DECISION_THRESHOLD_BPS 对齐）
  local signal_strong=$(python3 -c "
u=$weighted_up; d=$weighted_down
t=u+d
if t == 0:
    print('false')
else:
    up_bps = u * 10000 // t
    print('true' if (up_bps >= 6000 or up_bps <= 4000) else 'false')
")

  tg "🧠 *Round #${round_id} 蜂群共识 (HiveScore 加权)*
BTC: \$${btc_price}
市场: UP ${up_price} | DN ${down_price}
参与 Agent: *${revealed_count}* / ${participant_count} 个
信号强度: ${up_pct}% UP $([ "$signal_strong" = "true" ] && echo '✅ 达标' || echo '⚠️ 未达60%阈值')
\`\`\`
Agent 预测:
─────────────────────────────${agent_lines}
─────────────────────────────
加权共识: ${swarm_bet}
UP ${up_pct}%  (加权 ${weighted_up})
DN $((100 - ${up_pct:-0}))%  (加权 ${weighted_down})
原始: UP=${raw_up} DN=${raw_down}
\`\`\`"

  if [ "$signal_strong" != "true" ]; then
    log "信号不足 (${up_pct}% UP，未达 60% 阈值)，跳过下注（先链上结算）"
    tg "⏭️ *Round #${round_id} 跳过下注*
信号 ${up_pct}% 未达 60% 超级多数阈值
合约不会更新 HiveScore，跳过避免无效亏损"
    finalize_stuck_round_on_axon "$btc_int"
    return 1
  fi

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
  local trade_success=$(echo "$trade_json" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('success', False))" 2>/dev/null || echo "False")
  local trade_error=$(echo "$trade_json" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('error','') or d.get('errorMsg','') or ('order_failed' if not d.get('success') else ''))" 2>/dev/null || echo "unknown")

  local fill_price=0 shares=0 bet_placed=false
  if [ "$trade_success" = "True" ]; then
    fill_price=$(echo "$trade_json" | python3 -c "import sys,json; print(json.load(sys.stdin).get('fillPrice', 0))")
    shares=$(echo "$trade_json" | python3 -c "import sys,json; print(json.load(sys.stdin).get('shares', 0))")
    log "下注成功 fillPrice=$fill_price shares=$shares"
    tg "🐝 *Round #${round_id} 下注*
方向: *${swarm_bet}* | 金额: \$${BET_AMOUNT}
价格: ${fill_price} | 份额: ${shares}
BTC: \$${btc_price}"
    bet_placed=true
  elif [ "$trade_error" = "price_too_high" ]; then
    local rejected_price=$(echo "$trade_json" | python3 -c "import sys,json; print(json.load(sys.stdin).get('fillPrice', '?'))" 2>/dev/null || echo "?")
    log "赔率不利 (price=$rejected_price > max=$MAX_PRICE)，跳过本轮下注"
    tg "⏭️ *Round #${round_id} 跳过*
赔率 ${rejected_price} > 上限 ${MAX_PRICE}"
  else
    log "下注失败: $trade_error"
    tg "⚠️ *Round #${round_id} 下注失败*
错误: \`${trade_error}\`"
  fi

  # [9] 等待市场结算
  log_section "等待市场结算"
  local now=$(date +%s)
  local slot_size=900
  local current_slot_end=$((( now / slot_size + 1) * slot_size ))
  local wait_secs=$(( current_slot_end - now + 30 ))
  [ "$wait_secs" -gt 960 ] && wait_secs=960

  log "等待 ${wait_secs}s..."
  local wait_min=$(python3 -c "print(f'{$wait_secs/60:.0f}')")
  tg "⏳ *Round #${round_id} 等待结算*
约 ${wait_min} 分钟后结算..."
  sleep "$wait_secs"

  # [10] 赎回条件代币（等待 Oracle resolve）
  if [ "$bet_placed" = true ]; then
    log_section "赎回条件代币"
    tg "🔄 *Round #${round_id} 等待 Oracle resolve 后赎回...*"

    local redeem_attempts=0
    local max_attempts=$((REDEEM_MAX_WAIT / 30))
    local redeemed_value=0

    while [ "$redeem_attempts" -lt "$max_attempts" ]; do
      redeem_attempts=$((redeem_attempts + 1))
      sleep 30

      local pre_bal=$(get_proxy_balance)
      node "$SCRIPT_DIR/redeem-wins.mjs" --hours 1 2>>"$LOG_FILE" | tee -a "$LOG_FILE"
      local post_bal=$(get_proxy_balance)
      redeemed_value=$(python3 -c "print(int('$post_bal') - int('$pre_bal'))")

      if [ "$redeemed_value" -gt 0 ]; then
        local rv_usd=$(python3 -c "print(f'{$redeemed_value / 1e6:.2f}')")
        log "赎回成功: +\$$rv_usd (第 ${redeem_attempts} 次尝试)"
        break
      fi

      log "赎回尝试 ${redeem_attempts}/${max_attempts}: 余额未变化，Oracle 可能未 resolve，等待..."
    done

    if [ "$redeemed_value" -le 0 ]; then
      log "赎回未产生收益 (已尝试 ${redeem_attempts} 次)"
    fi
    log "赎回流程完成"
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

  if [ "$bet_placed" = true ]; then
    local emoji="❌"
    [ "$profit_loss" -gt 0 ] && emoji="✅"
    local bal_usd_before=$(python3 -c "print(f'{int(\"$bal_before\") / 1e6:.2f}')")
    local bal_usd_after=$(python3 -c "print(f'{int(\"$bal_after\") / 1e6:.2f}')")
    local pol_raw=$(cast balance "$POLYMARKET_FUNDER" --rpc-url "$POLYGON_RPC" 2>/dev/null || echo "0")
    local pol_bal=$(python3 -c "print(f'{int(\"$pol_raw\") / 1e18:.4f}')")
    tg "${emoji} *Round #${round_id} 结算*
BTC: \$${btc_price} → \$${btc_close} (*${actual_dir}*)
预测: *${swarm_bet}* | 结果: *${result_text}*

💰 *钱包资产*
\`\`\`
USDC.e (下注前): \$${bal_usd_before}
USDC.e (赎回后): \$${bal_usd_after}
本轮 P&L:        \$${pnl_usd}
POL (Gas):        ${pol_bal}
\`\`\`"
  fi

  # [12] 链上结算
  log_section "Axon 链上结算"
  local settle_out=$(cast send "$HIVE_ROUND" "settle(uint256,uint256,int256)" \
    "$round_id" "$btc_close_int" "$profit_loss" \
    --private-key "$OPERATOR_KEY" --rpc-url "$RPC" --gas-limit 8000000 --legacy --gas-price 8000000000 2>&1)
  local settle_status=$(echo "$settle_out" | grep "^status" | awk '{print $2}')
  if [ "$settle_status" = "0" ]; then
    log "⚠️ settle 失败 — 可能 gas 不足"
  fi
  log "链上结算完成"

  sleep 3

  # [13] HiveScore 更新验证 (查询所有参与者)
  local score_lines=""
  local part_list=$(cast call "$HIVE_ROUND" "getParticipants(uint256)(address[])" "$round_id" --rpc-url "$RPC" 2>/dev/null || echo "[]")
  local part_addrs=$(echo "$part_list" | tr -d '[],' | tr ' ' '\n' | grep '^0x' || true)

  for addr in $part_addrs; do
    local score_raw=$(cast call "$HIVE_SCORE" "getScore(address)(uint256)" "$addr" --rpc-url "$RPC" --block latest 2>&1)
    local streak_raw=$(cast call "$HIVE_SCORE" "getStreak(address)(int256)" "$addr" --rpc-url "$RPC" --block latest 2>&1)
    local s=$(cast_num "$score_raw")
    local st=$(cast_num "$streak_raw")
    local short="${addr:0:10}"
    log "  $short Score=$s Streak=$st"
    score_lines+="
${short}: Score=$s Streak=$st"
  done

  tg "📊 *Round #${round_id} HiveScore 更新*
\`\`\`${score_lines}
\`\`\`"

  # [14] 利润分发（仅盈利时）
  if [ "$profit_loss" -gt 0 ]; then
    log_section "利润分发"
    local dist_output=$(node "$SCRIPT_DIR/distribute-bsc.mjs" \
      --round-id "$round_id" \
      --total-profit "$pnl_usd" \
      --actual-direction "$actual_dir" 2>>"$LOG_FILE")
    echo "$dist_output" | tee -a "$LOG_FILE"

    local agent_pool=$(python3 -c "print(f'{float(\"$pnl_usd\") * 0.35:.2f}')")
    local reserve_pool=$(python3 -c "print(f'{float(\"$pnl_usd\") * 0.25:.2f}')")
    local keep_pool=$(python3 -c "print(f'{float(\"$pnl_usd\") * 0.40:.2f}')")

    # 解析 distribute 输出，提取每个 Agent 的分发明细
    local agent_detail_lines=$(echo "$dist_output" | grep -E '^\s+✅ Agent|^\s+\[模拟\] Agent' | \
      python3 -c "
import sys
lines = []
for l in sys.stdin:
    l = l.strip()
    parts = l.replace('✅','').replace('[模拟]','').strip()
    lines.append(parts)
if lines:
    print('\n'.join(lines))
else:
    print('(无明细)')
" 2>/dev/null || echo "(无明细)")

    # 获取分发后最新余额
    local bal_post_dist=$(get_proxy_balance)
    local bal_post_dist_usd=$(python3 -c "print(f'{int(\"$bal_post_dist\") / 1e6:.2f}')")

    tg "💰 *Round #${round_id} 利润分发*
总利润: *\$${pnl_usd}*

📋 *分配方案*
\`\`\`
Agent 35%: \$${agent_pool}
储备  25%: \$${reserve_pool}
留存  40%: \$${keep_pool}
\`\`\`

👤 *Agent 分发明细*
\`\`\`
${agent_detail_lines}
\`\`\`

🏦 分发后金库: \$${bal_post_dist_usd}"
  else
    local bal_no_dist=$(python3 -c "print(f'{int(\"$bal_after\") / 1e6:.2f}')")
    tg "📉 *Round #${round_id} 无利润分发*
本轮 P\&L: \$${pnl_usd} (亏损)
🏦 金库余额: \$${bal_no_dist}
下轮继续..."
  fi

  # 更新统计
  TOTAL_PNL=$(python3 -c "print(f'{$TOTAL_PNL + $profit_loss / 1e6:.2f}')")
  ROUND_COUNT=$((ROUND_COUNT + 1))

  local elapsed=$(( $(date +%s) - round_start ))
  log "═══ 轮次 #$round_id 完成 | P&L: \$$pnl_usd | 累计: \$$TOTAL_PNL | 耗时: ${elapsed}s ═══"
  echo "" >> "$LOG_FILE"

  local final_bal=$(python3 -c "print(f'{int(\"$bal_after\") / 1e6:.2f}')")
  tg "🏁 *Round #${round_id} 完成*
⏱ 耗时: ${elapsed}s
💰 本轮 P&L: \$${pnl_usd}
📈 累计 P&L: \$${TOTAL_PNL}
🏦 金库: \$${final_bal}
🔄 已完成: ${ROUND_COUNT} 轮"

  return 0
}

# ─── 主循环 ───────────────────────────────────────────
log ""
log "╔═══════════════════════════════════════════════════════════╗"
log "║    蜂巢协议 — 自动运行守护进程 v3 (纯 Operator)        ║"
log "╚═══════════════════════════════════════════════════════════╝"
log "  PID: $$"
log "  模式: 纯 Operator (无内部 Agent，仅管理轮次)"
log "  共识: HiveScore 加权"
log "  等待 Commit: ${COMMIT_WAIT}s | Reveal: ${REVEAL_WAIT}s"
log "  每轮下注: 金库 × ${BET_PCT}% (最低 \$${BET_MIN}, 上限 \$${BET_MAX})"
log "  最大可接受价格: $MAX_PRICE"
log "  最大轮数: $([ $MAX_ROUNDS -eq 0 ] && echo '无限' || echo $MAX_ROUNDS)"

tg "🚀 *蜂巢协议 v3 启动 (纯 Operator)*
PID: \`$$\`
模式: 无内部 Agent，HiveScore 加权共识
等待窗口: Commit ${COMMIT_WAIT}s | Reveal ${REVEAL_WAIT}s
下注: 金库 × ${BET_PCT}% (\$${BET_MIN}~\$${BET_MAX})
价格上限: ${MAX_PRICE}"
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
