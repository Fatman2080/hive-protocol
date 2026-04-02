//! 链上交互客户端
//!
//! 封装所有与 Axon 链上合约的交互。
//! Phase 0: 使用 alloy 直接读写合约。
//! Phase 1+: 增加重试、nonce 管理、Gas 估算。

use anyhow::Result;
use std::sync::Arc;
use tokio::sync::RwLock;

use crate::config::ChainConfig;

/// 链上轮次数据（从合约 getRound 读取）
#[derive(Debug, Clone, Default)]
pub struct RoundData {
    pub round_id: u64,
    pub phase: u8,
    pub open_price: u64,
    pub close_price: u64,
    pub up_weight: u64,
    pub down_weight: u64,
    pub participant_count: u64,
    pub bet_amount: u64,
    pub profit_loss: i64,
    pub start_time: u64,
}

/// 交易收据摘要
#[derive(Debug, Clone)]
pub struct TxReceipt {
    pub tx_hash: String,
    pub block_number: u64,
    pub gas_used: u64,
    pub success: bool,
}

/// 链上交互客户端
///
/// 职责：
///   - 发送交易（startRound, advanceToReveal, settle）
///   - 读取合约状态（getRound, currentBetSize, getScore）
///   - Nonce 管理（防止交易冲突）
///   - 重试逻辑（网络抖动自动重试）
#[derive(Clone)]
pub struct ChainClient {
    rpc_url: String,
    contracts: crate::config::ContractAddresses,
    nonce: Arc<RwLock<u64>>,
    // Phase 1: 替换为 alloy Provider + Signer
    // provider: Arc<Provider>,
    // wallet: LocalWallet,
}

impl ChainClient {
    pub async fn new(config: &ChainConfig) -> Result<Self> {
        tracing::info!(rpc = %config.rpc_url, "Connecting to Axon RPC");

        // Phase 1: 实际连接
        // let provider = ProviderBuilder::new()
        //     .with_recommended_fillers()
        //     .on_http(config.rpc_url.parse()?);
        // let wallet = LocalWallet::from_str(&config.private_key)?;

        Ok(Self {
            rpc_url: config.rpc_url.clone(),
            contracts: config.contracts.clone(),
            nonce: Arc::new(RwLock::new(0)),
        })
    }

    // ─── 写入交易 ──────────────────────────────────────

    /// 链上调用 HiveRound.startRound(openPrice)
    /// openPrice: BTC 价格 × 1e8（与合约精度一致）
    pub async fn start_round(&self, open_price: f64) -> Result<u64> {
        let price_scaled = (open_price * 1e8) as u64;
        tracing::info!(price = open_price, scaled = price_scaled, "start_round");

        // Phase 1 实现：
        // let tx = self.round_contract.startRound(U256::from(price_scaled));
        // let receipt = tx.send().await?.get_receipt().await?;
        // let round_id = parse_event_log(receipt, "RoundStarted");

        metrics::counter!("chain_tx_sent", "method" => "startRound").increment(1);
        Ok(1) // placeholder
    }

    /// 推进到 REVEAL 阶段
    pub async fn advance_to_reveal(&self, round_id: u64) -> Result<TxReceipt> {
        tracing::info!(round_id, "advance_to_reveal");

        // let tx = self.round_contract.advanceToReveal(U256::from(round_id));
        // let receipt = tx.send().await?.get_receipt().await?;

        metrics::counter!("chain_tx_sent", "method" => "advanceToReveal").increment(1);
        Ok(TxReceipt {
            tx_hash: "0x...".into(),
            block_number: 0,
            gas_used: 0,
            success: true,
        })
    }

    /// 结算轮次
    pub async fn settle_round(
        &self,
        round_id: u64,
        close_price: f64,
        profit_loss: i64,
    ) -> Result<TxReceipt> {
        let price_scaled = (close_price * 1e8) as u64;
        tracing::info!(round_id, close_price, profit_loss, "settle_round");

        // let tx = self.round_contract.settle(
        //     U256::from(round_id),
        //     U256::from(price_scaled),
        //     I256::from(profit_loss),
        // );
        // let receipt = tx.send().await?.get_receipt().await?;

        metrics::counter!("chain_tx_sent", "method" => "settle").increment(1);
        Ok(TxReceipt {
            tx_hash: "0x...".into(),
            block_number: 0,
            gas_used: 0,
            success: true,
        })
    }

    // ─── 只读查询 ──────────────────────────────────────

    /// 读取轮次数据
    pub async fn get_round(&self, round_id: u64) -> Result<RoundData> {
        // let data = self.round_contract.getRound(U256::from(round_id)).call().await?;
        Ok(RoundData {
            round_id,
            ..Default::default()
        })
    }

    /// 读取当前下注额度
    pub async fn get_bet_size(&self) -> Result<u64> {
        // let size = self.vault_contract.currentBetSize().call().await?;
        Ok(200_000_000) // 200 USDT placeholder
    }

    /// 读取当前轮次 ID
    pub async fn get_current_round_id(&self) -> Result<u64> {
        // let id = self.round_contract.currentRoundId().call().await?;
        Ok(0)
    }

    /// 读取金库余额
    pub async fn get_treasury_balance(&self) -> Result<u64> {
        // let balance = self.vault_contract.treasuryBalance().call().await?;
        Ok(10_000_000_000) // 10,000 USDT placeholder
    }

    /// 读取 Agent 的 HiveScore
    pub async fn get_score(&self, agent: &str) -> Result<u64> {
        // let score = self.score_contract.getScore(agent.parse()?).call().await?;
        Ok(50) // placeholder
    }

    // ─── 内部工具 ──────────────────────────────────────

    async fn next_nonce(&self) -> u64 {
        let mut nonce = self.nonce.write().await;
        let n = *nonce;
        *nonce += 1;
        n
    }
}
