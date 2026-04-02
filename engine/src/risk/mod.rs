use std::sync::Arc;
use tokio::sync::RwLock;

use crate::config::RiskConfig;

/// 链下风控管理器
#[derive(Clone)]
pub struct RiskManager {
    pub config: RiskConfig,
    state: Arc<RwLock<RiskState>>,
}

struct RiskState {
    daily_pnl: i64,
    weekly_pnl: i64,
    is_halted: bool,
}

impl RiskManager {
    pub fn new(config: &RiskConfig) -> Self {
        Self {
            config: config.clone(),
            state: Arc::new(RwLock::new(RiskState {
                daily_pnl: 0,
                weekly_pnl: 0,
                is_halted: false,
            })),
        }
    }

    pub async fn can_bet(&self, amount: u64) -> bool {
        let state = self.state.read().await;

        if state.is_halted {
            return false;
        }

        // 检查日亏损限额
        let daily_loss = (-state.daily_pnl).max(0) as u64;
        let daily_limit = amount * self.config.daily_loss_limit_bps as u64 / 10000;
        if daily_loss >= daily_limit {
            tracing::warn!(daily_loss, daily_limit, "Daily loss limit reached");
            return false;
        }

        true
    }

    pub async fn record_pnl(&self, pnl: i64) {
        let mut state = self.state.write().await;
        state.daily_pnl += pnl;
        state.weekly_pnl += pnl;
    }

    pub async fn reset_daily(&self) {
        self.state.write().await.daily_pnl = 0;
    }

    pub async fn reset_weekly(&self) {
        let mut state = self.state.write().await;
        state.weekly_pnl = 0;
        state.daily_pnl = 0;
    }

    pub async fn halt(&self) {
        self.state.write().await.is_halted = true;
    }

    pub async fn resume(&self) {
        self.state.write().await.is_halted = false;
    }
}
