"""
情绪分析 Agent — 基于 Polymarket 实时赔率做反向 / 跟随决策

核心逻辑：
  - 从 Polymarket Gamma API 获取当前 BTC 15m 市场的实时赔率
  - 如果 UP 概率 > 65% → 市场过度看涨 → 预测 DOWN（逆向）
  - 如果 DOWN 概率 > 65% → 市场过度看跌 → 预测 UP（逆向）
  - 中间区域 → 跟随多数（UP > 50% → UP）
  - 信心度 = 偏离 50% 的程度
"""

import json
import httpx
from base_agent import make_agent
from hive_protocol import Prediction
from hive_protocol.types import PredictionResult, RoundInfo

agent = make_agent("AGENT_KEY_SENTIMENT")

GAMMA_HOST = "https://gamma-api.polymarket.com"
CLOB_HOST = "https://clob.polymarket.com"


def get_btc_15m_midpoint() -> float | None:
    """获取当前 BTC 15m 市场 UP token 的中间价"""
    import time

    now = int(time.time())
    interval = 15 * 60
    current_slot = (now // interval) * interval
    slug = f"btc-updown-15m-{current_slot}"

    try:
        resp = httpx.get(f"{GAMMA_HOST}/markets/slug/{slug}", timeout=5)
        if resp.status_code != 200:
            return None

        market = resp.json()
        token_ids = json.loads(market.get("clobTokenIds", "[]"))
        if len(token_ids) < 1:
            return None

        book_resp = httpx.get(
            f"{CLOB_HOST}/midpoint", params={"token_id": token_ids[0]}, timeout=5
        )
        if book_resp.status_code == 200:
            data = book_resp.json()
            return float(data.get("mid", 0.5))
    except Exception:
        pass
    return None


@agent.on_new_round
def predict(info: RoundInfo) -> PredictionResult:
    up_prob = get_btc_15m_midpoint()
    if up_prob is None:
        return PredictionResult(direction=Prediction.UP, confidence=25)

    # 逆向阈值：市场过于一边倒时做反向
    if up_prob > 0.65:
        direction = Prediction.DOWN
        confidence = min(80, 40 + int((up_prob - 0.5) * 200))
    elif up_prob < 0.35:
        direction = Prediction.UP
        confidence = min(80, 40 + int((0.5 - up_prob) * 200))
    else:
        direction = Prediction.UP if up_prob >= 0.5 else Prediction.DOWN
        confidence = 30 + int(abs(up_prob - 0.5) * 100)

    return PredictionResult(direction=direction, confidence=confidence)


if __name__ == "__main__":
    agent.start()
