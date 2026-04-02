/**
 * 蜂巢协议 — Polygon USDC.e 利润分发
 *
 * 分配比例:
 *   35% → Agent 按权重分润 (Polygon USDC.e)
 *   25% → 储备地址 (回购10% + 风险10% + 运营5%)
 *   40% → 留存 Polymarket 金库 (自动，不需要转账)
 *
 * 利润通过 Polymarket ProxyWalletFactory.proxy() 从 Proxy Wallet 转出
 *
 * 用法:
 *   node scripts/distribute-bsc.mjs --round-id 42 --total-profit 200 [--dry-run]
 */

import { createPublicClient, createWalletClient, http, formatUnits, parseUnits, parseAbi, encodeFunctionData } from 'viem';
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
const FACTORY     = '0xab45c5a4b0c941a2f231c04c3f49182e1a254052'; // ProxyWalletFactory

const POLYMARKET_PK = process.env.POLYMARKET_PRIVATE_KEY;
const HIVE_AGENT    = process.env.HIVE_AGENT_ADDRESS || '0x4222fE51db0b8e2c79460fF963Fe2B56B54Cbc45';
const HIVE_SCORE    = process.env.HIVE_SCORE_ADDRESS || '0xc55EC85F2ee552F565f13f2dc9c77fd6B16F3b14';
const RESERVE_ADDR  = process.env.RESERVE_ADDRESS || '0x754876eeE86180C48771043b9fc9Ad885996b3dd';

const AGENT_SHARE_PCT   = 35;
const RESERVE_SHARE_PCT = 25; // 10% buyback + 10% risk + 5% ops

// ─── 参数 ─────────────────────────────────────────────
const args = process.argv.slice(2);
const getArg = (n) => { const i = args.indexOf(`--${n}`); return i >= 0 ? args[i+1] : null; };
const DRY_RUN      = args.includes('--dry-run');
const ROUND_ID     = parseInt(getArg('round-id') || '0');
const TOTAL_PROFIT = parseFloat(getArg('total-profit') || '0');

if (!ROUND_ID || !TOTAL_PROFIT) {
  console.error('用法: node distribute-bsc.mjs --round-id <N> --total-profit <USDC金额>');
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
const proxyAbi = parseAbi([
  'function proxy((uint8 callType, address to, uint256 value, bytes data)[] calls) payable returns (bytes[])',
]);

// ─── Agent 地址：从链上动态获取 ─────────────────────
const HIVE_ROUND = process.env.HIVE_ROUND_ADDRESS || '0xCA4b670D1a91E52a90A390836E1397929DbAcd02';
const roundAbi = parseAbi([
  'function getParticipants(uint256 roundId) view returns (address[])',
]);

// ─── 主流程 ──────────────────────────────────────────
const account = POLYMARKET_PK ? privateKeyToAccount(POLYMARKET_PK) : null;
const agentPool   = TOTAL_PROFIT * AGENT_SHARE_PCT / 100;
const reservePool = TOTAL_PROFIT * RESERVE_SHARE_PCT / 100;
const treasuryKeep = TOTAL_PROFIT * 40 / 100;

console.log('═══════════════════════════════════════════════════');
console.log('  蜂巢协议 — Polygon USDC.e 利润分发');
console.log('═══════════════════════════════════════════════════');
console.log(`  轮次 #${ROUND_ID}  |  总利润 $${TOTAL_PROFIT}`);
console.log(`  ├ Agent 35%  $${agentPool.toFixed(2)}`);
console.log(`  ├ 储备 25%   $${reservePool.toFixed(2)} → ${RESERVE_ADDR.slice(0,10)}...`);
console.log(`  └ 留存 40%   $${treasuryKeep.toFixed(2)} → 留在 Polymarket`);
console.log(`  EOA: ${account?.address || '(dry-run)'}`);
console.log(`  模式: ${DRY_RUN ? '模拟' : '实际转账'}`);
console.log('');

// Step 1: 从链上动态获取本轮参与者
console.log('[1] 读取 Axon 链上参与者数据...');

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
  console.log('  ⚠️  无法从链上获取参与者，回退查询所有活跃 Agent...');
  // 回退：扫描已知地址 + 动态发现
  const knownAddrs = (process.env.KNOWN_AGENTS || '').split(',').filter(Boolean);
  participants = knownAddrs.length > 0 ? knownAddrs : [];
}

const eligible = [];
for (const addr of participants) {
  try {
    const [active, scoreVal, stake] = await Promise.all([
      axon.readContract({ address: HIVE_AGENT, abi: agentAbi, functionName: 'isActive', args: [addr] }),
      axon.readContract({ address: HIVE_SCORE, abi: scoreAbi, functionName: 'getScore', args: [addr] }),
      axon.readContract({ address: HIVE_AGENT, abi: agentAbi, functionName: 'getStake', args: [addr] }),
    ]);

    const stakeNum = Number(formatUnits(stake, 18));
    const scoreNum = Number(scoreVal);
    const status = active ? '✅' : '⬚';
    const shortAddr = addr.slice(0, 10);

    console.log(`  ${status} ${shortAddr}...  Score=${scoreNum}  Stake=${stakeNum}`);

    if (active) {
      eligible.push({ name: shortAddr, addr, score: scoreNum, stake: stakeNum });
    }
  } catch { continue; }
}

if (eligible.length === 0) {
  console.log('\n⚠️  无活跃 Agent 参与本轮，跳过分发');
  process.exit(0);
}

// Step 2: 计算权重和分润
console.log(`\n[2] 按权重分润 (${eligible.length} 个 Agent)...`);

let totalWeight = 0;
for (const a of eligible) {
  a.weight = a.score * Math.sqrt(a.stake);
  totalWeight += a.weight;
}

for (const a of eligible) {
  a.share = totalWeight > 0 ? (a.weight / totalWeight) * agentPool : agentPool / eligible.length;
}

const maxNameLen = Math.max(...eligible.map(a => a.name.length));
for (const a of eligible) {
  const pct = (a.weight / totalWeight * 100).toFixed(1);
  console.log(`  ${a.name.padEnd(maxNameLen)}  权重=${a.weight.toFixed(1).padStart(8)}  占比=${pct.padStart(5)}%  → $${a.share.toFixed(4)}`);
}

// Step 3: 通过 ProxyWalletFactory 批量转账 (Polygon)
console.log(`\n[3] Polygon USDC.e 分发 (Agent 35% + 储备 25%)...`);

const totalTransferNeeded = agentPool + reservePool;

if (!DRY_RUN && account) {
  const polyWallet = createWalletClient({ account, chain: polygon, transport: http(POLYGON_RPC) });

  // 构造所有 ERC-20 transfer 调用
  const transferCalls = [];

  // Agent 转账
  for (const a of eligible) {
    if (a.share < 0.001) { console.log(`  [跳过] ${a.name} 金额太小`); continue; }
    const amount = parseUnits(a.share.toFixed(6), 6); // USDC.e 6 decimals
    const data = encodeFunctionData({ abi: erc20Abi, functionName: 'transfer', args: [a.addr, amount] });
    transferCalls.push({ callType: 1, to: USDC_E, value: 0n, data });
    console.log(`  Agent  ${a.name.padEnd(maxNameLen)} → ${a.addr.slice(0,10)}... $${a.share.toFixed(4)}`);
  }

  // 储备地址转账 (25%)
  const reserveAmount = parseUnits(reservePool.toFixed(6), 6);
  const reserveData = encodeFunctionData({ abi: erc20Abi, functionName: 'transfer', args: [RESERVE_ADDR, reserveAmount] });
  transferCalls.push({ callType: 1, to: USDC_E, value: 0n, data: reserveData });
  console.log(`  储备   25%        → ${RESERVE_ADDR.slice(0,10)}... $${reservePool.toFixed(4)}`);

  console.log(`\n  共 ${transferCalls.length} 笔转账, 总计 $${totalTransferNeeded.toFixed(2)} USDC.e`);

  try {
    const hash = await polyWallet.writeContract({
      address: FACTORY, abi: proxyAbi,
      functionName: 'proxy', args: [transferCalls],
      gas: 500000n,
    });
    console.log(`  ✅ 批量转账成功! tx: ${hash}`);

    const receipt = await polyPub.waitForTransactionReceipt({ hash, timeout: 60_000 })
      .catch(() => null);
    if (receipt) {
      console.log(`  区块: ${receipt.blockNumber}  状态: ${receipt.status}`);
    } else {
      console.log(`  ⏳ Receipt 超时，tx 已提交: ${hash}`);
    }
  } catch (e) {
    console.error(`  ❌ 转账失败: ${e.shortMessage || e.message}`);
    process.exit(1);
  }
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
