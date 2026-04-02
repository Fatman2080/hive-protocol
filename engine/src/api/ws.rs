use axum::{
    extract::{
        State,
        ws::{Message, WebSocket, WebSocketUpgrade},
    },
    response::IntoResponse,
};
use futures_util::{SinkExt, StreamExt};

use super::AppState;

pub async fn ws_handler(
    ws: WebSocketUpgrade,
    State(state): State<AppState>,
) -> impl IntoResponse {
    ws.on_upgrade(move |socket| handle_socket(socket, state))
}

async fn handle_socket(socket: WebSocket, state: AppState) {
    let (mut sender, mut receiver) = socket.split();

    tracing::info!("WebSocket client connected");

    let state_clone = state.clone();
    let send_task = tokio::spawn(async move {
        let mut interval = tokio::time::interval(std::time::Duration::from_secs(5));
        let mut last_round_id = 0u64;
        let mut last_phase = String::new();

        loop {
            interval.tick().await;

            let round_id = state_clone.round_manager.current_round_id().await;
            let phase = format!("{:?}", state_clone.round_manager.current_phase().await);
            let snapshot = state_clone.market.snapshot().await;

            // 只在状态变化时推送完整更新
            let phase_changed = phase != last_phase || round_id != last_round_id;

            let msg = if phase_changed {
                last_round_id = round_id;
                last_phase = phase.clone();

                serde_json::json!({
                    "type": "round_update",
                    "round_id": round_id,
                    "phase": phase,
                    "btc_price": snapshot.btc_price,
                    "volatility_bps": snapshot.volatility_bps,
                    "trend_15m": snapshot.trend_15m,
                })
            } else {
                serde_json::json!({
                    "type": "heartbeat",
                    "btc_price": snapshot.btc_price,
                    "timestamp_ms": snapshot.timestamp_ms,
                })
            };

            if sender.send(Message::Text(msg.to_string().into())).await.is_err() {
                break;
            }
        }
    });

    let recv_task = tokio::spawn(async move {
        while let Some(Ok(msg)) = receiver.next().await {
            match msg {
                Message::Text(text) => {
                    tracing::debug!(msg = %text, "WS received");
                }
                Message::Close(_) => break,
                _ => {}
            }
        }
    });

    tokio::select! {
        _ = send_task => {},
        _ = recv_task => {},
    }

    tracing::info!("WebSocket client disconnected");
}
