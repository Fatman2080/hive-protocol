use anyhow::Result;
use std::sync::Arc;
use tokio::sync::RwLock;

use crate::chain::ChainClient;
use crate::config::SchedulerConfig;
use crate::execution::Executor;
use crate::market::MarketFeed;
use crate::risk::RiskManager;
use crate::settlement::{SettlementTracker, BetRecord, BetStatus};

#[derive(Debug, Clone, Copy, PartialEq)]
pub enum RoundPhase {
    WaitingForStart,
    Commit,
    Reveal,
    Betting,
    WaitingForSettlement,
}

struct RoundState {
    phase: RoundPhase,
    round_id: u64,
    open_price: f64,
    consecutive_losses: u32,
    paused_rounds_remaining: u32,
}

#[derive(Clone)]
pub struct RoundManager {
    chain: ChainClient,
    market: MarketFeed,
    executor: Arc<dyn Executor>,
    risk: RiskManager,
    config: SchedulerConfig,
    state: Arc<RwLock<RoundState>>,
    settlement: Arc<SettlementTracker>,
}

impl RoundManager {
    pub fn new(
        chain: ChainClient,
        market: MarketFeed,
        executor: Arc<dyn Executor>,
        risk: RiskManager,
        config: SchedulerConfig,
    ) -> Self {
        Self {
            chain,
            market,
            executor,
            risk,
            config,
            state: Arc::new(RwLock::new(RoundState {
                phase: RoundPhase::WaitingForStart,
                round_id: 0,
                open_price: 0.0,
                consecutive_losses: 0,
                paused_rounds_remaining: 0,
            })),
            settlement: Arc::new(SettlementTracker::new()),
        }
    }

    /// 主循环：持续运行轮次调度
    pub async fn run(&self) -> Result<()> {
        tracing::info!(
            round_duration = ?self.config.round_duration,
            "Round scheduler started"
        );

        loop {
            if let Err(e) = self.run_one_round().await {
                tracing::error!(?e, "Round execution failed");
                metrics::counter!("rounds_failed").increment(1);
            }

            // 轮次间间隔（等待到下一个 15 分钟对齐点）
            self.wait_for_next_slot().await;
        }
    }

    async fn run_one_round(&self) -> Result<()> {
        let mut state = self.state.write().await;

        // 熔断检查
        if state.paused_rounds_remaining > 0 {
            tracing::warn!(remaining = state.paused_rounds_remaining, "Round paused (circuit breaker)");
            state.paused_rounds_remaining -= 1;
            return Ok(());
        }

        // 波动率检查
        if !self.market.is_volatile_enough(self.config.min_volatility_bps).await {
            tracing::info!("Skipping round: volatility too low");
            metrics::counter!("rounds_skipped_low_vol").increment(1);
            return Ok(());
        }

        let snapshot = self.market.snapshot().await;
        let open_price = snapshot.btc_price;

        // Phase 1: 链上开启新轮次
        tracing::info!(price = open_price, "Starting new round");
        let round_id = self.chain.start_round(open_price).await?;
        state.round_id = round_id;
        state.open_price = open_price;
        state.phase = RoundPhase::Commit;
        drop(state); // 释放锁

        // Phase 2: 等待 commit 窗口
        tokio::time::sleep(self.config.commit_window).await;

        // Phase 3: 推进到 reveal
        self.chain.advance_to_reveal(round_id).await?;
        self.state.write().await.phase = RoundPhase::Reveal;

        // Phase 4: 等待 reveal 窗口
        tokio::time::sleep(self.config.reveal_window).await;

        // Phase 5: 读取链上聚合结果，执行下注
        self.state.write().await.phase = RoundPhase::Betting;
        let round_data = self.chain.get_round(round_id).await?;

        let (should_bet, direction) = self.evaluate_signal(&round_data);

        let bet_placed = if should_bet {
            let bet_size = self.chain.get_bet_size().await?;

            if !self.risk.can_bet(bet_size).await {
                tracing::warn!("Risk manager blocked bet");
                false
            } else {
                let pnl = self.executor.execute_bet(direction, bet_size).await?;

                // Polymarket 异步结算：execute_bet 返回 0 表示已下注等待结算
                // 记录到 SettlementTracker
                if self.executor.name() == "Polymarket" {
                    let now_ts = chrono::Utc::now().timestamp() as u64;
                    self.settlement.record_bet(BetRecord {
                        round_id,
                        order_id: format!("round-{round_id}"),
                        token_id: String::new(),
                        is_up: direction,
                        amount_usdc: rust_decimal::Decimal::new(bet_size as i64, 6),
                        placed_at: now_ts,
                        market_slug: format!("btc-updown-15m-{}", now_ts),
                        status: BetStatus::Pending,
                        pnl: None,
                    }).await;
                }

                tracing::info!(
                    direction = if direction { "UP" } else { "DOWN" },
                    bet_size,
                    executor = self.executor.name(),
                    "Bet executed"
                );
                true
            }
        } else {
            tracing::info!("Signal insufficient, skipping bet");
            false
        };

        // Phase 6: 等待市场结算
        self.state.write().await.phase = RoundPhase::WaitingForSettlement;
        let settle_duration = self.config.round_duration
            - self.config.commit_window
            - self.config.reveal_window;
        tokio::time::sleep(settle_duration).await;

        // Phase 7: 获取收盘价，结算
        let close_price = self.market.btc_price().await;
        let btc_went_up = close_price >= open_price;

        // 对于 Polymarket：通过 SettlementTracker 获取实际 P&L
        let profit_loss = if self.executor.name() == "Polymarket" && bet_placed {
            self.settlement.settle_round(round_id, btc_went_up).await.unwrap_or(0)
        } else if bet_placed {
            // DryRun / CEX 模式：execute_bet 已返回实际 P&L
            0i64
        } else {
            0i64
        };

        self.chain.settle_round(round_id, close_price, profit_loss).await?;
        self.risk.record_pnl(profit_loss).await;

        // 盈利时触发 BSC 利润分发（异步，不阻塞下一轮）
        if profit_loss > 0 {
            let profit_usdt = profit_loss as f64 / 1_000_000.0;
            tracing::info!(
                round_id,
                profit_usdt,
                "Profit round — BSC distribution triggered"
            );
            // Phase 0: 通过外部脚本分发
            // Phase 1: 引擎内直接调 BSC RPC
            metrics::gauge!("last_profit_usdt").set(profit_usdt);
        }

        // 更新连败计数
        let mut state = self.state.write().await;
        if profit_loss < 0 {
            state.consecutive_losses += 1;
            if state.consecutive_losses >= self.risk.config.consecutive_loss_pause {
                state.paused_rounds_remaining = self.risk.config.pause_rounds;
                tracing::warn!(losses = state.consecutive_losses, "Circuit breaker triggered");
            }
        } else if profit_loss > 0 {
            state.consecutive_losses = 0;
        }
        state.phase = RoundPhase::WaitingForStart;

        metrics::counter!("rounds_completed").increment(1);
        Ok(())
    }

    fn evaluate_signal(&self, round_data: &crate::chain::RoundData) -> (bool, bool) {
        let total = round_data.up_weight + round_data.down_weight;
        if total == 0 {
            return (false, true);
        }

        let up_ratio = round_data.up_weight as f64 / total as f64;

        if up_ratio >= 0.6 {
            (true, true) // bet UP
        } else if up_ratio <= 0.4 {
            (true, false) // bet DOWN
        } else {
            (false, true) // skip
        }
    }

    async fn wait_for_next_slot(&self) {
        // 对齐到下一个 15 分钟整点
        let now = chrono::Utc::now();
        let mins = now.minute();
        let next_slot = ((mins / 15) + 1) * 15;
        let wait_mins = next_slot - mins;
        let wait_secs = (wait_mins as u64) * 60 - now.second() as u64;

        tracing::debug!(wait_secs, "Waiting for next round slot");
        tokio::time::sleep(std::time::Duration::from_secs(wait_secs)).await;
    }

    pub async fn current_phase(&self) -> RoundPhase {
        self.state.read().await.phase
    }

    pub async fn current_round_id(&self) -> u64 {
        self.state.read().await.round_id
    }
}

// chrono::Utc 需要 minute() 和 second()
use chrono::Timelike;
