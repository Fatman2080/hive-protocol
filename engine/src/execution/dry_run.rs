use anyhow::Result;
use std::sync::atomic::{AtomicU64, Ordering};

use super::Executor;

/// 模拟执行器——不实际下注，用于测试和验证
pub struct DryRunExecutor {
    virtual_balance: AtomicU64,
}

impl DryRunExecutor {
    pub fn new() -> Self {
        Self {
            virtual_balance: AtomicU64::new(10_000_000_000), // 10,000 USDT
        }
    }
}

#[async_trait::async_trait]
impl Executor for DryRunExecutor {
    async fn execute_bet(&self, is_up: bool, amount_usdt: u64) -> Result<i64> {
        // 模拟 50% 胜率的随机结果
        let random = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .subsec_nanos();

        let win = random % 2 == 0;
        let pnl = if win {
            amount_usdt as i64
        } else {
            -(amount_usdt as i64)
        };

        let direction = if is_up { "UP" } else { "DOWN" };
        let result = if win { "WIN" } else { "LOSS" };
        tracing::info!(
            direction,
            amount = amount_usdt,
            result,
            pnl,
            "[DryRun] Simulated bet"
        );

        Ok(pnl)
    }

    async fn available_balance(&self) -> Result<u64> {
        Ok(self.virtual_balance.load(Ordering::Relaxed))
    }

    fn name(&self) -> &str {
        "DryRun"
    }
}
