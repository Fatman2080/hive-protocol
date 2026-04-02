"""
随机基线 Agent — 等概率随机选择 UP/DOWN

作为控制组基线，理论胜率 ≈ 50%。
如果蜂群整体表现低于此基线，说明策略有问题。
"""

import random
from base_agent import make_agent
from hive_protocol import Prediction
from hive_protocol.types import PredictionResult, RoundInfo, RoundResult

agent = make_agent("AGENT_KEY_RANDOM")


@agent.on_new_round
def predict(info: RoundInfo) -> PredictionResult:
    direction = random.choice([Prediction.UP, Prediction.DOWN])
    confidence = random.randint(20, 60)
    return PredictionResult(direction=direction, confidence=confidence)


@agent.on_round_result
def on_result(result: RoundResult):
    s = "✅" if result.correct else "❌"
    print(f"[Random] #{result.round_id} {s} PnL={result.profit_loss:+.2f} Score={result.new_hive_score}")


if __name__ == "__main__":
    agent.start()
