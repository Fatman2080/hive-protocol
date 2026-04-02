import { HiveAgent, Prediction, type PredictionResult, type RoundInfo } from "../src";

const agent = new HiveAgent({
  rpcUrl: process.env.RPC_URL || "https://mainnet-rpc.axonchain.ai/",
  privateKey: process.env.AGENT_PRIVATE_KEY as `0x${string}`,
  contractAddresses: {
    round: process.env.HIVE_ROUND_ADDRESS as `0x${string}`,
    agent: process.env.HIVE_AGENT_ADDRESS as `0x${string}`,
    vault: process.env.HIVE_VAULT_ADDRESS as `0x${string}`,
    score: process.env.HIVE_SCORE_ADDRESS as `0x${string}`,
  },
});

agent.onNewRound(async (round: RoundInfo): Promise<PredictionResult> => {
  // 简单动量策略
  const trend = (round.marketSnapshot["15m_trend"] as number) || 0;

  return {
    direction: trend > 0 ? Prediction.UP : Prediction.DOWN,
    confidence: Math.min(Math.abs(trend * 10000) + 30, 70),
  };
});

agent.onRoundResult(async (result) => {
  const icon = result.correct ? "✅" : "❌";
  console.log(
    `Round ${result.roundId}: ${icon} | PnL: ${result.profitLoss > 0 ? "+" : ""}$${result.profitLoss} | Score: ${result.newHiveScore}`
  );
});

async function main() {
  await agent.register();
  await agent.start();
}

main().catch(console.error);
