"""
动量策略 Agent — 追随短期趋势

核心逻辑：
  - 获取 Binance BTC 1m/5m/15m K 线数据
  - 计算 EMA(5) 和 EMA(15) 交叉
  - EMA5 > EMA15 → UP，反之 → DOWN
  - 信心度 = min(70, 30 + |EMA差| / 价格 * 10000)
"""

import httpx
from base_agent import make_agent
from hive_protocol import Prediction
from hive_protocol.types import PredictionResult, RoundInfo

agent = make_agent("AGENT_KEY_MOMENTUM")

BINANCE_API = "https://api.binance.com/api/v3/klines"


def fetch_closes(symbol: str = "BTCUSDT", interval: str = "5m", limit: int = 20) -> list[float]:
    try:
        resp = httpx.get(BINANCE_API, params={
            "symbol": symbol, "interval": interval, "limit": limit,
        }, timeout=5)
        return [float(k[4]) for k in resp.json()]
    except Exception:
        return []


def ema(values: list[float], period: int) -> float:
    if not values:
        return 0.0
    multiplier = 2 / (period + 1)
    result = values[0]
    for v in values[1:]:
        result = (v - result) * multiplier + result
    return result


@agent.on_new_round
def predict(info: RoundInfo) -> PredictionResult:
    closes = fetch_closes(limit=20)
    if len(closes) < 15:
        return PredictionResult(direction=Prediction.UP, confidence=25)

    ema5 = ema(closes, 5)
    ema15 = ema(closes, 15)
    price = closes[-1]

    diff_bps = (ema5 - ema15) / price * 10000 if price > 0 else 0

    if diff_bps > 0:
        direction = Prediction.UP
    else:
        direction = Prediction.DOWN

    confidence = min(70, 30 + int(abs(diff_bps)))
    return PredictionResult(direction=direction, confidence=confidence)


if __name__ == "__main__":
    agent.start()
