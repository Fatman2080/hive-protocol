"""LLM Agent — 使用大模型分析 BTC 走势"""

import os
import logging
from hive_protocol import HiveAgent, Prediction
from hive_protocol.types import PredictionResult, RoundInfo

logging.basicConfig(level=logging.INFO, format="%(asctime)s [%(name)s] %(message)s")

# LLM 客户端（用户自行替换为 OpenAI / Claude / 本地模型）
try:
    from openai import OpenAI
    llm = OpenAI(api_key=os.environ.get("OPENAI_API_KEY"))
except ImportError:
    llm = None

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

agent.register(stake_axon=100)

SYSTEM_PROMPT = """你是一个 BTC 短期价格分析师。你需要预测 BTC 在接下来 15 分钟会涨还是跌。

你必须严格按照以下 JSON 格式回答，不要多说一个字：
{"direction": "UP" 或 "DOWN", "confidence": 1-100 的整数}

confidence 代表你的信心：
- 30 以下: 基本是猜
- 30-50: 有一定根据
- 50-70: 比较有把握
- 70 以上: 非常有把握（注意：错了扣分更重）
"""


@agent.on_new_round
def predict(info: RoundInfo) -> PredictionResult:
    if llm is None:
        # 没有 LLM 就用随机策略
        import random
        return PredictionResult(
            direction=random.choice([Prediction.UP, Prediction.DOWN]),
            confidence=40,
        )

    prompt = (
        f"当前 BTC 价格: ${info.btc_price:,.2f}\n"
        f"金库余额: ${info.treasury_balance:,.2f}\n"
        f"本轮下注: ${info.bet_size:,.2f}\n"
        f"参与人数: {info.participant_count}\n"
        f"\n15 分钟后 BTC 会涨还是跌？"
    )

    try:
        response = llm.chat.completions.create(
            model="gpt-4o-mini",
            messages=[
                {"role": "system", "content": SYSTEM_PROMPT},
                {"role": "user", "content": prompt},
            ],
            temperature=0.3,
            max_tokens=50,
        )

        import json
        answer = json.loads(response.choices[0].message.content.strip())

        direction = Prediction.UP if answer["direction"] == "UP" else Prediction.DOWN
        confidence = max(1, min(70, int(answer["confidence"])))

        return PredictionResult(direction=direction, confidence=confidence)

    except Exception as e:
        logging.error(f"LLM error: {e}")
        return PredictionResult(direction=Prediction.UP, confidence=30)


if __name__ == "__main__":
    agent.start()
