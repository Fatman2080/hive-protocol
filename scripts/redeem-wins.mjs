/**
 * 蜂巢协议 — 批量赎回赢家条件代币
 *
 * 扫描过去 24 小时所有已解决的 BTC 15m 市场，
 * 赎回我们持有的赢家代币，释放 USDC.e 回 Proxy Wallet。
 *
 * 用法:
 *   node scripts/redeem-wins.mjs           # 扫描并赎回所有
 *   node scripts/redeem-wins.mjs --hours 6 # 只扫描最近 6 小时
 */

import { createPublicClient, createWalletClient, http, encodeFunctionData, parseAbi } from 'viem';
import { polygon } from 'viem/chains';
import { privateKeyToAccount } from 'viem/accounts';
import { readFileSync } from 'fs';

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

const POLYGON_RPC = 'https://polygon-bor-rpc.publicnode.com';
const CTF         = '0x4D97DCd97eC945f40cF65F87097ACe5EA0476045';
const USDC_E      = '0x2791Bca1f2de4661ED88A30C99A7a9449Aa84174';
const FACTORY     = '0xab45c5a4b0c941a2f231c04c3f49182e1a254052';
const PROXY       = process.env.POLYMARKET_FUNDER;
const GAMMA       = 'https://gamma-api.polymarket.com';
const PK          = process.env.POLYMARKET_PRIVATE_KEY;
const PARENT      = '0x0000000000000000000000000000000000000000000000000000000000000000';

const args = process.argv.slice(2);
const getArg = (n) => { const i = args.indexOf(`--${n}`); return i >= 0 ? args[i+1] : null; };
const HOURS = parseInt(getArg('hours') || '24');

const ctfAbi = parseAbi([
  'function redeemPositions(address collateralToken, bytes32 parentCollectionId, bytes32 conditionId, uint256[] indexSets)',
  'function balanceOf(address owner, uint256 id) view returns (uint256)',
  'function payoutDenominator(bytes32) view returns (uint256)',
  'function payoutNumerators(bytes32,uint256) view returns (uint256)',
]);

const erc20Abi = parseAbi(['function balanceOf(address) view returns (uint256)']);

const proxyAbi = parseAbi([
  'function proxy((uint8 callType, address to, uint256 value, bytes data)[] calls) payable returns (bytes[])',
]);

const account = privateKeyToAccount(PK);
const polyPub = createPublicClient({ chain: polygon, transport: http(POLYGON_RPC) });
const polyWallet = createWalletClient({ account, chain: polygon, transport: http(POLYGON_RPC) });

async function getMarketInfo(slug) {
  const resp = await fetch(`${GAMMA}/events?slug=${slug}`);
  const events = await resp.json();
  if (!events.length || !events[0].markets?.length) return null;
  const m = events[0].markets[0];
  if (!m.conditionId) return null;
  const ids = JSON.parse(m.clobTokenIds || '[]');
  return {
    slug, conditionId: m.conditionId,
    yesTokenId: ids[0] ? BigInt(ids[0]) : null,
    noTokenId: ids[1] ? BigInt(ids[1]) : null,
  };
}

async function main() {
  console.log(`蜂巢协议 — 批量赎回 (最近 ${HOURS}h)`);
  console.log(`Proxy: ${PROXY}\n`);

  const maticBal = await polyPub.getBalance({ address: account.address });
  const maticStr = (Number(maticBal) / 1e18).toFixed(4);
  console.log(`EOA MATIC: ${maticStr}`);
  if (maticBal < 5000000000000000n) { // < 0.005 MATIC
    console.log(`⚠️  MATIC 余额不足 (${maticStr})，无法支付 gas，跳过赎回`);
    return;
  }

  const balBefore = await polyPub.readContract({
    address: USDC_E, abi: erc20Abi,
    functionName: 'balanceOf', args: [PROXY],
  });
  console.log(`赎回前 USDC.e: $${(Number(balBefore) / 1e6).toFixed(2)}\n`);

  const now = Math.floor(Date.now() / 1000);
  const slotSize = 900;
  const totalSlots = Math.floor(HOURS * 4);
  let redeemed = 0;
  let skipped = 0;

  for (let i = 1; i <= totalSlots; i++) {
    const slot = (Math.floor(now / slotSize) - i) * slotSize;
    const slug = `btc-updown-15m-${slot}`;

    let info;
    try { info = await getMarketInfo(slug); } catch { continue; }
    if (!info || !info.yesTokenId || !info.noTokenId) continue;

    let yesBal, noBal;
    try {
      [yesBal, noBal] = await Promise.all([
        polyPub.readContract({ address: CTF, abi: ctfAbi, functionName: 'balanceOf', args: [PROXY, info.yesTokenId] }),
        polyPub.readContract({ address: CTF, abi: ctfAbi, functionName: 'balanceOf', args: [PROXY, info.noTokenId] }),
      ]);
    } catch { continue; }

    if (yesBal === 0n && noBal === 0n) continue;

    // 检查是否已解决
    let denom;
    try {
      denom = await polyPub.readContract({ address: CTF, abi: ctfAbi, functionName: 'payoutDenominator', args: [info.conditionId] });
    } catch { continue; }

    if (denom === 0n) {
      console.log(`  ⏳ ${slug} — 未解决，跳过`);
      skipped++;
      continue;
    }

    const label = `${slug.slice(-10)} YES:${(Number(yesBal)/1e6).toFixed(2)} NO:${(Number(noBal)/1e6).toFixed(2)}`;

    // 赎回
    const redeemData = encodeFunctionData({
      abi: ctfAbi,
      functionName: 'redeemPositions',
      args: [USDC_E, PARENT, info.conditionId, [1n, 2n]],
    });

    try {
      const bBefore = await polyPub.readContract({ address: USDC_E, abi: erc20Abi, functionName: 'balanceOf', args: [PROXY] });

      const callArgs = {
        address: FACTORY, abi: proxyAbi,
        functionName: 'proxy',
        args: [[{ callType: 1, to: CTF, value: 0n, data: redeemData }]],
      };

      let gasEst;
      try {
        gasEst = await polyPub.estimateContractGas({ ...callArgs, account: account.address });
        gasEst = gasEst * 130n / 100n; // +30% buffer
      } catch (ge) {
        console.log(`  ⚠️  ${label} → gas估算失败: ${(ge.shortMessage || ge.message || '').slice(0, 80)}`);
        continue;
      }

      const hash = await polyWallet.writeContract({ ...callArgs, gas: gasEst });
      const receipt = await polyPub.waitForTransactionReceipt({ hash, timeout: 60000 });

      const bAfter = await polyPub.readContract({ address: USDC_E, abi: erc20Abi, functionName: 'balanceOf', args: [PROXY] });
      const gained = (Number(bAfter) - Number(bBefore)) / 1e6;

      if (receipt.status === 'success') {
        console.log(`  ✅ ${label} → +$${gained.toFixed(4)}  tx:${hash.slice(0, 20)}...`);
        redeemed++;
      } else {
        console.log(`  ❌ ${label} → reverted`);
      }
    } catch (e) {
      console.log(`  ⚠️  ${label} → ${(e.shortMessage || e.message || '').slice(0, 80)}`);
    }

    await new Promise(r => setTimeout(r, 500));
  }

  const balAfter = await polyPub.readContract({
    address: USDC_E, abi: erc20Abi,
    functionName: 'balanceOf', args: [PROXY],
  });

  console.log(`\n═══ 赎回完成 ═══`);
  console.log(`  成功: ${redeemed}  跳过: ${skipped}`);
  console.log(`  赎回前: $${(Number(balBefore) / 1e6).toFixed(2)}`);
  console.log(`  赎回后: $${(Number(balAfter) / 1e6).toFixed(2)}`);
  console.log(`  净释放: +$${((Number(balAfter) - Number(balBefore)) / 1e6).toFixed(4)} USDC.e`);
}

main().catch(e => {
  console.error('Fatal:', e.message);
  process.exit(1);
});
