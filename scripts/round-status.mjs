/**
 * 蜂巢协议 — 轮次状态查询
 *
 * 提供两种模式：
 *   1. CLI 查询：node scripts/round-status.mjs
 *   2. HTTP 服务：node scripts/round-status.mjs --serve [--port 3210]
 *
 * 外部 Agent 可通过 HTTP 接口获取当前轮次信息，决定何时 commit/reveal。
 *
 * API 端点:
 *   GET /status          — 当前轮次完整状态
 *   GET /phase           — 仅返回当前阶段 ("COMMIT"/"REVEAL"/"SETTLED"/"IDLE")
 *   GET /next-slot       — 下一个 15 分钟窗口时间
 */

import { createPublicClient, http, parseAbi } from 'viem';
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
const HIVE_ROUND = process.env.HIVE_ROUND_ADDRESS || '0xCA4b670D1a91E52a90A390836E1397929DbAcd02';
const HIVE_AGENT = process.env.HIVE_AGENT_ADDRESS || '0x4222fE51db0b8e2c79460fF963Fe2B56B54Cbc45';
const HIVE_SCORE = process.env.HIVE_SCORE_ADDRESS || '0xc55EC85F2ee552F565f13f2dc9c77fd6B16F3b14';

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
]);

const axon = createPublicClient({ transport: http(RPC) });

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

// HTTP 服务模式
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
    } else {
      res.statusCode = 404;
      res.end(JSON.stringify({ error: 'Not found. Use /status, /phase, or /next-slot' }));
    }
  } catch (e) {
    res.statusCode = 500;
    res.end(JSON.stringify({ error: e.message }));
  }
});

server.listen(PORT, () => {
  console.log(`蜂巢协议 — 轮次状态 API`);
  console.log(`  http://localhost:${PORT}/status`);
  console.log(`  http://localhost:${PORT}/phase`);
  console.log(`  http://localhost:${PORT}/next-slot`);
});
