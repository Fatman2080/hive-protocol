"""
逆向策略 Agent — 与短期趋势反向操作

核心逻辑：
  均值回归假设：短期超涨/超跌后价格倾向于回归均值。
  - 计算 BTC 过去 1 小时相对于 VWAP 的偏离度
  - 偏离 > +0.3% → 预测 DOWN（超涨回调）
  - 偏离 < -0.3% → 预测 UP（超跌反弹）
  - 偏离在 ±0.3% 以内 → 低信心跟随趋势
"""

import httpx
from base_agent import make_agent
from hive_protocol import Prediction
from hive_protocol.types import PredictionResult, RoundInfo

agent = make_agent("AGENT_KEY_CONTRARIAN")

BINANCE_API = "https://api.binance.com/api/v3/klines"


def calc_vwap_deviation() -> float:
    """返回当前价相对 1h VWAP 的偏离百分比"""
    try:
        resp = httpx.get(BINANCE_API, params={
            "symbol": "BTCUSDT", "interval": "5m", "limit": 12,
        }, timeout=5)
        klines = resp.json()

        total_pv = 0.0
        total_vol = 0.0
        for k in klines:
            typical_price = (float(k[2]) + float(k[3]) + float(k[4])) / 3  # (H+L+C)/3
            volume = float(k[5])
            total_pv += typical_price * volume
            total_vol += volume

        if total_vol == 0:
            return 0.0

        vwap = total_pv / total_vol
        current_price = float(klines[-1][4])
        deviation_pct = (current_price - vwap) / vwap * 100

        return deviation_pct
    except Exception:
        return 0.0


@agent.on_new_round
def predict(info: RoundInfo) -> PredictionResult:
    dev = calc_vwap_deviation()

    if dev > 0.3:
        # 超涨 → 预测回调
        direction = Prediction.DOWN
        confidence = min(75, 35 + int(dev * 50))
    elif dev < -0.3:
        # 超跌 → 预测反弹
        direction = Prediction.UP
        confidence = min(75, 35 + int(abs(dev) * 50))
    else:
        # 中性区域 → 低信心跟随
        direction = Prediction.UP if dev > 0 else Prediction.DOWN
        confidence = 25

    return PredictionResult(direction=direction, confidence=confidence)


if __name__ == "__main__":
    agent.start()
