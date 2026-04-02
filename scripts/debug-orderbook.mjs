import { ClobClient } from '@polymarket/clob-client';

const upId = process.argv[2] || '92417553627194809451173096132610260873358186056015927551668205125084550949152';
const downId = process.argv[3] || '23355131339265677397011808619054822857884770841656323138859280900002123936395';

const client = new ClobClient('https://clob.polymarket.com', 137);

for (const [label, id] of [['UP', upId], ['DOWN', downId]]) {
  const book = await client.getOrderBook(id);
  const asks = book.asks || [];
  const bids = book.bids || [];
  console.log(`\n=== ${label} Order Book (${asks.length} asks, ${bids.length} bids) ===`);
  console.log('ALL Asks:');
  asks.forEach(a => console.log(`  price=${a.price}  size=${a.size}`));
  if (!asks.length) console.log('  (空)');
  console.log('ALL Bids:');
  bids.forEach(b => console.log(`  price=${b.price}  size=${b.size}`));
  if (!bids.length) console.log('  (空)');
  
  const sortedAsks = [...asks].sort((a,b) => parseFloat(a.price) - parseFloat(b.price));
  console.log(`Best ask (cheapest): ${sortedAsks[0]?.price || 'N/A'}`);
  console.log(`Best bid (highest): ${bids[bids.length-1]?.price || bids[0]?.price || 'N/A'}`);
}
