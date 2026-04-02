use std::str::FromStr;
use std::sync::Arc;
use tokio::sync::RwLock;

use anyhow::{Context, Result, bail};
use rust_decimal::Decimal;
use rust_decimal_macros::dec;

use polymarket_client_sdk::POLYGON;
use polymarket_client_sdk::auth::LocalSigner;
use polymarket_client_sdk::clob::{Client as ClobClient, Config as ClobConfig};
use polymarket_client_sdk::clob::types::{Amount, OrderType, Side, SignatureType};
use polymarket_client_sdk::gamma::Client as GammaClient;
use polymarket_client_sdk::gamma::types::request::MarketsRequest;

use crate::config::PolymarketConfig;
use super::Executor;

/// BTC 15 分钟预测市场中 UP / DOWN 两个 outcome token 的 ID
#[derive(Debug, Clone)]
pub struct MarketTokens {
    pub slug: String,
    pub up_token_id: String,
    pub down_token_id: String,
    pub end_timestamp: u64,
}

/// 缓存当前轮次的市场信息，避免每次请求 Gamma API
struct CachedMarket {
    tokens: Option<MarketTokens>,
    fetched_at: u64,
}

pub struct PolymarketExecutor {
    clob: ClobClient,
    gamma: GammaClient,
    signer: alloy::signers::local::LocalSigner<alloy::signers::local::k256::ecdsa::SigningKey>,
    config: PolymarketConfig,
    market_cache: Arc<RwLock<CachedMarket>>,
}

impl PolymarketExecutor {
    pub async fn new(config: &PolymarketConfig) -> Result<Self> {
        let chain_id = config.chain_id;
        let signer = LocalSigner::from_str(&config.private_key)
            .context("Invalid Polymarket private key")?
            .with_chain_id(Some(chain_id));

        let sig_type = match config.signature_type {
            0 => SignatureType::Eoa,
            1 => SignatureType::Proxy,
            2 => SignatureType::GnosisSafe,
            _ => bail!("Invalid signature_type: must be 0, 1, or 2"),
        };

        let mut auth = ClobClient::new(&config.host, ClobConfig::default())?
            .authentication_builder(&signer)
            .signature_type(sig_type);

        if let Some(ref funder) = config.funder {
            let addr = funder.parse().context("Invalid funder address")?;
            auth = auth.funder(addr);
        }

        let clob = auth.authenticate().await
            .context("Failed to authenticate with Polymarket CLOB")?;

        let gamma = GammaClient::default();

        tracing::info!(
            host = %config.host,
            chain_id,
            wallet = %signer.address(),
            "Polymarket executor initialized"
        );

        Ok(Self {
            clob,
            gamma,
            signer,
            config: config.clone(),
            market_cache: Arc::new(RwLock::new(CachedMarket {
                tokens: None,
                fetched_at: 0,
            })),
        })
    }

    /// 通过 Gamma API 发现当前活跃的 BTC 15 分钟市场
    ///
    /// slug 格式: btc-updown-15m-{next_slot_timestamp}
    /// 返回 UP 和 DOWN 两个 token 的 ID
    pub async fn discover_current_market(&self) -> Result<MarketTokens> {
        let now_ts = chrono::Utc::now().timestamp() as u64;

        // 检查缓存（同一个 15 分钟窗口内不重复请求）
        {
            let cache = self.market_cache.read().await;
            if let Some(ref tokens) = cache.tokens {
                if tokens.end_timestamp > now_ts {
                    return Ok(tokens.clone());
                }
            }
        }

        let interval_secs = self.config.interval_minutes as u64 * 60;
        let next_slot = ((now_ts / interval_secs) + 1) * interval_secs;
        let slug = format!(
            "{}-updown-{}m-{}",
            self.config.crypto.to_lowercase(),
            self.config.interval_minutes,
            next_slot
        );

        tracing::info!(slug = %slug, next_slot, "Discovering Polymarket BTC 15m market");

        let request = MarketsRequest::builder()
            .slug(&slug)
            .build();
        let markets = self.gamma.markets(&request).await
            .context("Gamma API: failed to fetch market by slug")?;

        let market = markets.into_iter().next()
            .with_context(|| format!("No active market found for slug: {slug}"))?;

        // clobTokenIds: [UP_token, DOWN_token]
        let clob_ids: Vec<String> = serde_json::from_str(
            market.clob_token_ids.as_deref().unwrap_or("[]")
        ).context("Failed to parse clobTokenIds")?;

        if clob_ids.len() < 2 {
            bail!("Market {} has fewer than 2 clob token IDs", slug);
        }

        let tokens = MarketTokens {
            slug: slug.clone(),
            up_token_id: clob_ids[0].clone(),
            down_token_id: clob_ids[1].clone(),
            end_timestamp: next_slot + interval_secs,
        };

        // 更新缓存
        {
            let mut cache = self.market_cache.write().await;
            cache.tokens = Some(tokens.clone());
            cache.fetched_at = now_ts;
        }

        tracing::info!(
            slug,
            up_token = %tokens.up_token_id[..12.min(tokens.up_token_id.len())],
            down_token = %tokens.down_token_id[..12.min(tokens.down_token_id.len())],
            "Market discovered"
        );

        Ok(tokens)
    }

    /// 在 Polymarket 下市价单
    ///
    /// 对于 BTC 15 分钟预测市场:
    /// - 买 UP token = 看涨
    /// - 买 DOWN token = 看跌
    /// - token 定价在 0~1 之间，resolution 后赢家 = $1/share，输家 = $0/share
    async fn place_market_order(
        &self,
        token_id: &str,
        amount_usdc: Decimal,
    ) -> Result<PlacedOrder> {
        let order = self.clob
            .market_order()
            .token_id(token_id)
            .amount(Amount::usdc(amount_usdc)?)
            .side(Side::Buy)
            .order_type(OrderType::FOK)
            .build()
            .await
            .context("Failed to build market order")?;

        let signed = self.clob.sign(&self.signer, order).await
            .context("Failed to sign order")?;

        let response = self.clob.post_order(signed).await
            .context("Failed to post order to Polymarket")?;

        tracing::info!(
            order_id = %response.order_id,
            status = ?response.status,
            token_id = &token_id[..12.min(token_id.len())],
            amount = %amount_usdc,
            "Order placed on Polymarket"
        );

        Ok(PlacedOrder {
            order_id: response.order_id.to_string(),
            token_id: token_id.to_owned(),
            amount_usdc,
            filled: response.status == polymarket_client_sdk::clob::types::OrderStatus::Matched,
        })
    }
}

struct PlacedOrder {
    order_id: String,
    token_id: String,
    amount_usdc: Decimal,
    filled: bool,
}

#[async_trait::async_trait]
impl Executor for PolymarketExecutor {
    /// 在 Polymarket BTC 15 分钟市场执行下注
    ///
    /// - `is_up`: true = 买 UP token, false = 买 DOWN token
    /// - `amount_usdt`: 金额（6 decimals）
    /// - 返回值：本轮立即可知的损益为 0（需要等待市场 resolution 后通过 settlement 模块结算）
    ///   但会通过 metrics 记录下单信息
    async fn execute_bet(&self, is_up: bool, amount_usdt: u64) -> Result<i64> {
        let market = self.discover_current_market().await?;

        let token_id = if is_up {
            &market.up_token_id
        } else {
            &market.down_token_id
        };

        let amount_dec = Decimal::new(amount_usdt as i64, 6);

        let direction = if is_up { "UP" } else { "DOWN" };
        tracing::info!(
            direction,
            amount = %amount_dec,
            slug = %market.slug,
            "Executing Polymarket bet"
        );

        let order = self.place_market_order(token_id, amount_dec).await?;

        if !order.filled {
            tracing::warn!(order_id = %order.order_id, "Order not fully filled (FOK rejected)");
            metrics::counter!("polymarket_orders_rejected").increment(1);
            return Ok(0);
        }

        metrics::counter!("polymarket_orders_filled").increment(1);
        metrics::gauge!("polymarket_last_bet_size").set(amount_dec.to_string().parse::<f64>().unwrap_or(0.0));

        // Polymarket 预测市场是异步结算：
        // 下注后需要等 15 分钟市场关闭才知道结果。
        // 实际损益由 settlement 模块在 resolution 后查询。
        // 这里返回 0 表示"已下注，等待结算"。
        Ok(0)
    }

    async fn available_balance(&self) -> Result<u64> {
        // 查询 Polymarket 账户 USDC.e 余额
        // 通过 CLOB API 的 balance 端点获取
        let balance = self.clob.balance().await
            .context("Failed to query Polymarket balance")?;

        let usdc_micro = (balance * dec!(1_000_000))
            .to_string()
            .parse::<u64>()
            .unwrap_or(0);

        tracing::debug!(balance = %balance, usdc_micro, "Polymarket balance queried");
        Ok(usdc_micro)
    }

    fn name(&self) -> &str {
        "Polymarket"
    }
}
