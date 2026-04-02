mod price_feed;

use anyhow::Result;
use std::sync::Arc;
use tokio::sync::RwLock;

use crate::config::MarketConfig;

/// BTC 实时价格 + 波动率数据
#[derive(Debug, Clone)]
pub struct MarketSnapshot {
    pub btc_price: f64,
    pub timestamp_ms: u64,
    pub volatility_bps: u32, // 15 分钟波动率 (basis points)
    pub trend_1m: f64,
    pub trend_5m: f64,
    pub trend_15m: f64,
    pub volume_spike: bool,
}

/// 多源行情聚合服务
#[derive(Clone)]
pub struct MarketFeed {
    state: Arc<RwLock<MarketSnapshot>>,
}

impl MarketFeed {
    pub async fn new(config: &MarketConfig) -> Result<Self> {
        let initial = MarketSnapshot {
            btc_price: 0.0,
            timestamp_ms: 0,
            volatility_bps: 0,
            trend_1m: 0.0,
            trend_5m: 0.0,
            trend_15m: 0.0,
            volume_spike: false,
        };

        let feed = Self {
            state: Arc::new(RwLock::new(initial)),
        };

        // 启动 Binance 和 OKX WebSocket 订阅
        let state = feed.state.clone();
        let binance_ws = config.binance_ws.clone();
        let symbol = config.symbol.clone();
        tokio::spawn(async move {
            if let Err(e) = price_feed::run_binance_ws(&binance_ws, &symbol, state).await {
                tracing::error!(?e, "Binance WebSocket disconnected");
            }
        });

        Ok(feed)
    }

    pub async fn snapshot(&self) -> MarketSnapshot {
        self.state.read().await.clone()
    }

    pub async fn btc_price(&self) -> f64 {
        self.state.read().await.btc_price
    }

    /// 波动率是否足以参与下注
    pub async fn is_volatile_enough(&self, min_bps: u32) -> bool {
        self.state.read().await.volatility_bps >= min_bps
    }
}
