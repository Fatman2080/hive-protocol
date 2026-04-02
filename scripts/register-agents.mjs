/**
 * 蜂巢协议 — 注册 5 个 Agent 到 Axon 主网
 *
 * 流程: approve AXON → register(stakeAmount, selfAddress)
 * 当前部署的合约仍含 bscAddress 参数，传入自身地址即可
 * （EVM 地址通用：Axon 地址 = BSC 地址）
 *
 * 用法: node scripts/register-agents.mjs [--dry-run]
 */

import { createPublicClient, createWalletClient, http, parseUnits, formatUnits, parseAbi } from 'viem';
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

// ─── 配置 ─────────────────────────────────────────────
const AXON_RPC = process.env.RPC_URL || 'https://mainnet-rpc.axonchain.ai/';
const DRY_RUN  = process.argv.includes('--dry-run');
const STAKE_AMOUNT = parseUnits('200', 18); // 200 AXON

const axonChain = {
  id: 8210,
  name: 'Axon Mainnet',
  nativeCurrency: { name: 'AXON', symbol: 'AXON', decimals: 18 },
  rpcUrls: { default: { http: [AXON_RPC] } },
};

const AXON_TOKEN    = process.env.AXON_TOKEN;
const HIVE_AGENT    = process.env.HIVE_AGENT_ADDRESS;

const erc20Abi = parseAbi([
  'function approve(address,uint256) returns (bool)',
  'function balanceOf(address) view returns (uint256)',
  'function allowance(address,address) view returns (uint256)',
]);

// 旧版合约 ABI（含 bscAddress 参数）
const agentAbi = parseAbi([
  'function register(uint256,address)',
  'function isActive(address) view returns (bool)',
  'function getStake(address) view returns (uint256)',
  'function getTier(address) view returns (uint8)',
]);

const AGENTS = [
  { name: 'Random',     key: process.env.AGENT_KEY_RANDOM },
  { name: 'Momentum',   key: process.env.AGENT_KEY_MOMENTUM },
  { name: 'Sentiment',  key: process.env.AGENT_KEY_SENTIMENT },
  { name: 'LLM',        key: process.env.AGENT_KEY_LLM },
  { name: 'Contrarian', key: process.env.AGENT_KEY_CONTRARIAN },
];

// ─── 客户端 ──────────────────────────────────────────
const pub = createPublicClient({ chain: axonChain, transport: http(AXON_RPC) });

console.log('═══════════════════════════════════════════════════');
console.log('  蜂巢协议 — Axon 主网 Agent 注册');
console.log('═══════════════════════════════════════════════════');
console.log(`  AXON Token: ${AXON_TOKEN}`);
console.log(`  HiveAgent:  ${HIVE_AGENT}`);
console.log(`  质押量:     200 AXON / Agent`);
console.log(`  模式:       ${DRY_RUN ? '🔍 模拟' : '💰 实际注册'}`);
console.log('');

for (const agent of AGENTS) {
  const account = privateKeyToAccount(agent.key);
  agent.addr = account.address;

  // 检查是否已注册
  const alreadyActive = await pub.readContract({
    address: HIVE_AGENT, abi: agentAbi,
    functionName: 'isActive', args: [agent.addr],
  });

  if (alreadyActive) {
    const stake = await pub.readContract({
      address: HIVE_AGENT, abi: agentAbi,
      functionName: 'getStake', args: [agent.addr],
    });
    console.log(`  ✅ ${agent.name.padEnd(11)} ${agent.addr}  已注册 (stake=${formatUnits(stake, 18)} AXON)`);
    continue;
  }

  // 检查 AXON 余额
  const bal = await pub.readContract({
    address: AXON_TOKEN, abi: erc20Abi,
    functionName: 'balanceOf', args: [agent.addr],
  });
  const balStr = formatUnits(bal, 18);

  if (bal < STAKE_AMOUNT) {
    console.log(`  ❌ ${agent.name.padEnd(11)} ${agent.addr}  AXON 余额不足: ${balStr}`);
    continue;
  }

  if (DRY_RUN) {
    console.log(`  [模拟] ${agent.name.padEnd(11)} ${agent.addr}  余额=${balStr} AXON → 将注册 200 AXON`);
    continue;
  }

  // 实际注册
  const wallet = createWalletClient({ account, chain: axonChain, transport: http(AXON_RPC) });

  try {
    // Step 1: approve
    const approveTx = await wallet.writeContract({
      address: AXON_TOKEN, abi: erc20Abi,
      functionName: 'approve', args: [HIVE_AGENT, STAKE_AMOUNT],
    });
    console.log(`  ⏳ ${agent.name.padEnd(11)} approve tx: ${approveTx.slice(0, 14)}...`);
    await pub.waitForTransactionReceipt({ hash: approveTx });

    // Step 2: register(stakeAmount, selfAddress)
    // 传入自身地址作为 bscAddress（Axon 地址 = BSC 地址）
    // Axon 链 gas 估算有兼容问题，手动指定全部 gas 参数
    const regTx = await wallet.writeContract({
      address: HIVE_AGENT, abi: agentAbi,
      functionName: 'register', args: [STAKE_AMOUNT, agent.addr],
      gas: 500_000n,
      gasPrice: 1_200_000_000n,
    });
    console.log(`  ⏳ ${agent.name.padEnd(11)} register tx: ${regTx.slice(0, 14)}...`);
    await pub.waitForTransactionReceipt({ hash: regTx });

    // 验证
    const active = await pub.readContract({
      address: HIVE_AGENT, abi: agentAbi,
      functionName: 'isActive', args: [agent.addr],
    });
    const tier = await pub.readContract({
      address: HIVE_AGENT, abi: agentAbi,
      functionName: 'getTier', args: [agent.addr],
    });
    const tierNames = ['NONE', 'BRONZE', 'SILVER', 'GOLD', 'PLATINUM'];

    console.log(`  ✅ ${agent.name.padEnd(11)} ${agent.addr}  注册成功! Tier=${tierNames[tier] || tier}  Active=${active}`);
  } catch (e) {
    console.log(`  ❌ ${agent.name.padEnd(11)} 注册失败: ${e.shortMessage || e.message}`);
  }
}

console.log('\n─── 注册完成 ────────────────────────────────────');
console.log('  下一步: 启动 Rust 引擎 → cargo run --release');
console.log('─────────────────────────────────────────────────\n');
