use anyhow::Result;
use serde::Deserialize;
use std::time::Duration;

#[derive(Debug, Clone, Deserialize)]
pub struct AppConfig {
    pub chain: ChainConfig,
    pub market: MarketConfig,
    pub execution: ExecutionConfig,
    pub risk: RiskConfig,
    pub scheduler: SchedulerConfig,
    pub api: ApiConfig,
}

#[derive(Debug, Clone, Deserialize)]
pub struct ChainConfig {
    pub rpc_url: String,
    pub ws_url: String,
    pub private_key: String, // Operator EOA
    pub contracts: ContractAddresses,
}

#[derive(Debug, Clone, Deserialize)]
pub struct ContractAddresses {
    pub hive_round: String,
    pub hive_vault: String,
    pub hive_score: String,
    pub hive_agent: String,
}

#[derive(Debug, Clone, Deserialize)]
pub struct MarketConfig {
    pub binance_ws: String,
    pub okx_ws: String,
    pub symbol: String, // "BTCUSDT"
}

#[derive(Debug, Clone, Deserialize)]
pub struct ExecutionConfig {
    pub mode: ExecutionMode,
    pub polymarket: Option<PolymarketConfig>,
    pub cex_api_key: Option<String>,
    pub cex_api_secret: Option<String>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct PolymarketConfig {
    pub private_key: String,
    pub host: String,           // "https://clob.polymarket.com"
    pub chain_id: u64,          // 137 (Polygon mainnet) or 80002 (Amoy testnet)
    pub signature_type: u8,     // 0=EOA, 1=Proxy, 2=GnosisSafe
    pub funder: Option<String>, // 代理钱包地址（type 1/2 时必填）
    pub crypto: String,         // "BTC"
    pub interval_minutes: u32,  // 15
    pub max_slippage_bps: u32,  // 最大滑点 (basis points), 默认 200 = 2%
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum ExecutionMode {
    Polymarket,
    Cex,
    DryRun, // 模拟执行，不真实下注
}

#[derive(Debug, Clone, Deserialize)]
pub struct RiskConfig {
    pub max_bet_bps: u32,            // 默认 200 (2%)
    pub daily_loss_limit_bps: u32,   // 默认 800 (8%)
    pub weekly_loss_limit_bps: u32,  // 默认 1500 (15%)
    pub consecutive_loss_pause: u32, // 连败 N 次暂停
    pub pause_rounds: u32,           // 暂停几轮
}

#[derive(Debug, Clone, Deserialize)]
pub struct SchedulerConfig {
    #[serde(with = "humantime_serde")]
    pub round_duration: Duration,
    #[serde(with = "humantime_serde")]
    pub commit_window: Duration,
    #[serde(with = "humantime_serde")]
    pub reveal_window: Duration,
    pub min_volatility_bps: u32,    // 波动率低于此值跳轮
    pub active_hours: Vec<(u8, u8)>, // UTC 活跃时段
}

#[derive(Debug, Clone, Deserialize)]
pub struct ApiConfig {
    pub host: String,
    pub port: u16,
}

// humantime 反序列化支持
mod humantime_serde {
    use serde::{self, Deserialize, Deserializer};
    use std::time::Duration;

    pub fn deserialize<'de, D>(deserializer: D) -> Result<Duration, D::Error>
    where
        D: Deserializer<'de>,
    {
        let s = String::deserialize(deserializer)?;
        humantime::parse_duration(&s).map_err(serde::de::Error::custom)
    }
}

impl AppConfig {
    pub fn load() -> Result<Self> {
        dotenvy::dotenv().ok();

        let config = config::Config::builder()
            .add_source(config::File::with_name("config").required(false))
            .add_source(config::Environment::with_prefix("HIVE").separator("__"))
            .build()?;

        Ok(config.try_deserialize()?)
    }
}

impl Default for RiskConfig {
    fn default() -> Self {
        Self {
            max_bet_bps: 200,
            daily_loss_limit_bps: 800,
            weekly_loss_limit_bps: 1500,
            consecutive_loss_pause: 5,
            pause_rounds: 3,
        }
    }
}
