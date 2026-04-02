// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import {HiveTypes} from "./IHiveTypes.sol";

/// @title IHiveRound — 轮次管理接口
/// @notice commit-reveal 预测 → 信号聚合 → 结算分润
interface IHiveRound {
    event RoundStarted(uint256 indexed roundId, uint256 openPrice, uint256 startTime);
    event PredictionCommitted(uint256 indexed roundId, address indexed agent);
    event PredictionRevealed(uint256 indexed roundId, address indexed agent, HiveTypes.Prediction prediction, uint8 confidence);
    event RoundSettled(uint256 indexed roundId, HiveTypes.Prediction result, int256 profitLoss, uint256 correctCount);
    event RoundSkipped(uint256 indexed roundId, string reason);

    /// @notice 开启新轮次（仅 operator）
    function startRound(uint256 openPrice) external returns (uint256 roundId);

    /// @notice Agent 提交加密预测
    function commit(uint256 roundId, bytes32 commitHash) external;

    /// @notice Agent 揭示预测
    function reveal(uint256 roundId, HiveTypes.Prediction prediction, uint8 confidence, bytes32 salt) external;

    /// @notice 结算轮次（仅 operator）
    function settle(uint256 roundId, uint256 closePrice, int256 profitLoss) external;

    /// @notice 查询轮次数据
    function getRound(uint256 roundId) external view returns (HiveTypes.RoundData memory);

    /// @notice 查询当前轮次 ID
    function currentRoundId() external view returns (uint256);

    /// @notice 查询 Agent 在某轮的 commit 信息
    function getCommit(uint256 roundId, address agent) external view returns (HiveTypes.CommitInfo memory);
}
