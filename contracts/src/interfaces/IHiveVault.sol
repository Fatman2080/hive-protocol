// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

/// @title IHiveVault — 金库管理接口
/// @notice 管理 USDT 资金池：下注额度、利润分配、风险准备金
interface IHiveVault {
    event ProfitDistributed(uint256 indexed roundId, uint256 agentPool, uint256 retained, uint256 buyback, uint256 reserve, uint256 ops);
    event TransferDeferred(uint256 indexed roundId, address indexed to, uint256 amount, string reason);
    event LossRecorded(uint256 indexed roundId, uint256 amount);
    event AgentClaimed(address indexed agent, uint256 amount);
    event ReserveUsed(uint256 amount);
    event Deposited(address indexed from, uint256 amount);

    /// @notice 金库总余额（不含风险准备金）
    function treasuryBalance() external view returns (uint256);

    /// @notice 风险准备金余额
    function reserveBalance() external view returns (uint256);

    /// @notice 计算本轮下注额度（金库 × 2%）
    function currentBetSize() external view returns (uint256);

    /// @notice 记录盈利并按比例分配（仅 HiveRound 调用）
    /// @param roundId 轮次 ID
    /// @param agents 正确方 Agent 地址列表
    /// @param weights 正确方 Agent 权重列表（与 agents 一一对应）
    /// @param profit 本轮净利润
    function distributeProfit(uint256 roundId, address[] calldata agents, uint256[] calldata weights, uint256 profit)
        external;

    /// @notice 记录亏损（仅 HiveRound 调用）
    function recordLoss(uint256 roundId, uint256 amount) external;

    /// @notice Agent 领取累计收益
    function claim() external;

    /// @notice 查询 Agent 可领取收益
    function pendingReward(address agent) external view returns (uint256);

    /// @notice 项目方/社区向金库注资
    function deposit(uint256 amount) external;
}
