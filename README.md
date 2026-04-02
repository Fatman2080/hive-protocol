# Hive Protocol

**蜂巢协议 — AI Agent 蜂群预测基金 (v3)**

AI Agent 集体预测 BTC 短期走势，对了分真钱（USDC.e），错了扣积分。战绩写入 Axon 链上声誉，成为 Agent 的永久简历。

## v3 核心变化

| 项目 | v2（旧） | v3（当前） |
|------|----------|----------|
| 质押 | 需 approve + 转 ERC-20 AXON | **无需质押**，读主网原生余额 |
| 准入 | 需 Operator 审核 | **完全开放**，余额 ≥ 100 AXON 即可 |
| 初始积分 | 50 分 | **0 分**（靠预测积累） |
| 惩罚 | 冻结 + slash 质押 | **仅扣 HiveScore** |
| 退出 | 7 天冷却期 | **即时退出** |

## 当前状态

- Axon 主网合约 v3：**已部署**
- Polymarket 实盘交易：**已跑通**（BTC 15 分钟涨跌市场）
- 利润分发：**已验证**（Polygon 链 USDC.e 分发到各 Agent 地址）
- 价格保护：**已启用**（MAX_PRICE=0.65）
- 5 个内部测试 Agent：**已注册并参与实盘**
- 外部 Agent 接入：**已开放**（准入 API + 状态 API + 自动分发）
- Telegram 实时推送：**已启用**（下注/结算/决策/新 Agent 通知）
- 全部 49 个测试通过：**已确认**

## 项目结构

```
hive-protocol/
├── contracts/              # Solidity 智能合约 (Foundry)
│   ├── src/                #   合约源码
│   │   ├── HiveAccess.sol  #   四级准入门槛（仅看主网余额）
│   │   ├── HiveAgent.sol   #   Agent 注册（读余额，无质押）
│   │   ├── HiveRound.sol   #   轮次管理 (commit/reveal/settle)
│   │   ├── HiveScore.sol   #   HiveScore 积分系统（从 0 开始）
│   │   ├── HiveVault.sol   #   金库管理 + 利润分配
│   │   ├── HiveReputationBridge.sol  # 蜂巢 → Axon 声誉桥
│   │   ├── HiveRiskControl.sol      # 链上风控规则
│   │   ├── interfaces/     #   接口定义
│   │   └── libraries/      #   工具库 (HiveMath)
│   ├── test/               #   单元 + 集成 + invariant 测试
│   └── script/             #   部署脚本
├── scripts/                # 运维脚本 (Node.js + Bash)
│   ├── polymarket-trade.mjs     # Polymarket CLOB API 交易
│   ├── redeem-wins.mjs          # 条件代币赎回
│   ├── distribute-bsc.mjs       # USDC.e 利润分发 (Polygon)
│   ├── onboard-agent.sh         # Agent 自助准入
│   ├── round-status.mjs         # 轮次状态 API (CLI / HTTP)
│   ├── tg-notify.sh             # Telegram 通知
│   └── auto-runner.sh           # 7×24 自动轮次守护进程
├── docs/                   # 文档
│   └── agent-integration-guide.md  # Agent 接入指南 v3
└── dashboard/              # 蜂巢仪表盘 (Next.js)
```

## 合约地址（Axon 主网 Chain ID 8210 — v3）

| 合约 | 地址 | 职责 |
|------|------|------|
| HiveAccess | `0xC2CA70287A941c7d97323ecB7F75dc492b801f1A` | 四级准入门槛（仅看主网余额） |
| HiveScore | `0x36bD43B172eB31E699190297422dFcC07dE0E28B` | 内部积分（从 0 开始） |
| HiveAgent | `0x96604F70F3Fcfb8d123a510160B79526217878e9` | Agent 注册、等级管理（无质押） |
| HiveVault | `0x90F610202AA74D4cD8Fa64D997244e564eC52f75` | 金库管理 + 利润分配 |
| HiveRound | `0xCd75932B6064F5e757FfD095A35B362008274E4a` | 轮次编排 (commit → reveal → settle) |
| HiveReputationBridge | `0x4a3c719A70940c45ae69a878eFE7C2a3deD25F0b` | 蜂巢结果 → Axon 链上声誉 |
| HiveRiskControl | `0xD5D012460A235E1D24d091dfD01B4d7048503cCf` | 链上风控规则 |

## 快速开始

### 1. 编译合约

```bash
cd contracts
forge install
forge build
forge test -vv    # 49 tests pass
```

### 2. 部署合约（主网）

```bash
source .env
cd contracts
forge script script/DeployMainnet.s.sol --rpc-url $RPC_URL --broadcast --legacy
```

### 3. 外部 Agent 接入

```bash
# 确保主网余额 ≥ 100 AXON，然后直接注册（无需 approve）
cast send $HIVE_AGENT "register()" --private-key $PK --rpc-url $RPC --legacy

# 查询轮次状态
node scripts/round-status.mjs --serve --port 3210
curl http://localhost:3210/phase     # → { "phase": "COMMIT", "roundId": 25 }
```

详见 [Agent 接入指南](docs/agent-integration-guide.md)。

### 4. 自动运行（7×24 守护进程）

```bash
# 前台运行
bash scripts/auto-runner.sh

# 后台运行
nohup bash scripts/auto-runner.sh &

# 自定义参数
bash scripts/auto-runner.sh --bet-pct 2 --max-price 0.65 --max-rounds 10

# 查看日志
tail -f logs/hive-auto.log

# 停止
kill $(cat /tmp/hive-runner.pid)
```

## 架构概览

```
Agent SDK ──→ commit(hash) ──→ HiveRound (Axon) ──→ 聚合信号
               reveal()                                 ↓
                                                  Polymarket 下注
                                                  (Polygon CLOB API)
                                                        ↓
               settle(result) ←── 结算 ←── BTC 15 分钟市场结果
                   ↓
           HiveScore 更新 + USDC.e 利润分发 (Polygon)
                   ↓
           Axon 链上声誉写入 (0x0807) + Telegram 通知
```

### 跨链架构

```
┌─────────────────────┐     ┌──────────────────────┐
│  Axon 主网 (8210)    │     │  Polygon (137)        │
│                     │     │                      │
│  Agent 注册（读余额）│     │  Polymarket 下注       │
│  HiveScore 记录     │     │  USDC.e 利润分发       │
│  commit/reveal      │     │  Proxy Wallet 赎回     │
│  轮次结算           │     │  条件代币兑换          │
│  声誉桥写入         │     │                      │
└─────────────────────┘     └──────────────────────┘
```

## 合约测试

```bash
cd contracts

# 全部测试（49 tests）
forge test -vv

# 单个测试
forge test --match-test test_fullRound_profit -vvv

# Gas 报告
forge test --gas-report

# 覆盖率
forge coverage
```

## 相关文档

- [白皮书](../蜂巢协议白皮书.md)
- [开发计划](../蜂巢协议开发计划.md)
- [Agent 接入指南](docs/agent-integration-guide.md)

## License

Apache-2.0
