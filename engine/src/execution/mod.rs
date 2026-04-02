mod dry_run;
pub mod polymarket;

use anyhow::Result;
use std::sync::Arc;

use crate::config::{ExecutionConfig, ExecutionMode};

/// 执行器抽象——所有执行路径（Polymarket / CEX / DryRun）实现此 trait
#[async_trait::async_trait]
pub trait Executor: Send + Sync {
    /// 执行下注
    /// - `is_up`: true = 买涨, false = 买跌
    /// - `amount_usdt`: 下注金额（USDT, 6 decimals）
    /// - 返回: 盈亏金额（正=盈利，负=亏损，单位与 amount 相同）
    async fn execute_bet(&self, is_up: bool, amount_usdt: u64) -> Result<i64>;

    /// 获取当前可用余额
    async fn available_balance(&self) -> Result<u64>;

    /// 执行器名称（日志用）
    fn name(&self) -> &str;
}

pub async fn create_executor(config: &ExecutionConfig) -> Result<Arc<dyn Executor>> {
    match config.mode {
        ExecutionMode::DryRun => {
            tracing::info!("Using DryRun executor (no real bets)");
            Ok(Arc::new(dry_run::DryRunExecutor::new()))
        }
        ExecutionMode::Polymarket => {
            let pm_config = config.polymarket.as_ref()
                .ok_or_else(|| anyhow::anyhow!(
                    "execution.mode = polymarket but [execution.polymarket] config is missing"
                ))?;
            let executor = polymarket::PolymarketExecutor::new(pm_config).await?;
            tracing::info!("Using Polymarket executor (live trading)");
            Ok(Arc::new(executor))
        }
        ExecutionMode::Cex => {
            tracing::warn!("CEX executor not implemented yet, falling back to DryRun");
            Ok(Arc::new(dry_run::DryRunExecutor::new()))
        }
    }
}
