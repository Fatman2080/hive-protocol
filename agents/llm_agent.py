"""
LLM 分析 Agent — 调用大语言模型分析 BTC 走势

核心逻辑：
  1. 获取最近 20 根 5m K 线（开高低收量）
  2. 获取当前 Polymarket 赔率
  3. 将数据组装成 prompt 给 GPT-4o-mini / DeepSeek
  4. 解析 LLM 返回的 UP/DOWN + 信心度
"""

import os
import json
import httpx
from base_agent import make_agent
from hive_protocol import Prediction
from hive_protocol.types import PredictionResult, RoundInfo

agent = make_agent("AGENT_KEY_LLM")

OPENAI_KEY = os.environ.get("OPENAI_API_KEY", "")
OPENAI_MODEL = os.environ.get("LLM_MODEL", "gpt-4o-mini")
OPENAI_URL = os.environ.get("LLM_BASE_URL", "https://api.openai.com/v1/chat/completions")

BINANCE_API = "https://api.binance.com/api/v3/klines"


def fetch_klines() -> str:
    try:
        resp = httpx.get(BINANCE_API, params={
            "symbol": "BTCUSDT", "interval": "5m", "limit": 20,
        }, timeout=5)
        klines = resp.json()
        lines = []
        for k in klines[-10:]:
            o, h, l, c, v = float(k[1]), float(k[2]), float(k[3]), float(k[4]), float(k[5])
            lines.append(f"  O={o:.1f} H={h:.1f} L={l:.1f} C={c:.1f} Vol={v:.0f}")
        return "\n".join(lines)
    except Exception:
        return "(unavailable)"


def ask_llm(kline_data: str, btc_price: float) -> tuple[Prediction, int]:
    prompt = f"""You are a BTC short-term trader. Based on the following data, predict whether BTC price will go UP or DOWN in the next 15 minutes.

Current BTC price: ${btc_price:,.2f}

Recent 5-minute candles (latest 10):
{kline_data}

Respond in EXACTLY this JSON format, nothing else:
{{"direction": "UP" or "DOWN", "confidence": 1-100, "reason": "brief reason"}}"""

    try:
        resp = httpx.post(
            OPENAI_URL,
            headers={
                "Authorization": f"Bearer {OPENAI_KEY}",
                "Content-Type": "application/json",
            },
            json={
                "model": OPENAI_MODEL,
                "messages": [{"role": "user", "content": prompt}],
                "temperature": 0.3,
                "max_tokens": 150,
            },
            timeout=15,
        )
        data = resp.json()
        content = data["choices"][0]["message"]["content"]

        # 解析 JSON
        result = json.loads(content.strip().strip("```json").strip("```").strip())
        direction = Prediction.UP if result["direction"].upper() == "UP" else Prediction.DOWN
        confidence = max(1, min(100, int(result["confidence"])))
        reason = result.get("reason", "")

        print(f"  [LLM] {OPENAI_MODEL}: {result['direction']} conf={confidence} — {reason}")
        return direction, confidence

    except Exception as e:
        print(f"  [LLM] Error: {e}, falling back to UP/50")
        return Prediction.UP, 50


@agent.on_new_round
def predict(info: RoundInfo) -> PredictionResult:
    if not OPENAI_KEY:
        print("  [LLM] No API key, using random fallback")
        import random
        return PredictionResult(
            direction=random.choice([Prediction.UP, Prediction.DOWN]),
            confidence=40,
        )

    kline_data = fetch_klines()
    direction, confidence = ask_llm(kline_data, info.btc_price)
    return PredictionResult(direction=direction, confidence=confidence)


if __name__ == "__main__":
    agent.start()
