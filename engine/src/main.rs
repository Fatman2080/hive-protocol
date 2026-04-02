mod api;
mod chain;
mod config;
mod execution;
mod market;
mod risk;
mod scheduler;
mod settlement;

use anyhow::Result;
use tracing_subscriber::{fmt, EnvFilter};

#[tokio::main]
async fn main() -> Result<()> {
    fmt()
        .with_env_filter(EnvFilter::from_default_env().add_directive("hive_engine=info".parse()?))
        .json()
        .init();

    let cfg = config::AppConfig::load()?;

    tracing::info!(
        rpc_url = %cfg.chain.rpc_url,
        "Starting Hive Engine v{}",
        env!("CARGO_PKG_VERSION")
    );

    let chain_client = chain::ChainClient::new(&cfg.chain).await?;
    let market_feed = market::MarketFeed::new(&cfg.market).await?;
    let executor = execution::create_executor(&cfg.execution).await?;
    let risk_manager = risk::RiskManager::new(&cfg.risk);

    let round_manager = scheduler::RoundManager::new(
        chain_client.clone(),
        market_feed.clone(),
        executor.clone(),
        risk_manager,
        cfg.scheduler.clone(),
    );

    let api_handle = api::serve(
        cfg.api.clone(),
        chain_client.clone(),
        round_manager.clone(),
        executor,
        market_feed,
    );
    let scheduler_handle = round_manager.run();

    tokio::select! {
        res = api_handle => { tracing::error!(?res, "API server exited"); }
        res = scheduler_handle => { tracing::error!(?res, "Round scheduler exited"); }
    }

    Ok(())
}
