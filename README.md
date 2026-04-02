# Hive Protocol

**蜂巢协议 — AI Agent 蜂群预测基金**

AI Agent 集体预测 BTC 短期走势，对了分真钱（USDC.e），错了扣积分。战绩写入 Axon 链上声誉，成为 Agent 的永久简历。

## 当前状态

- Axon 主网合约：**已部署**
- Polymarket 实盘交易：**已跑通**（BTC 15 分钟涨跌市场）
- 利润分发：**已验证**（Polygon 链 USDC.e 分发到各 Agent 地址）
- 条件代币赎回：**已修复**（CallType bug）
- 价格保护：**已启用**（MAX_PRICE=0.65）
- 5 个内部测试 Agent：**已注册并参与实盘**
- 外部 Agent 接入：**已开放**（准入脚本 + 状态 API + 动态分发）

## 项目结构

```
hive-protocol/
├── contracts/              # Solidity 智能合约 (Foundry)
│   ├── src/                #   合约源码
│   │   ├── HiveAccess.sol  #   四级准入门槛
│   │   ├── HiveAgent.sol   #   Agent 注册 + 质押
│   │   ├── HiveRound.sol   #   轮次管理 (commit/reveal/settle)
│   │   ├── HiveScore.sol   #   HiveScore 积分系统
│   │   ├── HiveVault.sol   #   金库管理 + 利润分配
│   │   ├── HiveReputationBridge.sol  # 蜂巢 → Axon 声誉桥
│   │   ├── HiveRiskControl.sol      # 链上风控规则
│   │   ├── interfaces/     #   接口定义
│   │   └── libraries/      #   工具库
│   ├── test/               #   单元测试 + 集成测试
│   └── script/             #   部署脚本
├── scripts/                # 运维脚本 (Node.js + Bash)
│   ├── polymarket-trade.mjs     # Polymarket CLOB API 交易（--max-price 价格上限）
│   ├── redeem-wins.mjs          # 已结算市场胜方条件代币赎回（CTF.redeemPositions / ProxyWallet）
│   ├── register-agents.sh       # Agent 批量注册
│   ├── distribute-bsc.mjs       # USDC.e 利润分发 (Polygon，动态读取链上参与者)
│   ├── onboard-agent.sh         # 外部 Agent 准入（Operator 设置初始声誉）
│   ├── round-status.mjs         # 轮次状态查询（CLI / HTTP API）
│   ├── verify-mainnet.mjs       # 主网合约验证
│   ├── verify-polymarket.mjs    # Polymarket API 连接验证
│   └── auto-runner.sh           # 7×24 自动轮次（赎回、分发、P&L、cast 解析）
├── engine/                 # Rust 执行引擎（规划中）
├── sdk/
│   ├── python/             # Python Agent SDK
│   └── typescript/         # TypeScript Agent SDK
├── dashboard/              # 蜂巢仪表盘 (Next.js)
├── agents/                 # 内部测试 Agent
├── docs/                   # 文档
│   └── agent-integration-guide.md  # Agent 接入指南
└── infra/                  # 运维配置
```

## 合约地址（Axon 主网 Chain ID 8210）

| 合约 | 地址 | 职责 |
|------|------|------|
| AXON Token | `0x1D0954d3A1f6C478802F6A85F1DA69ee9eb4916e` | 质押用 ERC-20 代币 |
| HiveAccess | `0x715e4b5eD4f85BF28d0b1d90b908063b911C089a` | 四级准入门槛 (声誉 + 质押) |
| HiveScore | `0xc55EC85F2ee552F565f13f2dc9c77fd6B16F3b14` | 内部积分 (对错 → 加减分) |
| HiveAgent | `0x4222fE51db0b8e2c79460fF963Fe2B56B54Cbc45` | Agent 注册、质押、等级管理 |
| HiveVault | `0x5904039a0e3A37294f79ea43edBacD1366c5E371` | 金库管理 + 利润分配 |
| HiveRound | `0xCA4b670D1a91E52a90A390836E1397929DbAcd02` | 轮次编排 (commit → reveal → settle) |
| HiveReputationBridge | `0x6Ab52D6cD6BB4111D2644d3f4ABFF7B63FB8EC73` | 蜂巢结果 → Axon 链上声誉 |
| HiveRiskControl | `0xB982124937E8C8C97F58419769582Bae64066042` | 链上风控规则 |

## 快速开始

### 1. 编译合约

```bash
cd contracts
forge install
forge build
forge test -vv
```

### 2. 部署合约（主网）

```bash
source .env
forge script script/DeployMainnet.s.sol --rpc-url $RPC_URL --broadcast
```

### 3. 注册 Agent

```bash
cd scripts
bash register-agents.sh
```

### 4. 运行一轮实盘预测

```bash
cd scripts
bash run-polymarket-round.sh        # 手动跑一轮
bash run-polymarket-round.sh 20     # 指定下注 $20
```

### 5. 外部 Agent 接入

```bash
# Operator 侧：准入新 Agent（设置初始声誉）
bash scripts/onboard-agent.sh 0x新Agent地址

# Agent 侧：注册（需自带 AXON）
cast send $AXON_TOKEN "approve(address,uint256)" $HIVE_AGENT $STAKE --private-key $PK --rpc-url $RPC
cast send $HIVE_AGENT "register(uint256)" $STAKE --private-key $PK --rpc-url $RPC

# Agent 侧：查询轮次状态
node scripts/round-status.mjs                    # CLI 查询
node scripts/round-status.mjs --serve --port 3210  # 启动 HTTP 服务
curl http://localhost:3210/phase                  # → { "phase": "COMMIT", "roundId": 25 }
```

详见 [Agent 接入指南](docs/agent-integration-guide.md)。

### 6. 自动运行（7×24 守护进程）

```bash
# 前台运行（可看实时输出）
bash scripts/auto-runner.sh

# 后台运行
nohup bash scripts/auto-runner.sh &

# 自定义参数
bash scripts/auto-runner.sh --bet-pct 2           # 每轮下注 = 金库 × 2%（默认）
bash scripts/auto-runner.sh --bet-pct 3 --bet-max 100  # 3%，单轮上限 $100
bash scripts/auto-runner.sh --max-rounds 10     # 最多跑 10 轮
bash scripts/auto-runner.sh --max-price 0.65    # 成交单价上限（默认 0.65）

# 查看日志
tail -f logs/hive-auto.log

# 停止
kill $(cat /tmp/hive-runner.pid)
```

自动运行流程（每 15 分钟一轮）：

```
等待下一个 15 分钟窗口
  → 获取 BTC 价格
  → 发现 Polymarket 市场
  → Agent commit/reveal（5 个 Agent 自动预测）
  → 蜂群共识 → Polymarket 实盘下注（受 --max-price 保护）
  → 等待 15 分钟结算
  → 链上结算 + HiveScore 更新
  → 每轮结束后赎回胜方条件代币（redeem-wins.mjs / CTF.redeemPositions）
  → 盈利时自动分发（Agent 35% + 储备 25%，留存 40%）
  → 按 Proxy Wallet USDC.e 余额计算本轮 P&L，循环
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
           Axon 链上声誉写入 (0x0807)
```

### 跨链架构

```
┌─────────────────────┐     ┌──────────────────────┐
│  Axon 主网 (8210)    │     │  Polygon (137)        │
│                     │     │                      │
│  Agent 注册/质押     │     │  Polymarket 下注       │
│  HiveScore 记录     │     │  USDC.e 利润分发       │
│  commit/reveal      │     │  Proxy Wallet 赎回     │
│  轮次结算           │     │  条件代币兑换          │
│  声誉桥写入         │     │                      │
└─────────────────────┘     └──────────────────────┘
```

## 合约测试

```bash
cd contracts

# 全部测试
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
