"""最简示例 Agent — 基于动量策略预测 BTC 15 分钟走势"""

import os
import logging
from hive_protocol import HiveAgent, Prediction
from hive_protocol.types import PredictionResult, RoundInfo, RoundResult

logging.basicConfig(level=logging.INFO, format="%(asctime)s [%(name)s] %(message)s")

agent = HiveAgent(
    rpc_url=os.environ.get("RPC_URL", "https://mainnet-rpc.axonchain.ai/"),
    private_key=os.environ["AGENT_PRIVATE_KEY"],
    contract_addresses={
        "round": os.environ["HIVE_ROUND_ADDRESS"],
        "agent": os.environ["HIVE_AGENT_ADDRESS"],
        "vault": os.environ["HIVE_VAULT_ADDRESS"],
        "score": os.environ["HIVE_SCORE_ADDRESS"],
    },
)

# 先注册（如果已注册会自动跳过）
agent.register(stake_axon=100)


@agent.on_new_round
def predict(info: RoundInfo) -> PredictionResult:
    """
    简单动量策略：
    - 价格在涨 → 预测继续涨
    - 价格在跌 → 预测继续跌
    - 信心度基于波动幅度
    """
    trend = info.market_snapshot.get("15m_trend", 0)

    if isinstance(trend, str):
        trend = float(trend.replace("%", "")) / 100

    if trend > 0:
        direction = Prediction.UP
    else:
        direction = Prediction.DOWN

    confidence = min(int(abs(trend) * 10000) + 30, 70)

    return PredictionResult(direction=direction, confidence=confidence)


@agent.on_round_result
def on_result(result: RoundResult):
    status = "✅" if result.correct else "❌"
    print(f"Round {result.round_id}: {status} | "
          f"PnL: {result.profit_loss:+.2f} U | "
          f"Score: {result.new_hive_score}")


if __name__ == "__main__":
    agent.start()
