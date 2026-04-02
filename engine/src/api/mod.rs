mod ws;

use anyhow::Result;
use axum::{
    extract::{Path, State},
    routing::{get, post},
    Json, Router,
};
use std::sync::Arc;

use crate::chain::ChainClient;
use crate::config::ApiConfig;
use crate::execution::Executor;
use crate::market::MarketFeed;
use crate::scheduler::RoundManager;

#[derive(Clone)]
pub struct AppState {
    pub chain: ChainClient,
    pub round_manager: RoundManager,
    pub executor: Arc<dyn Executor>,
    pub market: MarketFeed,
}

pub async fn serve(
    config: ApiConfig,
    chain: ChainClient,
    round_manager: RoundManager,
    executor: Arc<dyn Executor>,
    market: MarketFeed,
) -> Result<()> {
    let state = AppState {
        chain,
        round_manager,
        executor,
        market,
    };

    let app = Router::new()
        .route("/health", get(health))
        // 轮次
        .route("/v1/round/current", get(current_round))
        .route("/v1/round/{id}", get(round_by_id))
        // Agent
        .route("/v1/agent/{address}/stats", get(agent_stats))
        // 排行榜
        .route("/v1/leaderboard", get(leaderboard))
        // 金库
        .route("/v1/treasury", get(treasury))
        // 执行器
        .route("/v1/executor/status", get(executor_status))
        // 行情
        .route("/v1/market/snapshot", get(market_snapshot))
        // WebSocket
        .route("/v1/ws", get(ws::ws_handler))
        .with_state(state);

    let addr = format!("{}:{}", config.host, config.port);
    tracing::info!(addr = %addr, "API server starting");

    let listener = tokio::net::TcpListener::bind(&addr).await?;
    axum::serve(listener, app).await?;

    Ok(())
}

async fn health() -> &'static str {
    "ok"
}

async fn current_round(State(state): State<AppState>) -> Json<serde_json::Value> {
    let round_id = state.round_manager.current_round_id().await;
    let phase = state.round_manager.current_phase().await;
    let snapshot = state.market.snapshot().await;

    Json(serde_json::json!({
        "round_id": round_id,
        "phase": format!("{:?}", phase),
        "btc_price": snapshot.btc_price,
        "volatility_bps": snapshot.volatility_bps,
        "trend_15m": snapshot.trend_15m,
    }))
}

async fn round_by_id(
    State(state): State<AppState>,
    Path(id): Path<u64>,
) -> Json<serde_json::Value> {
    match state.chain.get_round(id).await {
        Ok(rd) => Json(serde_json::json!({
            "round_id": rd.round_id,
            "phase": rd.phase,
            "open_price": rd.open_price as f64 / 1e8,
            "close_price": rd.close_price as f64 / 1e8,
            "up_weight": rd.up_weight,
            "down_weight": rd.down_weight,
            "participant_count": rd.participant_count,
            "bet_amount": rd.bet_amount as f64 / 1e6,
            "profit_loss": rd.profit_loss as f64 / 1e6,
        })),
        Err(_) => Json(serde_json::json!({ "error": "Round not found" })),
    }
}

async fn agent_stats(
    State(state): State<AppState>,
    Path(address): Path<String>,
) -> Json<serde_json::Value> {
    let score = state.chain.get_score(&address).await.unwrap_or(0);

    Json(serde_json::json!({
        "address": address,
        "hive_score": score,
    }))
}

async fn leaderboard(State(_state): State<AppState>) -> Json<serde_json::Value> {
    Json(serde_json::json!({
        "agents": [],
        "note": "Will be populated once agents start participating"
    }))
}

async fn treasury(State(state): State<AppState>) -> Json<serde_json::Value> {
    let balance = state.executor.available_balance().await.unwrap_or(0);
    let on_chain_balance = state.chain.get_treasury_balance().await.unwrap_or(0);

    Json(serde_json::json!({
        "executor": state.executor.name(),
        "executor_balance_usdc": balance as f64 / 1e6,
        "on_chain_balance_usdt": on_chain_balance as f64 / 1e6,
    }))
}

async fn executor_status(State(state): State<AppState>) -> Json<serde_json::Value> {
    let balance = state.executor.available_balance().await.unwrap_or(0);

    Json(serde_json::json!({
        "executor": state.executor.name(),
        "balance_usdc": balance as f64 / 1e6,
        "status": "active",
    }))
}

async fn market_snapshot(State(state): State<AppState>) -> Json<serde_json::Value> {
    let snapshot = state.market.snapshot().await;

    Json(serde_json::json!({
        "btc_price": snapshot.btc_price,
        "timestamp_ms": snapshot.timestamp_ms,
        "volatility_bps": snapshot.volatility_bps,
        "trend_1m": snapshot.trend_1m,
        "trend_5m": snapshot.trend_5m,
        "trend_15m": snapshot.trend_15m,
        "volume_spike": snapshot.volume_spike,
    }))
}
