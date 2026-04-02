/**
 * 蜂巢协议 — 全链路端到端联调脚本 (DryRun 模式)
 *
 * 模拟完整的一轮预测流程：
 *  1. 从 Binance 获取实时 BTC 价格
 *  2. 发现 Polymarket BTC 15m 市场
 *  3. 模拟 5 个 Agent 的预测信号
 *  4. 执行信号聚合 → 得出方向
 *  5. 模拟 Polymarket 下注（不实际交易）
 *  6. 等待 15 分钟后结算
 *  7. 计算 P&L
 *
 * 用法：node scripts/e2e-dry-run.mjs [--fast]
 *   --fast: 快速模式（30 秒等待而非 15 分钟）
 */

const FAST_MODE = process.argv.includes('--fast');
const WAIT_SECS = FAST_MODE ? 30 : 15 * 60;

const GAMMA_HOST = 'https://gamma-api.polymarket.com';
const CLOB_HOST = 'https://clob.polymarket.com';
const BINANCE_API = 'https://api.binance.com/api/v3';

// ─── 模拟 5 个 Agent 的预测函数 ──────────────────────

function randomPredict() {
  const direction = Math.random() > 0.5 ? 'UP' : 'DOWN';
  const confidence = Math.floor(Math.random() * 40) + 20;
  return { name: 'Random', direction, confidence };
}

function momentumPredict(closes) {
  if (closes.length < 5) return { name: 'Momentum', direction: 'UP', confidence: 30 };

  const ema5 = closes.slice(-5).reduce((a, b) => a + b) / 5;
  const ema15 = closes.reduce((a, b) => a + b) / closes.length;
  const diff = ema5 - ema15;

  return {
    name: 'Momentum',
    direction: diff > 0 ? 'UP' : 'DOWN',
    confidence: Math.min(70, 30 + Math.floor(Math.abs(diff / closes[closes.length - 1]) * 10000)),
  };
}

function sentimentPredict(upProb) {
  if (upProb > 0.65) {
    return { name: 'Sentiment', direction: 'DOWN', confidence: Math.min(80, 40 + Math.floor((upProb - 0.5) * 200)) };
  } else if (upProb < 0.35) {
    return { name: 'Sentiment', direction: 'UP', confidence: Math.min(80, 40 + Math.floor((0.5 - upProb) * 200)) };
  }
  return { name: 'Sentiment', direction: upProb >= 0.5 ? 'UP' : 'DOWN', confidence: 30 };
}

function contrarianPredict(closes) {
  if (closes.length < 12) return { name: 'Contrarian', direction: 'UP', confidence: 25 };

  const vwap = closes.reduce((a, b) => a + b) / closes.length;
  const current = closes[closes.length - 1];
  const devPct = ((current - vwap) / vwap) * 100;

  if (devPct > 0.3) {
    return { name: 'Contrarian', direction: 'DOWN', confidence: Math.min(75, 35 + Math.floor(devPct * 50)) };
  } else if (devPct < -0.3) {
    return { name: 'Contrarian', direction: 'UP', confidence: Math.min(75, 35 + Math.floor(Math.abs(devPct) * 50)) };
  }
  return { name: 'Contrarian', direction: devPct > 0 ? 'DOWN' : 'UP', confidence: 25 };
}

function llmPredict(closes) {
  // 模拟 LLM：使用简单的 RSI 近似
  if (closes.length < 14) return { name: 'LLM-Sim', direction: 'UP', confidence: 40 };

  let gains = 0, losses = 0;
  for (let i = closes.length - 14; i < closes.length; i++) {
    const diff = closes[i] - closes[i - 1];
    if (diff > 0) gains += diff;
    else losses -= diff;
  }
  const rsi = gains / (gains + losses) * 100;

  if (rsi > 60) return { name: 'LLM-Sim', direction: 'UP', confidence: Math.min(70, 30 + Math.floor((rsi - 50) * 2)) };
  if (rsi < 40) return { name: 'LLM-Sim', direction: 'DOWN', confidence: Math.min(70, 30 + Math.floor((50 - rsi) * 2)) };
  return { name: 'LLM-Sim', direction: rsi >= 50 ? 'UP' : 'DOWN', confidence: 35 };
}

// ─── 信号聚合（与合约逻辑一致）──────────────────────

function aggregateSignals(predictions) {
  let upWeight = 0;
  let downWeight = 0;

  for (const p of predictions) {
    const weight = p.confidence; // 简化：权重 = 信心度
    if (p.direction === 'UP') upWeight += weight;
    else downWeight += weight;
  }

  const total = upWeight + downWeight;
  const upRatio = total > 0 ? upWeight / total : 0.5;

  let finalDirection;
  let shouldBet;

  if (upRatio >= 0.6) {
    finalDirection = 'UP';
    shouldBet = true;
  } else if (upRatio <= 0.4) {
    finalDirection = 'DOWN';
    shouldBet = true;
  } else {
    finalDirection = 'SKIP';
    shouldBet = false;
  }

  return { upWeight, downWeight, upRatio, finalDirection, shouldBet };
}

// ─── 主流程 ─────────────────────────────────────────

async function main() {
  console.log('═══════════════════════════════════════════════════════');
  console.log('  蜂巢协议 — 全链路端到端联调');
  console.log(`  模式: ${FAST_MODE ? '快速 (30s)' : '完整 (15m)'}`);
  console.log('═══════════════════════════════════════════════════════\n');

  // Step 1: 获取 BTC 实时价格 + K 线
  console.log('[1/7] 获取 BTC 行情数据...');
  const klineRes = await fetch(`${BINANCE_API}/klines?symbol=BTCUSDT&interval=5m&limit=20`);
  const klines = await klineRes.json();
  const closes = klines.map(k => parseFloat(k[4]));
  const openPrice = closes[closes.length - 1];
  console.log(`  BTC 当前价: $${openPrice.toLocaleString()}`);
  console.log(`  20 根 5m K 线已获取\n`);

  // Step 2: 发现 Polymarket 市场
  console.log('[2/7] 发现 Polymarket BTC 15m 市场...');
  const now = Math.floor(Date.now() / 1000);
  const interval = 15 * 60;
  const currentSlot = Math.floor(now / interval) * interval;
  const slug = `btc-updown-15m-${currentSlot}`;

  let upProb = 0.5;
  try {
    const gammaRes = await fetch(`${GAMMA_HOST}/markets/slug/${slug}`);
    if (gammaRes.ok) {
      const market = await gammaRes.json();
      const tokenIds = JSON.parse(market.clobTokenIds || '[]');
      console.log(`  市场: ${market.question || slug}`);

      if (tokenIds.length >= 1) {
        const midRes = await fetch(`${CLOB_HOST}/midpoint?token_id=${tokenIds[0]}`);
        if (midRes.ok) {
          const midData = await midRes.json();
          upProb = parseFloat(midData.mid || '0.5');
          console.log(`  UP 概率: ${(upProb * 100).toFixed(1)}%`);
        }
      }
    } else {
      console.log(`  (市场 ${slug} 暂不可用，使用默认赔率)`);
    }
  } catch (e) {
    console.log(`  (Gamma API 异常: ${e.message})`);
  }
  console.log('');

  // Step 3: 模拟 5 个 Agent 预测
  console.log('[3/7] 5 个 Agent 提交预测...');
  const predictions = [
    randomPredict(),
    momentumPredict(closes),
    sentimentPredict(upProb),
    contrarianPredict(closes),
    llmPredict(closes),
  ];

  for (const p of predictions) {
    const arrow = p.direction === 'UP' ? '↑' : '↓';
    console.log(`  ${p.name.padEnd(12)} ${arrow} ${p.direction.padEnd(4)} confidence=${p.confidence}`);
  }
  console.log('');

  // Step 4: 信号聚合
  console.log('[4/7] 信号聚合...');
  const agg = aggregateSignals(predictions);
  console.log(`  UP 权重: ${agg.upWeight} | DOWN 权重: ${agg.downWeight}`);
  console.log(`  UP 占比: ${(agg.upRatio * 100).toFixed(1)}%`);
  console.log(`  决策: ${agg.finalDirection} ${agg.shouldBet ? '(下注)' : '(跳过)'}`);
  console.log('');

  // Step 5: 模拟下注
  const betAmount = 200; // $200
  console.log('[5/7] 模拟下注...');
  if (agg.shouldBet) {
    console.log(`  方向: ${agg.finalDirection}`);
    console.log(`  金额: $${betAmount} USDC`);
    console.log(`  执行器: DryRun (模拟)`);
  } else {
    console.log(`  跳过本轮 (信号不足)`);
  }
  console.log('');

  // Step 6: 等待结算
  console.log(`[6/7] 等待结算 (${WAIT_SECS}s)...`);

  for (let i = WAIT_SECS; i > 0; i -= 5) {
    const pctDone = ((WAIT_SECS - i) / WAIT_SECS * 100).toFixed(0);
    process.stdout.write(`\r  ⏳ ${i}s 剩余... [${pctDone}%]`);
    await new Promise(r => setTimeout(r, Math.min(5000, i * 1000)));
  }
  console.log('\r  ✅ 等待完成                 \n');

  // Step 7: 读取收盘价 + 结算
  console.log('[7/7] 读取收盘价，结算...');
  const closeRes = await fetch(`${BINANCE_API}/ticker/price?symbol=BTCUSDT`);
  const closeData = await closeRes.json();
  const closePrice = parseFloat(closeData.price);

  const btcWentUp = closePrice >= openPrice;
  const priceChange = closePrice - openPrice;
  const priceChangePct = (priceChange / openPrice * 100).toFixed(3);

  console.log(`  开盘价: $${openPrice.toLocaleString()}`);
  console.log(`  收盘价: $${closePrice.toLocaleString()}`);
  console.log(`  变动:   ${priceChange >= 0 ? '+' : ''}$${priceChange.toFixed(2)} (${priceChangePct}%)`);
  console.log(`  实际:   ${btcWentUp ? 'UP ↑' : 'DOWN ↓'}`);

  let pnl = 0;
  if (agg.shouldBet) {
    const correct = (agg.finalDirection === 'UP') === btcWentUp;
    pnl = correct ? betAmount : -betAmount;

    console.log(`  预测:   ${agg.finalDirection}`);
    console.log(`  结果:   ${correct ? '✅ 正确' : '❌ 错误'}`);
    console.log(`  P&L:    ${pnl >= 0 ? '+' : ''}$${pnl}`);
  } else {
    console.log(`  本轮跳过，P&L: $0`);
  }
  console.log('');

  // Agent 战绩
  console.log('─── Agent 战绩 ───────────────────────────────────');
  for (const p of predictions) {
    const correct = (p.direction === 'UP') === btcWentUp;
    const icon = correct ? '✅' : '❌';
    const scoreChange = correct ? '+3' : '-2';
    console.log(`  ${p.name.padEnd(12)} ${p.direction.padEnd(4)} ${icon} HiveScore ${scoreChange}`);
  }

  // 金库状态
  console.log('');
  console.log('─── 金库状态 ─────────────────────────────────────');
  const treasury = 10000 + pnl;
  console.log(`  初始:   $10,000`);
  console.log(`  P&L:    ${pnl >= 0 ? '+' : ''}$${pnl}`);
  console.log(`  当前:   $${treasury.toLocaleString()}`);
  if (pnl > 0) {
    console.log(`  分配:   Agent 分润 $${(pnl * 0.35).toFixed(0)} | 留存 $${(pnl * 0.40).toFixed(0)} | 回购 $${(pnl * 0.10).toFixed(0)} | 储备 $${(pnl * 0.10).toFixed(0)} | 运营 $${(pnl * 0.05).toFixed(0)}`);
  }

  console.log('\n═══════════════════════════════════════════════════════');
  console.log('  联调完成！');
  console.log('═══════════════════════════════════════════════════════\n');
}

main().catch(console.error);
