use anyhow::Result;
use futures_util::StreamExt;
use serde::Deserialize;
use std::sync::Arc;
use tokio::sync::RwLock;
use tokio_tungstenite::connect_async;

use super::MarketSnapshot;

#[derive(Debug, Deserialize)]
struct BinanceTicker {
    #[serde(rename = "c")]
    close: String,
    #[serde(rename = "E")]
    event_time: u64,
    #[serde(rename = "h")]
    high: String,
    #[serde(rename = "l")]
    low: String,
}

pub async fn run_binance_ws(
    ws_url: &str,
    symbol: &str,
    state: Arc<RwLock<MarketSnapshot>>,
) -> Result<()> {
    let url = format!("{}/ws/{}@ticker", ws_url, symbol.to_lowercase());

    loop {
        tracing::info!(url = %url, "Connecting to Binance WebSocket");

        match connect_async(&url).await {
            Ok((ws_stream, _)) => {
                let (_, mut read) = ws_stream.split();

                while let Some(msg) = read.next().await {
                    match msg {
                        Ok(tokio_tungstenite::tungstenite::Message::Text(text)) => {
                            if let Ok(ticker) = serde_json::from_str::<BinanceTicker>(&text) {
                                let price: f64 = ticker.close.parse().unwrap_or(0.0);
                                let high: f64 = ticker.high.parse().unwrap_or(0.0);
                                let low: f64 = ticker.low.parse().unwrap_or(0.0);

                                let volatility_bps = if price > 0.0 {
                                    ((high - low) / price * 10000.0) as u32
                                } else {
                                    0
                                };

                                let mut snapshot = state.write().await;
                                snapshot.btc_price = price;
                                snapshot.timestamp_ms = ticker.event_time;
                                snapshot.volatility_bps = volatility_bps;
                            }
                        }
                        Ok(_) => {}
                        Err(e) => {
                            tracing::warn!(?e, "WebSocket read error");
                            break;
                        }
                    }
                }
            }
            Err(e) => {
                tracing::error!(?e, "Failed to connect to Binance WebSocket");
            }
        }

        tracing::info!("Reconnecting in 5 seconds...");
        tokio::time::sleep(std::time::Duration::from_secs(5)).await;
    }
}
