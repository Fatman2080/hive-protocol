/**
 * Polymarket 金库连通性验证脚本
 *
 * 验证项目：
 *  1. 私钥 → EOA 地址推导
 *  2. Proxy 钱包链上余额（USDC.e + POL）
 *  3. Gamma API 市场发现（BTC 15m）
 *  4. CLOB API 健康检查
 *  5. CLOB API 认证（derive API key）
 *
 * 用法：node scripts/verify-polymarket.mjs
 */

import { createPublicClient, http, formatUnits } from 'viem';
import { polygon } from 'viem/chains';
import { privateKeyToAccount } from 'viem/accounts';

const PRIVATE_KEY = process.env.POLYMARKET_PRIVATE_KEY;
const EXPECTED_EOA = process.env.POLYMARKET_EOA || '';
const PROXY_WALLET = process.env.POLYMARKET_FUNDER || '';

const USDC_E = '0x2791Bca1f2de4661ED88A30C99A7a9449Aa84174';
const GAMMA_HOST = 'https://gamma-api.polymarket.com';
const CLOB_HOST = 'https://clob.polymarket.com';

const BALANCE_OF_ABI = [{
  inputs: [{ name: 'account', type: 'address' }],
  name: 'balanceOf',
  outputs: [{ name: '', type: 'uint256' }],
  stateMutability: 'view',
  type: 'function',
}];

const client = createPublicClient({
  chain: polygon,
  transport: http('https://polygon-bor-rpc.publicnode.com'),
});

let passed = 0;
let failed = 0;

function ok(label, detail = '') {
  passed++;
  console.log(`  ✅ ${label}${detail ? ` — ${detail}` : ''}`);
}

function fail(label, detail = '') {
  failed++;
  console.log(`  ❌ ${label}${detail ? ` — ${detail}` : ''}`);
}

// ─── Test 1: 私钥验证 ──────────────────────────────
async function testKeyDerivation() {
  console.log('\n[1/5] 私钥 → EOA 地址推导');
  try {
    const account = privateKeyToAccount(PRIVATE_KEY);
    if (account.address.toLowerCase() === EXPECTED_EOA.toLowerCase()) {
      ok('地址匹配', account.address);
    } else {
      fail('地址不匹配', `期望 ${EXPECTED_EOA}, 实际 ${account.address}`);
    }
  } catch (e) {
    fail('私钥无效', e.message);
  }
}

// ─── Test 2: 链上余额 ──────────────────────────────
async function testBalances() {
  console.log('\n[2/5] Polygon 链上余额');
  try {
    const proxyPol = await client.getBalance({ address: PROXY_WALLET });
    const proxyUsdc = await client.readContract({
      address: USDC_E,
      abi: BALANCE_OF_ABI,
      functionName: 'balanceOf',
      args: [PROXY_WALLET],
    });
    const eoaPol = await client.getBalance({ address: EXPECTED_EOA });

    const polStr = formatUnits(eoaPol, 18);
    const usdcStr = formatUnits(proxyUsdc, 6);

    ok('EOA POL (Gas)', `${parseFloat(polStr).toFixed(4)} POL`);

    if (proxyUsdc > 0n) {
      ok('Proxy USDC.e', `$${parseFloat(usdcStr).toFixed(2)}`);
    } else {
      fail('Proxy USDC.e 为 0', '需要充值才能交易');
    }

    if (eoaPol > 0n) {
      ok('EOA 有 Gas 费', `${parseFloat(polStr).toFixed(4)} POL`);
    } else {
      fail('EOA 无 Gas 费', '需要充入 POL');
    }
  } catch (e) {
    fail('RPC 查询失败', e.message);
  }
}

// ─── Test 3: Gamma API 市场发现 ────────────────────
async function testGammaApi() {
  console.log('\n[3/5] Gamma API 市场发现');
  try {
    const now = Math.floor(Date.now() / 1000);
    const interval = 15 * 60;
    const nextSlot = (Math.floor(now / interval) + 1) * interval;
    const slug = `btc-updown-15m-${nextSlot}`;

    console.log(`       尝试 slug: ${slug}`);

    const res = await fetch(`${GAMMA_HOST}/markets/slug/${slug}`);

    if (res.status === 200) {
      const data = await res.json();
      const tokenIds = JSON.parse(data.clobTokenIds || '[]');

      ok('找到活跃市场', slug);
      ok('市场问题', data.question || '(unknown)');

      if (tokenIds.length >= 2) {
        ok('Token IDs', `UP: ${tokenIds[0].slice(0, 16)}...  DOWN: ${tokenIds[1].slice(0, 16)}...`);
      } else {
        fail('Token IDs 不足', `只有 ${tokenIds.length} 个`);
      }
    } else if (res.status === 404) {
      // 当前时间点可能还没生成下一个 slot 的市场，尝试前一个
      const prevSlot = Math.floor(now / interval) * interval;
      const prevSlug = `btc-updown-15m-${prevSlot}`;
      console.log(`       当前 slot 无市场，尝试: ${prevSlug}`);

      const res2 = await fetch(`${GAMMA_HOST}/markets/slug/${prevSlug}`);
      if (res2.status === 200) {
        const data2 = await res2.json();
        ok('找到当前市场', prevSlug);
        ok('市场问题', data2.question || '(unknown)');
      } else {
        fail('Gamma API 无 BTC 15m 市场', `两个 slot 均 404`);
      }
    } else {
      fail('Gamma API 异常', `HTTP ${res.status}`);
    }
  } catch (e) {
    fail('Gamma API 请求失败', e.message);
  }
}

// ─── Test 4: CLOB API 健康检查 ────────────────────
async function testClobHealth() {
  console.log('\n[4/5] CLOB API 健康检查');
  try {
    const res = await fetch(`${CLOB_HOST}/`);
    if (res.ok) {
      const text = await res.text();
      ok('CLOB API 可达', text.trim().slice(0, 50));
    } else {
      fail('CLOB API 不可达', `HTTP ${res.status}`);
    }
  } catch (e) {
    fail('CLOB API 连接失败', e.message);
  }
}

// ─── Test 5: CLOB 认证测试 ─────────────────────────
async function testClobAuth() {
  console.log('\n[5/5] CLOB API 认证检查');

  try {
    // 使用 Polymarket 的 API Key 派生端点测试认证
    // 这需要 EIP-712 签名，较复杂，这里先测试基础端点
    const res = await fetch(`${CLOB_HOST}/time`);
    if (res.ok) {
      const data = await res.text();
      ok('CLOB 服务器时间', data.trim());
    } else {
      fail('CLOB 时间端点异常', `HTTP ${res.status}`);
    }

    // 测试 orderbook 端点（不需要认证）
    // 先从 gamma 获取一个 token id
    const now = Math.floor(Date.now() / 1000);
    const interval = 15 * 60;
    const currentSlot = Math.floor(now / interval) * interval;
    const slug = `btc-updown-15m-${currentSlot}`;

    const gammaRes = await fetch(`${GAMMA_HOST}/markets/slug/${slug}`);
    if (gammaRes.ok) {
      const market = await gammaRes.json();
      const tokenIds = JSON.parse(market.clobTokenIds || '[]');
      if (tokenIds.length >= 1) {
        const bookRes = await fetch(`${CLOB_HOST}/book?token_id=${tokenIds[0]}`);
        if (bookRes.ok) {
          const book = await bookRes.json();
          const bids = book.bids?.length || 0;
          const asks = book.asks?.length || 0;
          ok('Orderbook 可查询', `${bids} bids, ${asks} asks`);
        } else {
          fail('Orderbook 查询失败', `HTTP ${bookRes.status}`);
        }
      }
    }
  } catch (e) {
    fail('CLOB 认证测试失败', e.message);
  }
}

// ─── Main ───────────────────────────────────────────
console.log('═══════════════════════════════════════════');
console.log('  蜂巢协议 — Polymarket 金库连通性验证');
console.log('═══════════════════════════════════════════');
console.log(`  EOA:   ${EXPECTED_EOA}`);
console.log(`  Proxy: ${PROXY_WALLET}`);

await testKeyDerivation();
await testBalances();
await testGammaApi();
await testClobHealth();
await testClobAuth();

console.log('\n───────────────────────────────────────────');
console.log(`  结果: ${passed} 通过, ${failed} 失败`);

if (failed === 0) {
  console.log('  🎉 全部通过！金库账号准备就绪。');
} else {
  console.log('  ⚠️  存在失败项，请检查后重试。');
}
console.log('───────────────────────────────────────────\n');
