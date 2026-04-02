use anyhow::Result;
use rust_decimal::Decimal;
use rust_decimal_macros::dec;
use std::sync::Arc;
use tokio::sync::RwLock;

/// 单轮下注记录
#[derive(Debug, Clone)]
pub struct BetRecord {
    pub round_id: u64,
    pub order_id: String,
    pub token_id: String,
    pub is_up: bool,
    pub amount_usdc: Decimal,
    pub placed_at: u64,
    pub market_slug: String,
    pub status: BetStatus,
    pub pnl: Option<i64>,
}

#[derive(Debug, Clone, PartialEq)]
pub enum BetStatus {
    Pending,
    Won,
    Lost,
    Cancelled,
}

/// 管理 Polymarket 下注的异步结算
///
/// 因为 Polymarket 的 BTC 15 分钟市场是异步结算的：
/// 1. 下注（买入 UP/DOWN token）→ 立即完成
/// 2. 等待 15 分钟市场 resolution
/// 3. 赢家 token 可赎回 $1/share，输家 = $0
///
/// SettlementTracker 负责：
/// - 记录未结算的下注
/// - 轮询市场 resolution 状态
/// - 计算实际 P&L
/// - 触发链上结算
pub struct SettlementTracker {
    pending_bets: Arc<RwLock<Vec<BetRecord>>>,
    settled_bets: Arc<RwLock<Vec<BetRecord>>>,
}

impl SettlementTracker {
    pub fn new() -> Self {
        Self {
            pending_bets: Arc::new(RwLock::new(Vec::new())),
            settled_bets: Arc::new(RwLock::new(Vec::new())),
        }
    }

    /// 记录一笔新的下注
    pub async fn record_bet(&self, bet: BetRecord) {
        tracing::info!(
            round_id = bet.round_id,
            order_id = %bet.order_id,
            direction = if bet.is_up { "UP" } else { "DOWN" },
            amount = %bet.amount_usdc,
            "Recording bet for settlement tracking"
        );
        self.pending_bets.write().await.push(bet);
    }

    /// 检查并结算已 resolution 的市场
    ///
    /// 对于 Polymarket BTC 15m 市场：
    /// - 通过 Gamma API 检查市场是否已 closed
    /// - 读取 resolution 结果（UP 或 DOWN 赢）
    /// - 计算 P&L
    pub async fn check_and_settle(&self) -> Result<Vec<BetRecord>> {
        let now_ts = chrono::Utc::now().timestamp() as u64;
        let mut settled = Vec::new();

        let mut pending = self.pending_bets.write().await;
        let mut still_pending = Vec::new();

        for mut bet in pending.drain(..) {
            // 粗略检查：如果下注时间超过 20 分钟还未结算，标记为需要检查
            let age_secs = now_ts.saturating_sub(bet.placed_at);

            if age_secs < 900 {
                // 不到 15 分钟，市场还未 resolution
                still_pending.push(bet);
                continue;
            }

            // 通过 Gamma API 查询市场 resolution 状态
            // Phase 1: 实际调用 Gamma API
            // let market = gamma.market_by_slug(&bet.market_slug).await?;
            // let resolved = market.closed && market.resolution.is_some();

            // Phase 0: 基于时间的简化判断
            if age_secs >= 960 {
                // 16 分钟后认为已结算，通过 Chainlink 价格判断
                // Phase 1: 从 Gamma API 读取实际 resolution
                tracing::info!(
                    round_id = bet.round_id,
                    age_secs,
                    "Bet eligible for settlement check"
                );

                // 暂时标记为待查，Phase 1 通过 API 获取实际结果
                bet.status = BetStatus::Pending;
                still_pending.push(bet);
            } else {
                still_pending.push(bet);
            }
        }

        *pending = still_pending;

        if !settled.is_empty() {
            self.settled_bets.write().await.extend(settled.clone());
        }

        Ok(settled)
    }

    /// 手动设置某轮的结算结果（由外部 round_manager 在获得价格后调用）
    pub async fn settle_round(&self, round_id: u64, btc_went_up: bool) -> Option<i64> {
        let mut pending = self.pending_bets.write().await;
        let mut pnl = None;

        let mut still_pending = Vec::new();
        for mut bet in pending.drain(..) {
            if bet.round_id == round_id {
                let won = bet.is_up == btc_went_up;
                bet.status = if won { BetStatus::Won } else { BetStatus::Lost };

                // P&L: 赢 = +amount (扣去成本后的净利), 输 = -amount
                let amount_micro = (bet.amount_usdc * dec!(1_000_000))
                    .to_string()
                    .parse::<i64>()
                    .unwrap_or(0);
                bet.pnl = Some(if won { amount_micro } else { -amount_micro });

                let direction = if bet.is_up { "UP" } else { "DOWN" };
                let result_str = if won { "WON" } else { "LOST" };
                tracing::info!(
                    round_id,
                    direction,
                    result = result_str,
                    pnl = bet.pnl,
                    "Round settled on Polymarket"
                );

                pnl = bet.pnl;
                self.settled_bets.write().await.push(bet);
            } else {
                still_pending.push(bet);
            }
        }

        *pending = still_pending;
        pnl
    }

    pub async fn pending_count(&self) -> usize {
        self.pending_bets.read().await.len()
    }

    pub async fn total_settled_pnl(&self) -> i64 {
        self.settled_bets.read().await.iter()
            .filter_map(|b| b.pnl)
            .sum()
    }
}
