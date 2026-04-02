/**
 * 蜂巢协议 — Polymarket BTC 15 分钟实盘交易
 *
 * 用法:
 *   node scripts/polymarket-trade.mjs --direction UP   --amount 5
 *   node scripts/polymarket-trade.mjs --direction DOWN --amount 10
 *   node scripts/polymarket-trade.mjs --check-balance
 *   node scripts/polymarket-trade.mjs --find-market
 *
 * stdout 只输出 JSON，stderr 输出日志。
 * 返回 JSON: { success, orderId, direction, amount, market, tokenId, price, txHash }
 */

import { ClobClient } from '@polymarket/clob-client';
import { ethers } from 'ethers';
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

const HOST     = 'https://clob.polymarket.com';
const GAMMA    = 'https://gamma-api.polymarket.com';
const CHAIN    = 137;
const PK       = process.env.POLYMARKET_PRIVATE_KEY;
const FUNDER   = process.env.POLYMARKET_FUNDER;
const SIG_TYPE = parseInt(process.env.POLYMARKET_SIGNATURE_TYPE || '1');

const args = process.argv.slice(2);
const getArg = (n) => { const i = args.indexOf(`--${n}`); return i >= 0 ? args[i+1] : null; };
const CHECK_BALANCE = args.includes('--check-balance');
const FIND_MARKET   = args.includes('--find-market');
const DIRECTION     = (getArg('direction') || '').toUpperCase();
const AMOUNT        = parseFloat(getArg('amount') || '5');
const MAX_PRICE     = parseFloat(getArg('max-price') || '0.65');

const wallet = new ethers.Wallet(PK);

async function getAuthClient() {
  const tempClient = new ClobClient(HOST, CHAIN, wallet, undefined, SIG_TYPE, FUNDER);
  let creds;
  try {
    creds = await tempClient.deriveApiKey();
  } catch {
    creds = await tempClient.createApiKey();
  }
  return new ClobClient(HOST, CHAIN, wallet, creds, SIG_TYPE, FUNDER);
}

// ─── 发现最佳 BTC 15m 市场 ──────────────────────────
async function findBestMarket() {
  const now = Math.floor(Date.now() / 1000);
  const slotSize = 900;

  for (let offset = 0; offset <= 2; offset++) {
    const slot = (Math.floor(now / slotSize) + offset) * slotSize;
    const slug = `btc-updown-15m-${slot}`;

    const resp = await fetch(`${GAMMA}/events?slug=${slug}`);
    const events = await resp.json();
    if (!events.length) continue;

    const market = events[0].markets[0];
    if (!market.active || market.closed) continue;

    const ids = JSON.parse(market.clobTokenIds || '[]');
    const prices = JSON.parse(market.outcomePrices || '[]');

    return {
      slug,
      question: market.question,
      conditionId: market.conditionId,
      upTokenId: ids[0],
      downTokenId: ids[1],
      upPrice: parseFloat(prices[0]),
      downPrice: parseFloat(prices[1]),
      active: market.active,
      accepting: market.acceptingOrders,
      minSize: market.orderMinSize,
    };
  }
  return null;
}

// ─── 查找 order book 中可成交的最佳价格 ─────────────
async function findFillablePrice(client, tokenId, side, targetAmount) {
  const book = await client.getOrderBook(tokenId);
  const levels = side === 'BUY' ? (book.asks || []) : (book.bids || []);
  const validLevels = levels
    .filter(l => { const p = parseFloat(l.price); return p >= 0.01 && p <= 0.99; })
    .sort((a, b) => {
      const pa = parseFloat(a.price), pb = parseFloat(b.price);
      return side === 'BUY' ? pa - pb : pb - pa;
    });

  if (!validLevels.length) return null;

  let accumulated = 0;
  let worstPrice = null;
  for (const level of validLevels) {
    const p = parseFloat(level.price);
    const s = parseFloat(level.size);
    accumulated += s * p;
    worstPrice = p;
    if (accumulated >= targetAmount) break;
  }

  return worstPrice;
}

// ─── 主流程 ──────────────────────────────────────────
async function main() {
  if (FIND_MARKET) {
    const market = await findBestMarket();
    if (!market) {
      console.log(JSON.stringify({ error: 'No active BTC 15m market found' }));
      process.exit(1);
    }
    console.log(JSON.stringify(market, null, 2));
    return;
  }

  const client = await getAuthClient();

  if (CHECK_BALANCE) {
    try {
      const bal = await client.getBalanceAllowance({ asset_type: 'COLLATERAL', signature_type: SIG_TYPE });
      console.log(JSON.stringify({ balance_usdc: parseInt(bal.balance) / 1e6 }));
    } catch(e) {
      console.log(JSON.stringify({ error: e.message }));
    }
    return;
  }

  if (!DIRECTION || !['UP', 'DOWN'].includes(DIRECTION)) {
    console.error('用法: node polymarket-trade.mjs --direction UP|DOWN --amount <USDC>');
    process.exit(1);
  }

  const market = await findBestMarket();
  if (!market) {
    console.log(JSON.stringify({ success: false, error: 'No active BTC 15m market' }));
    process.exit(1);
  }

  const tokenId = DIRECTION === 'UP' ? market.upTokenId : market.downTokenId;
  const gammaPrice = DIRECTION === 'UP' ? market.upPrice : market.downPrice;

  console.error(`Market: ${market.question}`);
  console.error(`Direction: ${DIRECTION}, Amount: $${AMOUNT}, Gamma price: ${gammaPrice}`);

  const fillPrice = await findFillablePrice(client, tokenId, 'BUY', AMOUNT);
  if (!fillPrice) {
    console.log(JSON.stringify({ success: false, error: 'No fillable price in order book' }));
    process.exit(1);
  }

  if (fillPrice > MAX_PRICE) {
    console.error(`Fill price ${fillPrice} > max ${MAX_PRICE}, skipping (unfavorable odds)`);
    console.log(JSON.stringify({
      success: false, error: `price_too_high`,
      fillPrice, maxPrice: MAX_PRICE,
      direction: DIRECTION, market: market.slug,
    }));
    process.exit(1);
  }

  const shares = Math.max(Math.floor(AMOUNT / fillPrice), 1);
  console.error(`Fill price: ${fillPrice}, Shares: ${shares}`);

  try {
    const order = await client.createOrder({
      tokenID: tokenId,
      price: fillPrice,
      side: 'BUY',
      size: shares,
      feeRateBps: 1000,
    }, { tickSize: '0.01' });

    const resp = await client.postOrder(order, 'FOK');
    console.error('CLOB response:', JSON.stringify(resp).slice(0, 300));

    const errText = resp.errorMsg || resp.error || '';
    const result = {
      success: resp.success || false,
      orderId: resp.orderID,
      status: resp.status,
      direction: DIRECTION,
      amount: AMOUNT,
      fillPrice,
      shares,
      market: market.slug,
      question: market.question,
      tokenId: tokenId.slice(0, 30) + '...',
      makingAmount: resp.makingAmount,
      takingAmount: resp.takingAmount,
      txHash: resp.transactionsHashes?.[0] || null,
      error: errText || (resp.success ? '' : 'order_rejected'),
      errorMsg: errText,
    };

    console.log(JSON.stringify(result, null, 2));
    if (!resp.success) process.exit(1);
  } catch(e) {
    console.error('Order error:', e.message?.slice(0, 500));
    console.log(JSON.stringify({
      success: false,
      error: e.message?.slice(0, 300),
      direction: DIRECTION,
      amount: AMOUNT,
      market: market.slug,
    }, null, 2));
    process.exit(1);
  }
}

main().catch(e => {
  console.error('Fatal:', e.message);
  process.exit(1);
});
