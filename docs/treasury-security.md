# 蜂巢协议金库账号安全管理方案

## 1. 架构概览

蜂巢协议的金库在两条链上运行：

| 链 | 用途 | 资产 |
|---|---|---|
| **Polygon** | Polymarket 交易执行 | USDC.e + POL (Gas) |
| **Axon** | 合约结算 + Agent 激励 | USDT + AXON |

核心原则：**最小权限 + 冷热分离 + 多签管理**

```
                    ┌─────────────────────┐
                    │   冷钱包 (Gnosis Safe) │  ← 大额资金存储
                    │   3/5 多签            │
                    └──────────┬──────────┘
                               │ 定期注入
                    ┌──────────▼──────────┐
                    │   热钱包 (EOA)        │  ← 日常交易执行
                    │   资金上限: $2,000    │
                    └──────────┬──────────┘
                               │
              ┌────────────────┼────────────────┐
              │                │                │
    ┌─────────▼──────┐  ┌─────▼──────┐  ┌─────▼──────┐
    │ Polymarket     │  │ Axon 合约  │  │ Gas 储备   │
    │ CLOB 交易      │  │ 结算交易   │  │ POL / AXON │
    └────────────────┘  └────────────┘  └────────────┘
```

## 2. 钱包层级

### 2.1 冷钱包 (Gnosis Safe 多签)

- **链**: Polygon (存 USDC.e) + Axon (存 USDT/AXON)
- **签名要求**: 3/5 多签
- **用途**: 大额资金存储、协议参数修改、紧急暂停
- **操作频率**: 每周/每月

```
签名人分配建议:
├── 创始人 #1 (Ledger 硬件钱包)
├── 创始人 #2 (Ledger 硬件钱包)
├── 技术负责人 (Trezor 硬件钱包)
├── 顾问 (Ledger 硬件钱包)
└── 社区代表 (硬件钱包) ← Phase 2 加入
```

### 2.2 热钱包 (EOA - 执行引擎专用)

- **链**: Polygon
- **私钥存储**: 环境变量 → Phase 1 迁移到 AWS KMS / HashiCorp Vault
- **资金上限**: 最大持有 $2,000 USDC.e (约 10 轮下注额度)
- **自动补充**: 当余额低于 $500 时，触发从冷钱包补充的通知

## 3. Polymarket 账号接入步骤

### 3.1 准备工作

```bash
# 1. 生成专用钱包（仅用于 Polymarket 交易）
cast wallet new

# 2. 记录地址和私钥
# Address: 0x...
# Private Key: 0x...

# 3. 向该地址转入初始资金
# - USDC.e: $2,000 (从冷钱包转入)
# - POL: 10 POL (Gas 费用，约 $5)
```

### 3.2 配置引擎

```toml
# engine/config.toml
[execution]
mode = "polymarket"

[execution.polymarket]
private_key      = "${POLYMARKET_PRIVATE_KEY}"  # 从环境变量读取
host             = "https://clob.polymarket.com"
chain_id         = 137
signature_type   = 0  # EOA
crypto           = "BTC"
interval_minutes = 15
max_slippage_bps = 200
```

### 3.3 Token Allowance 设置

首次使用 Polymarket 前需要授权 Exchange 合约：

```bash
# 设置 USDC.e 授权（仅需执行一次）
# Polymarket Exchange (Polygon): 0x4bFb41d5B3570DeFd03C39a9A4D8dE6Bd8B8982E
# USDC.e (Polygon): 0x2791Bca1f2de4661ED88A30C99A7a9449Aa84174

cast send 0x2791Bca1f2de4661ED88A30C99A7a9449Aa84174 \
  "approve(address,uint256)" \
  0x4bFb41d5B3570DeFd03C39a9A4D8dE6Bd8B8982E \
  0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff \
  --rpc-url https://polygon-rpc.com \
  --private-key $POLYMARKET_PRIVATE_KEY

# 设置 CTF (Conditional Token Framework) 授权
# CTF Exchange: 0x4D97DCd97eC945f40cF65F87097ACe5EA0476045
cast send 0x4D97DCd97eC945f40cF65F87097ACe5EA0476045 \
  "setApprovalForAll(address,bool)" \
  0x4bFb41d5B3570DeFd03C39a9A4D8dE6Bd8B8982E \
  true \
  --rpc-url https://polygon-rpc.com \
  --private-key $POLYMARKET_PRIVATE_KEY
```

### 3.4 首次验证

```bash
# 启动引擎（DryRun 模式验证连通性）
EXECUTION_MODE=dryrun cargo run

# 确认无误后切换到 Polymarket 模式
EXECUTION_MODE=polymarket cargo run
```

## 4. 安全分级策略

### Phase 0 (验证期, $2,000)

| 措施 | 实现 |
|---|---|
| 私钥存储 | 环境变量 (.env) |
| 资金上限 | $2,000 USDC.e |
| 单轮下注上限 | $200 (2%) |
| 日亏损上限 | $160 (8%) |
| 监控 | Prometheus + Grafana |
| 告警 | 日志 + Discord Webhook |

### Phase 1 (公测期, $10,000)

| 措施 | 实现 |
|---|---|
| 私钥存储 | **AWS KMS** (密钥永不离开 HSM) |
| 多签管理 | Gnosis Safe 3/5 |
| 热钱包限额 | $2,000 自动补充 |
| 交易审计 | 链上事件 → 数据库日志 |
| 告警 | PagerDuty / OpsGenie |
| IP 白名单 | 仅允许服务器 IP |

### Phase 2+ (增长期, $50,000+)

| 措施 | 实现 |
|---|---|
| 私钥存储 | **AWS CloudHSM** / **Fireblocks** |
| 交易审批 | 超过 $1,000 需多签确认 |
| 保险 | 链上保险协议 (Nexus Mutual) |
| 渗透测试 | 外部安全审计 |
| Bug 赏金 | Immunefi 漏洞悬赏 |

## 5. AWS KMS 集成示例 (Phase 1)

Polymarket Rust SDK 原生支持 `alloy::signers::Signer` trait，包括 AWS KMS：

```rust
use alloy::signers::aws::AwsSigner;
use aws_config::BehaviorVersion;

// 从 AWS KMS 加载签名者（私钥永不离开 HSM）
let config = aws_config::load_defaults(BehaviorVersion::latest()).await;
let kms_client = aws_sdk_kms::Client::new(&config);
let signer = AwsSigner::new(kms_client, "alias/hive-polymarket", Some(137)).await?;

// 用 KMS 签名者初始化 Polymarket 客户端
let clob = Client::new("https://clob.polymarket.com", Config::default())?
    .authentication_builder(&signer)
    .authenticate()
    .await?;
```

## 6. 监控与告警

### 6.1 关键指标

```yaml
# Prometheus 告警规则
groups:
  - name: hive-treasury
    rules:
      - alert: TreasuryLow
        expr: polymarket_balance_usdc < 500
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "金库余额不足 $500，需要补充"

      - alert: DailyLossLimit
        expr: increase(polymarket_orders_rejected[1d]) > 5
        for: 1m
        labels:
          severity: critical
        annotations:
          summary: "触发日亏损限额，交易已暂停"

      - alert: LargeWithdrawal
        expr: polymarket_withdrawal_usdc > 1000
        for: 0s
        labels:
          severity: critical
        annotations:
          summary: "检测到大额提现 > $1,000"
```

### 6.2 Discord 告警 Webhook

每轮交易结果实时推送到 Discord 频道：
- 下注方向 + 金额
- 胜/负结果 + P&L
- 当前金库余额
- 连败计数

## 7. 应急预案

| 场景 | 响应 |
|---|---|
| 私钥泄露 | 立即冻结热钱包 → 冷钱包转移资金 → 生成新钱包 |
| 连续亏损触发熔断 | 自动暂停 → 人工审查策略 → 决定是否恢复 |
| Polymarket API 异常 | 自动降级为 DryRun → 告警通知 → 手动切换 |
| 资金不足 | 暂停交易 → 通知多签补充 → 恢复 |
| Polygon 网络拥堵 | 提高 Gas Price → 重试 → 超时告警 |
