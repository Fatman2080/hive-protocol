"""HiveAgent — Python SDK 核心类"""

import asyncio
import logging
import time
from typing import Callable, Optional

from .types import (
    AgentStats, Prediction, PredictionResult, RoundInfo,
    RoundPhase, RoundResult, Tier,
)
from .crypto import generate_salt, make_commit_hash
from .contract import HiveContracts

logger = logging.getLogger("hive_protocol")


class HiveAgent:
    """
    蜂巢协议 Python Agent SDK

    用法：
        agent = HiveAgent(
            rpc_url="https://mainnet-rpc.axonchain.ai/",
            private_key="0x...",
            contract_addresses={...},
        )
        agent.register(stake=100)

        @agent.on_new_round
        def predict(round_info: RoundInfo) -> PredictionResult:
            # 你的预测逻辑
            return PredictionResult(direction=Prediction.UP, confidence=70)

        agent.start()
    """

    def __init__(
        self,
        rpc_url: str,
        private_key: str,
        contract_addresses: dict,
        auto_claim: bool = True,
        claim_threshold_usdt: float = 10.0,
    ):
        self.contracts = HiveContracts(rpc_url, private_key, contract_addresses)
        self.address = self.contracts.account.address
        self.auto_claim = auto_claim
        self.claim_threshold = int(claim_threshold_usdt * 1e6)

        self._predict_fn: Optional[Callable[[RoundInfo], PredictionResult]] = None
        self._on_result_fn: Optional[Callable[[RoundResult], None]] = None
        self._running = False
        self._last_round_id = 0

    # ─── 装饰器 API ─────────────────────────────────────

    def on_new_round(self, fn: Callable[[RoundInfo], PredictionResult]):
        """注册预测回调（装饰器）"""
        self._predict_fn = fn
        return fn

    def on_round_result(self, fn: Callable[[RoundResult], None]):
        """注册结算结果回调（装饰器）"""
        self._on_result_fn = fn
        return fn

    # ─── 注册 ──────────────────────────────────────────

    def register(self, stake_axon: int = 100):
        """注册并质押 AXON Token"""
        if self.contracts.is_active(self.address):
            logger.info("Already registered, skipping")
            return

        stake_wei = stake_axon * 10**18
        logger.info(f"Registering with {stake_axon} AXON stake")
        receipt = self.contracts.register(stake_wei)
        logger.info(f"Registered! tx: {receipt.transactionHash.hex()}")

    # ─── 主循环 ─────────────────────────────────────────

    def start(self, poll_interval: float = 5.0):
        """启动 Agent 主循环（阻塞）"""
        if self._predict_fn is None:
            raise RuntimeError("No prediction function registered. Use @agent.on_new_round")

        self._running = True
        logger.info(f"Agent {self.address[:10]}... started, polling every {poll_interval}s")

        try:
            while self._running:
                try:
                    self._poll_round()
                except Exception as e:
                    logger.error(f"Round poll error: {e}", exc_info=True)
                time.sleep(poll_interval)
        except KeyboardInterrupt:
            logger.info("Agent stopped by user")
            self._running = False

    def stop(self):
        self._running = False

    def _poll_round(self):
        current_round = self.contracts.get_current_round_id()
        if current_round == 0 or current_round == self._last_round_id:
            return

        round_data = self.contracts.get_round(current_round)
        phase = round_data["phase"]

        if phase == RoundPhase.COMMIT:
            self._handle_commit(current_round, round_data)
        elif phase == RoundPhase.SETTLED and current_round != self._last_round_id:
            self._handle_settled(current_round, round_data)
            self._last_round_id = current_round

            if self.auto_claim:
                self._try_claim()

    def _handle_commit(self, round_id: int, round_data: dict):
        """COMMIT 阶段：调用用户的预测函数，提交预测"""
        # 检查是否已经 commit 过
        commit_info = self.contracts.round_contract.functions.getCommit(
            round_id, self.address
        ).call()
        if commit_info[0] != b'\x00' * 32:
            return  # 已 commit

        round_info = RoundInfo(
            round_id=round_id,
            btc_price=round_data["open_price"] / 1e8,
            open_price=round_data["open_price"] / 1e8,
            phase=RoundPhase.COMMIT,
            market_snapshot={},
            treasury_balance=self.contracts.get_treasury_balance() / 1e6,
            bet_size=round_data.get("bet_amount", 0) / 1e6,
            participant_count=round_data["participant_count"],
        )

        result = self._predict_fn(round_info)
        if not isinstance(result, PredictionResult):
            logger.error(f"Prediction function must return PredictionResult, got {type(result)}")
            return

        salt = generate_salt()
        commit_hash = make_commit_hash(result.direction, result.confidence, salt)

        logger.info(
            f"Round {round_id}: committing {result.direction.name} "
            f"confidence={result.confidence}"
        )
        self.contracts.commit(round_id, commit_hash)

        # 存储 salt 以便 reveal 阶段使用
        self._pending_reveal = {
            "round_id": round_id,
            "prediction": result.direction,
            "confidence": result.confidence,
            "salt": salt,
        }

    def _handle_settled(self, round_id: int, round_data: dict):
        """结算阶段：通知用户结果"""
        if self._on_result_fn is None:
            return

        result = RoundResult(
            round_id=round_id,
            actual_result=Prediction.UP if round_data["close_price"] > round_data["open_price"] else Prediction.DOWN,
            profit_loss=round_data["profit_loss"] / 1e6,
            new_hive_score=self.contracts.get_score(self.address),
        )

        try:
            self._on_result_fn(result)
        except Exception as e:
            logger.error(f"on_result callback error: {e}", exc_info=True)

    def _try_claim(self):
        """自动领取收益（超过阈值时）"""
        pending = self.contracts.get_pending_reward(self.address)
        if pending >= self.claim_threshold:
            logger.info(f"Claiming {pending / 1e6:.2f} USDT")
            self.contracts.claim()

    # ─── 查询 ──────────────────────────────────────────

    def get_stats(self) -> AgentStats:
        """查询自己的战绩"""
        score = self.contracts.get_score(self.address)
        # TODO: 补充完整统计
        return AgentStats(
            hive_score=score,
            total_rounds=0,
            correct_rounds=0,
            win_rate_bps=0,
            current_streak=0,
            best_streak=0,
            total_earned_usdt=0.0,
            tier=Tier.BRONZE,
        )
