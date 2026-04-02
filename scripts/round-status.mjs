/**
 * 蜂巢协议 — 轮次状态查询 (v2 — 无质押模型)
 *
 * 两种模式：
 *   1. CLI 查询：node scripts/round-status.mjs
 *   2. HTTP 服务：node scripts/round-status.mjs --serve [--port 3210]
 *
 * API 端点:
 *   GET  /status     — 当前轮次完整状态
 *   GET  /phase      — 仅返回当前阶段
 *   GET  /next-slot  — 下一个 15 分钟窗口时间
 *   POST /onboard    — 自助准入（body: {"address":"0x..."}），自动调 register()
 */

import { createPublicClient, createWalletClient, http, parseAbi } from 'viem';
import { privateKeyToAccount } from 'viem/accounts';
import { readFileSync } from 'fs';
import { createServer } from 'http';

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

const RPC        = 'https://mainnet-rpc.axonchain.ai/';
const HIVE_ROUND = process.env.HIVE_ROUND_ADDRESS;
const HIVE_AGENT = process.env.HIVE_AGENT_ADDRESS;
const HIVE_SCORE = process.env.HIVE_SCORE_ADDRESS;

const args = process.argv.slice(2);
const SERVE = args.includes('--serve');
const PORT  = parseInt(args[args.indexOf('--port') + 1]) || 3210;

const PHASES = ['IDLE', 'COMMIT', 'REVEAL', 'SETTLED'];

const roundAbi = parseAbi([
  'function currentRoundId() view returns (uint256)',
  'function getRound(uint256) view returns ((uint8 phase, uint256 openPrice, uint256 closePrice, uint256 upWeight, uint256 downWeight, uint256 participantCount, uint256 betAmount, int256 profitLoss, uint256 startTime))',
  'function getParticipants(uint256) view returns (address[])',
]);

const agentAbi = parseAbi([
  'function isActive(address) view returns (bool)',
  'function activeAgentCount() view returns (uint256)',
  'function getStake(address) view returns (uint256)',
  'function getTier(address) view returns (uint8)',
  'function register()',
]);

const axon = createPublicClient({ chain: { id: 8210 }, transport: http(RPC) });

const TG_BOT_TOKEN = process.env.TG_BOT_TOKEN || '8310104753:AAHmuR64fDdAxzdnn6gcxmywhh5S9YkowP4';
const TG_CHAT_ID   = process.env.TG_CHAT_ID   || '-1003349791999';
const TG_THREAD_ID = process.env.TG_THREAD_ID || '9228';

async function tgNotify(text) {
  try {
    await fetch(`https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ chat_id: TG_CHAT_ID, message_thread_id: parseInt(TG_THREAD_ID), parse_mode: 'Markdown', text }),
    });
  } catch {}
}

async function onboardAgent(address) {
  if (!/^0x[0-9a-fA-F]{40}$/.test(address)) return { success: false, error: 'Invalid address format' };

  const isActive = await axon.readContract({ address: HIVE_AGENT, abi: agentAbi, functionName: 'isActive', args: [address] });
  if (isActive) {
    return { success: true, address, message: 'Already registered and active' };
  }

  const balance = await axon.getBalance({ address });
  const balanceAxon = Number(balance) / 1e18;

  if (balanceAxon < 100) {
    return {
      success: false, address,
      balance: balanceAxon.toFixed(2),
      error: `Insufficient AXON balance: ${balanceAxon.toFixed(2)} (need >= 100)`,
    };
  }

  const tiers = ['NONE', 'BRONZE', 'SILVER', 'GOLD', 'DIAMOND'];
  let tier = 'BRONZE';
  if (balanceAxon >= 5000) tier = 'DIAMOND';
  else if (balanceAxon >= 2000) tier = 'GOLD';
  else if (balanceAxon >= 500) tier = 'SILVER';

  await tgNotify(`🆕 *Agent 准入检查通过*\n地址: \`${address}\`\n余额: ${balanceAxon.toFixed(2)} AXON\n等级: ${tier}\n请自行调用 register() 完成注册`);

  return {
    success: true, address,
    balance: balanceAxon.toFixed(2),
    tier,
    nextSteps: [
      `call register() on HiveAgent (${HIVE_AGENT})`,
      `cast send ${HIVE_AGENT} "register()" --private-key <your_key> --rpc-url ${RPC} --gas-limit 200000 --legacy`,
    ],
  };
}

async function getStatus() {
  const roundId = await axon.readContract({
    address: HIVE_ROUND, abi: roundAbi,
    functionName: 'currentRoundId',
  });

  let round = null;
  let participants = [];
  if (roundId > 0n) {
    [round, participants] = await Promise.all([
      axon.readContract({ address: HIVE_ROUND, abi: roundAbi, functionName: 'getRound', args: [roundId] }),
      axon.readContract({ address: HIVE_ROUND, abi: roundAbi, functionName: 'getParticipants', args: [roundId] }),
    ]);
  }

  let totalAgents = 0;
  try {
    totalAgents = Number(await axon.readContract({ address: HIVE_AGENT, abi: agentAbi, functionName: 'activeAgentCount' }));
  } catch {}

  const now = Math.floor(Date.now() / 1000);
  const slotSize = 900;
  const currentSlotStart = Math.floor(now / slotSize) * slotSize;
  const nextSlotStart = currentSlotStart + slotSize;
  const nextCommitOpen = nextSlotStart + 60;

  return {
    currentRoundId: Number(roundId),
    phase: round ? PHASES[round.phase] : 'IDLE',
    phaseCode: round ? round.phase : 0,
    openPrice: round ? Number(round.openPrice) / 1e8 : null,
    closePrice: round ? Number(round.closePrice) / 1e8 : null,
    participantCount: participants.length,
    participants: participants.map(a => a),
    totalActiveAgents: totalAgents,
    upWeight: round ? Number(round.upWeight) : 0,
    downWeight: round ? Number(round.downWeight) : 0,
    profitLoss: round ? Number(round.profitLoss) / 1e6 : 0,
    startTime: round ? Number(round.startTime) : 0,
    timing: {
      now,
      currentSlotStart,
      nextSlotStart,
      nextCommitOpen,
      secondsUntilNextSlot: nextSlotStart - now,
      secondsUntilCommit: nextCommitOpen - now,
    },
    contracts: {
      hiveRound: HIVE_ROUND,
      hiveAgent: HIVE_AGENT,
      hiveScore: HIVE_SCORE,
      chainId: 8210,
      rpc: RPC,
    },
  };
}

if (!SERVE) {
  const status = await getStatus();
  console.log(JSON.stringify(status, null, 2));
  process.exit(0);
}

const server = createServer(async (req, res) => {
  res.setHeader('Content-Type', 'application/json');
  res.setHeader('Access-Control-Allow-Origin', '*');

  try {
    if (req.url === '/status' || req.url === '/') {
      const status = await getStatus();
      res.end(JSON.stringify(status, null, 2));
    } else if (req.url === '/phase') {
      const status = await getStatus();
      res.end(JSON.stringify({ phase: status.phase, roundId: status.currentRoundId }));
    } else if (req.url === '/next-slot') {
      const now = Math.floor(Date.now() / 1000);
      const next = (Math.floor(now / 900) + 1) * 900;
      res.end(JSON.stringify({
        nextSlotStart: next,
        nextSlotISO: new Date(next * 1000).toISOString(),
        secondsUntil: next - now,
      }));
    } else if (req.url === '/onboard' && req.method === 'POST') {
      let body = '';
      for await (const chunk of req) body += chunk;
      try {
        const { address } = JSON.parse(body);
        const result = await onboardAgent(address);
        res.statusCode = result.success ? 200 : 400;
        res.end(JSON.stringify(result, null, 2));
      } catch (e) {
        res.statusCode = 400;
        res.end(JSON.stringify({ error: 'Invalid JSON. Send: {"address":"0x..."}' }));
      }
    } else if (req.url === '/onboard' && req.method === 'GET') {
      res.end(JSON.stringify({
        endpoint: 'POST /onboard',
        usage: 'curl -X POST http://host:3210/onboard -H "Content-Type: application/json" -d \'{"address":"0x..."}\'',
        description: 'Check if agent meets balance requirement (>= 100 AXON). Agent then calls register() themselves.',
        requirements: 'AXON mainnet balance >= 100 AXON',
      }, null, 2));
    } else {
      res.statusCode = 404;
      res.end(JSON.stringify({ error: 'Not found. Use /status, /phase, /next-slot, or POST /onboard' }));
    }
  } catch (e) {
    res.statusCode = 500;
    res.end(JSON.stringify({ error: e.message }));
  }
});

server.listen(PORT, () => {
  console.log(`蜂巢协议 — 轮次状态 API (v2)`);
  console.log(`  GET  http://localhost:${PORT}/status`);
  console.log(`  GET  http://localhost:${PORT}/phase`);
  console.log(`  GET  http://localhost:${PORT}/next-slot`);
  console.log(`  POST http://localhost:${PORT}/onboard   ← 余额检查 + 准入引导`);
});
