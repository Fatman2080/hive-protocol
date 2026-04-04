/**
 * 蜂巢协议 — Polygon USDC.e 利润分发 (v2)
 *
 * 只奖励预测正确的 Agent，按 HiveScore × confidence 加权分配
 *
 * 分配比例:
 *   35% → 预测正确的 Agent 按权重分润
 *   25% → 储备地址
 *   40% → 留存金库
 *
 * 用法:
 *   node scripts/distribute-bsc.mjs --round-id 42 --total-profit 200 --actual-direction UP [--dry-run]
 */

import { createPublicClient, createWalletClient, http, formatUnits, parseUnits, parseAbi } from 'viem';
import { polygon } from 'viem/chains';
import { privateKeyToAccount } from 'viem/accounts';
import { readFileSync } from 'fs';

// ─── 读 .env ─────────────────────────────────────────
function loadEnv() {
  try {
    const lines = readFileSync(new URL('../.env', import.meta.url), 'utf8').split('\n');
    for (const l of lines) {
      const m = l.match(/^([A-Z_]+)=(.+)$/);
      if (m && !process.env[m[1]]) process.env[m[1]] = m[2].trim();
    }
  } catch {}
}
loadEnv();

// ─── 常量 ─────────────────────────────────────────────
const AXON_RPC    = 'https://mainnet-rpc.axonchain.ai/';
const POLYGON_RPC = 'https://polygon-bor-rpc.publicnode.com';
const USDC_E      = '0x2791Bca1f2de4661ED88A30C99A7a9449Aa84174'; // Polygon USDC.e (6 decimals)

const POLYMARKET_PK = process.env.POLYMARKET_PRIVATE_KEY;
const HIVE_AGENT    = process.env.HIVE_AGENT_ADDRESS || '0x4222fE51db0b8e2c79460fF963Fe2B56B54Cbc45';
const HIVE_SCORE    = process.env.HIVE_SCORE_ADDRESS || '0xc55EC85F2ee552F565f13f2dc9c77fd6B16F3b14';
const RESERVE_ADDR  = process.env.RESERVE_ADDRESS;

const AGENT_SHARE_PCT   = 35;
const RESERVE_SHARE_PCT = 25; // 10% buyback + 10% risk + 5% ops

// ─── 参数 ─────────────────────────────────────────────
const args = process.argv.slice(2);
const getArg = (n) => { const i = args.indexOf(`--${n}`); return i >= 0 ? args[i+1] : null; };
const DRY_RUN      = args.includes('--dry-run');
const ROUND_ID     = parseInt(getArg('round-id') || '0');
const TOTAL_PROFIT = parseFloat(getArg('total-profit') || '0');
const ACTUAL_DIR   = (getArg('actual-direction') || '').toUpperCase(); // UP or DOWN

if (!ROUND_ID || !TOTAL_PROFIT || !['UP', 'DOWN'].includes(ACTUAL_DIR)) {
  console.error('用法: node distribute-bsc.mjs --round-id <N> --total-profit <USDC金额> --actual-direction <UP|DOWN>');
  process.exit(1);
}
if (!POLYMARKET_PK && !DRY_RUN) {
  console.error('错误: .env 中缺少 POLYMARKET_PRIVATE_KEY');
  process.exit(1);
}

// ─── 客户端 ──────────────────────────────────────────
const axon = createPublicClient({ transport: http(AXON_RPC) });
const polyPub = createPublicClient({ chain: polygon, transport: http(POLYGON_RPC) });

const agentAbi = parseAbi([
  'function isActive(address) view returns (bool)',
  'function getStake(address) view returns (uint256)',
]);
const scoreAbi = parseAbi([
  'function getScore(address) view returns (uint256)',
]);
const erc20Abi = parseAbi([
  'function transfer(address,uint256) returns (bool)',
  'function balanceOf(address) view returns (uint256)',
]);
// ─── Agent 地址：从链上动态获取 ─────────────────────
const HIVE_ROUND = process.env.HIVE_ROUND_ADDRESS || '0xCA4b670D1a91E52a90A390836E1397929DbAcd02';
const roundAbi = parseAbi([
  'function getParticipants(uint256 roundId) view returns (address[])',
  'function getCommit(uint256 roundId, address agent) view returns (bytes32 commitHash, bool revealed, uint8 prediction, uint8 confidence, uint256 weight)',
]);

// ─── 主流程 ──────────────────────────────────────────
const account = POLYMARKET_PK ? privateKeyToAccount(POLYMARKET_PK) : null;
const agentPool   = TOTAL_PROFIT * AGENT_SHARE_PCT / 100;
const reservePool = TOTAL_PROFIT * RESERVE_SHARE_PCT / 100;
const treasuryKeep = TOTAL_PROFIT * 40 / 100;

const correctPred = ACTUAL_DIR === 'UP' ? 0 : 1; // 0=UP, 1=DOWN

console.log('═══════════════════════════════════════════════════');
console.log('  蜂巢协议 — Polygon USDC.e 利润分发 v2');
console.log('═══════════════════════════════════════════════════');
console.log(`  轮次 #${ROUND_ID}  |  总利润 $${TOTAL_PROFIT}  |  实际方向: ${ACTUAL_DIR}`);
console.log(`  ├ Agent 35%  $${agentPool.toFixed(2)}  (仅预测正确者)`);
console.log(`  ├ 储备 25%   $${reservePool.toFixed(2)} → ${RESERVE_ADDR.slice(0,10)}...`);
console.log(`  └ 留存 40%   $${treasuryKeep.toFixed(2)} → 留在 Polymarket`);
console.log(`  EOA: ${account?.address || '(dry-run)'}`);
console.log(`  模式: ${DRY_RUN ? '模拟' : '实际转账'}`);
console.log('');

// Step 1: 获取参与者 + 预测 + HiveScore
console.log('[1] 读取链上参与者预测数据...');

let participants;
try {
  participants = await axon.readContract({
    address: HIVE_ROUND, abi: roundAbi,
    functionName: 'getParticipants', args: [BigInt(ROUND_ID)],
  });
} catch {
  participants = [];
}

if (participants.length === 0) {
  console.log('  ⚠️  无参与者，跳过分发');
  process.exit(0);
}

const allAgents = [];
const winners = [];

for (const addr of participants) {
  try {
    const [active, scoreVal, commitData] = await Promise.all([
      axon.readContract({ address: HIVE_AGENT, abi: agentAbi, functionName: 'isActive', args: [addr] }),
      axon.readContract({ address: HIVE_SCORE, abi: scoreAbi, functionName: 'getScore', args: [addr] }),
      axon.readContract({ address: HIVE_ROUND, abi: roundAbi, functionName: 'getCommit', args: [BigInt(ROUND_ID), addr] }),
    ]);

    if (!active) continue;

    const [, revealed, prediction, confidence] = commitData;
    if (!revealed) continue;

    const scoreNum = Number(scoreVal);
    const confNum = Number(confidence);
    const predNum = Number(prediction);
    const predDir = predNum === 0 ? 'UP' : 'DOWN';
    const isCorrect = predNum === correctPred;
    const shortAddr = addr.slice(0, 10);

    const icon = isCorrect ? '✅' : '❌';
    console.log(`  ${icon} ${shortAddr}...  预测=${predDir} conf=${confNum}  Score=${scoreNum}  ${isCorrect ? '→ 有分润' : '→ 无分润'}`);

    allAgents.push({ name: shortAddr, addr, score: scoreNum, confidence: confNum, prediction: predDir, correct: isCorrect });

    if (isCorrect) {
      winners.push({ name: shortAddr, addr, score: scoreNum, confidence: confNum });
    }
  } catch { continue; }
}

console.log(`\n  参与: ${allAgents.length} 个  |  预测正确: ${winners.length} 个  |  错误: ${allAgents.length - winners.length} 个`);

if (winners.length === 0) {
  console.log('\n⚠️  无 Agent 预测正确，Agent 份额留存金库');
  // 仍然分发储备金部分
}

// Step 2: 按 HiveScore × confidence 加权分润（仅正确者）
console.log(`\n[2] HiveScore × confidence 加权分润 (${winners.length} 个正确 Agent)...`);

let totalWeight = 0;
for (const a of winners) {
  const multiplier = Math.max(1, a.score);
  a.weight = multiplier * a.confidence;
  totalWeight += a.weight;
}

for (const a of winners) {
  a.share = totalWeight > 0 ? (a.weight / totalWeight) * agentPool : 0;
}

const maxNameLen = winners.length > 0 ? Math.max(...winners.map(a => a.name.length)) : 10;
for (const a of winners) {
  const pct = totalWeight > 0 ? (a.weight / totalWeight * 100).toFixed(1) : '0.0';
  console.log(`  ${a.name.padEnd(maxNameLen)}  Score=${String(a.score).padStart(3)}  conf=${String(a.confidence).padStart(3)}  权重=${a.weight.toFixed(0).padStart(6)}  占比=${pct.padStart(5)}%  → $${a.share.toFixed(4)}`);
}

const eligible = winners;

// Step 3: EOA 直接 ERC-20 转账 (Polygon)
console.log(`\n[3] Polygon USDC.e 分发 — EOA 直接转账 (Agent 35% + 储备 25%)...`);

const totalTransferNeeded = agentPool + reservePool;

if (!DRY_RUN && account) {
  const polyWallet = createWalletClient({ account, chain: polygon, transport: http(POLYGON_RPC) });

  let successCount = 0;
  let totalSent = 0;

  // Agent 逐笔转账
  for (const a of eligible) {
    if (a.share < 0.001) { console.log(`  [跳过] ${a.name} 金额太小`); continue; }
    const amount = parseUnits(a.share.toFixed(6), 6);
    try {
      const hash = await polyWallet.writeContract({
        address: USDC_E, abi: erc20Abi,
        functionName: 'transfer', args: [a.addr, amount],
      });
      console.log(`  ✅ Agent  ${a.name.padEnd(maxNameLen)} → $${a.share.toFixed(4)}  tx:${hash.slice(0,18)}...`);
      successCount++;
      totalSent += a.share;
    } catch (e) {
      console.error(`  ❌ Agent  ${a.name} 转账失败: ${e.shortMessage || e.message}`);
    }
  }

  // 储备地址转账 (25%)
  const reserveAmount = parseUnits(reservePool.toFixed(6), 6);
  try {
    const hash = await polyWallet.writeContract({
      address: USDC_E, abi: erc20Abi,
      functionName: 'transfer', args: [RESERVE_ADDR, reserveAmount],
    });
    console.log(`  ✅ 储备   25%        → $${reservePool.toFixed(4)}  tx:${hash.slice(0,18)}...`);
    successCount++;
    totalSent += reservePool;
  } catch (e) {
    console.error(`  ❌ 储备转账失败: ${e.shortMessage || e.message}`);
  }

  console.log(`\n  完成: ${successCount} 笔转账, 共 $${totalSent.toFixed(2)} USDC.e`);
} else {
  for (const a of eligible) {
    console.log(`  [模拟] Agent  ${a.name.padEnd(maxNameLen)} → ${a.addr.slice(0,10)}... $${a.share.toFixed(4)}`);
  }
  console.log(`  [模拟] 储备   25%        → ${RESERVE_ADDR.slice(0,10)}... $${reservePool.toFixed(4)}`);
}

// Step 4: 汇总
console.log('\n─── 本轮分配 ────────────────────────────────────');
console.log(`  总利润     $${TOTAL_PROFIT.toFixed(2)}`);
console.log(`  ├ Agent 35%  $${agentPool.toFixed(2)}  → Polygon USDC.e 已发`);
console.log(`  ├ 储备 25%   $${reservePool.toFixed(2)}  → ${RESERVE_ADDR.slice(0,10)}...`);
console.log(`  │  ├ 回购 10%  $${(TOTAL_PROFIT*0.10).toFixed(2)}`);
console.log(`  │  ├ 风险 10%  $${(TOTAL_PROFIT*0.10).toFixed(2)}`);
console.log(`  │  └ 运营  5%  $${(TOTAL_PROFIT*0.05).toFixed(2)}`);
console.log(`  └ 留存 40%   $${treasuryKeep.toFixed(2)}  → 留在 Polymarket 继续滚`);
console.log('─────────────────────────────────────────────────\n');
