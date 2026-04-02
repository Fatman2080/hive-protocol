/**
 * Axon 主网合约部署验证
 */

import { createPublicClient, http, formatUnits, parseAbi } from 'viem';

const RPC = 'https://mainnet-rpc.axonchain.ai/';
const client = createPublicClient({ transport: http(RPC) });

const CONTRACTS = {
  AXON_TOKEN:  '0x3728a6BCf4Bcc623222a47Aa95E070d907BC609a',
  USDT_TOKEN:  '0x86525Fc00D9b3AB321C0A88C6D0f6a22f0a67305',
  HIVE_ACCESS: '0xBDc600b64e0713A89e8Fd238BCA1bc6941355F3A',
  HIVE_SCORE:  '0xA98C35DD23e076f2BC696F3B83c39da058cb9f84',
  HIVE_AGENT:  '0x5c2416B46a5AE13BCD57C840262b660A77Bf224F',
  HIVE_VAULT:  '0x70eb759c9E2fEb1D5724b5F4A24F37940aB9b18d',
  HIVE_ROUND:  '0x81Fd46BB46745005e91eE4177Da0200180166D58',
  HIVE_REP_BRIDGE: '0xf556855352DF9F38B905357eeB75e044De4837cB',
  HIVE_RISK_CTRL: '0x606AD8a14d39C441C55E6b51F60cF2bE4a0B208B',
};

const AGENTS = [
  { name: 'Random',     addr: '0xC00df1E74fd818D8F538702C27FB9FEB8E6Be706' },
  { name: 'Momentum',   addr: '0xF77A0b21Fd53aD5777AcE3140F7F34469db36820' },
  { name: 'Sentiment',  addr: '0xba628c5F1aE3a29c1933ff8552Be48722F9e4efa' },
  { name: 'LLM',        addr: '0xFC7F55B8d9c0610DfB5C6dEDb6a813bb577FCD0D' },
  { name: 'Contrarian', addr: '0xAD70104cf2f7CB75aBac8d6DBC3cC30D29355352' },
];

const erc20Abi = parseAbi([
  'function symbol() view returns (string)',
  'function balanceOf(address) view returns (uint256)',
  'function decimals() view returns (uint8)',
]);

const vaultAbi = parseAbi([
  'function treasuryBalance() view returns (uint256)',
  'function reserveBalance() view returns (uint256)',
]);

const scoreAbi = parseAbi([
  'function getScore(address) view returns (uint256)',
]);

let passed = 0, failed = 0;
function ok(l, d='') { passed++; console.log(`  ✅ ${l}${d ? ' — ' + d : ''}`); }
function fail(l, d='') { failed++; console.log(`  ❌ ${l}${d ? ' — ' + d : ''}`); }

console.log('═══════════════════════════════════════════════');
console.log('  蜂巢协议 — Axon 主网部署验证');
console.log('  Chain ID: 8210');
console.log('═══════════════════════════════════════════════');

// 1. 检查合约代码存在
console.log('\n[1] 合约部署确认');
for (const [name, addr] of Object.entries(CONTRACTS)) {
  const code = await client.getCode({ address: addr });
  if (code && code !== '0x') {
    ok(name, addr.slice(0, 10) + '...');
  } else {
    fail(name, '无合约代码');
  }
}

// 2. Token 状态
console.log('\n[2] Token 状态');
const usdtSym = await client.readContract({ address: CONTRACTS.USDT_TOKEN, abi: erc20Abi, functionName: 'symbol' });
const axonSym = await client.readContract({ address: CONTRACTS.AXON_TOKEN, abi: erc20Abi, functionName: 'symbol' });
ok('USDT Symbol', usdtSym);
ok('AXON Symbol', axonSym);

// 3. 金库
console.log('\n[3] 金库状态');
const treasury = await client.readContract({ address: CONTRACTS.HIVE_VAULT, abi: vaultAbi, functionName: 'treasuryBalance' });
const tUsd = formatUnits(treasury, 6);
if (treasury > 0n) ok('金库余额', `$${parseFloat(tUsd).toLocaleString()} USDT`);
else fail('金库余额为 0');

// 4. Agent 余额
console.log('\n[4] Agent AXON ERC20 余额');
for (const a of AGENTS) {
  const bal = await client.readContract({ address: CONTRACTS.AXON_TOKEN, abi: erc20Abi, functionName: 'balanceOf', args: [a.addr] });
  const axonBal = formatUnits(bal, 18);
  if (bal > 0n) ok(a.name, `${parseFloat(axonBal)} AXON`);
  else fail(a.name, '0 AXON');
}

// 5. Agent AXON 原生余额 (Gas)
console.log('\n[5] Agent 原生 AXON (Gas)');
for (const a of AGENTS) {
  const bal = await client.getBalance({ address: a.addr });
  const axonBal = formatUnits(bal, 18);
  if (bal > 0n) ok(a.name, `${parseFloat(axonBal).toFixed(1)} AXON`);
  else fail(a.name, '无 Gas');
}

console.log('\n───────────────────────────────────────────────');
console.log(`  结果: ${passed} 通过, ${failed} 失败`);
if (failed === 0) console.log('  🎉 主网部署验证全部通过！');
else console.log('  ⚠️  存在失败项');
console.log('───────────────────────────────────────────────\n');
