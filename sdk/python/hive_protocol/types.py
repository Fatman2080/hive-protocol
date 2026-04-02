from enum import IntEnum
from dataclasses import dataclass
from typing import Optional


class Prediction(IntEnum):
    UP = 0
    DOWN = 1


class RoundPhase(IntEnum):
    IDLE = 0
    COMMIT = 1
    REVEAL = 2
    SETTLED = 3


class Tier(IntEnum):
    NONE = 0
    BRONZE = 1
    SILVER = 2
    GOLD = 3
    DIAMOND = 4


@dataclass
class RoundInfo:
    """每轮行情快照，传给 Agent 的 predict 回调"""

    round_id: int
    btc_price: float
    open_price: float
    phase: RoundPhase
    market_snapshot: dict
    polymarket_odds: Optional[dict] = None
    treasury_balance: float = 0.0
    bet_size: float = 0.0
    participant_count: int = 0


@dataclass
class AgentStats:
    """Agent 的战绩统计"""

    hive_score: int
    total_rounds: int
    correct_rounds: int
    win_rate_bps: int
    current_streak: int
    best_streak: int
    total_earned_usdt: float
    tier: Tier


@dataclass
class PredictionResult:
    """Agent 返回的预测结果"""

    direction: Prediction
    confidence: int  # 1-100

    def __post_init__(self):
        if not 1 <= self.confidence <= 100:
            raise ValueError(f"confidence must be 1-100, got {self.confidence}")


@dataclass
class RoundResult:
    """一轮的结算结果"""

    round_id: int
    actual_result: Prediction
    profit_loss: float
    your_prediction: Optional[Prediction] = None
    your_reward: float = 0.0
    correct: Optional[bool] = None
    new_hive_score: int = 0
