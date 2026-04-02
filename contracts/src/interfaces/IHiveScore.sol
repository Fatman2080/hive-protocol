// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

/// @title IHiveScore — 蜂巢内部积分接口
/// @notice 仅基于预测对错计算积分，不引用链上声誉
interface IHiveScore {
    event ScoreUpdated(address indexed agent, uint256 newScore, int256 delta, bool correct);
    event StreakUpdated(address indexed agent, int256 newStreak);

    /// @notice 更新 Agent 积分（仅由 HiveRound 在结算时调用）
    /// @param agent Agent 地址
    /// @param correct 本轮是否预测正确
    /// @param confidence 本轮信心度
    function updateScore(address agent, bool correct, uint8 confidence) external;

    /// @notice 查询 HiveScore
    function getScore(address agent) external view returns (uint256);

    /// @notice 查询连胜/连败
    function getStreak(address agent) external view returns (int256);

    /// @notice 查询胜率（返回 basis points, 6500 = 65.00%）
    function getWinRate(address agent) external view returns (uint256 rateBps, uint256 totalRounds);

    /// @notice 查询排行榜
    function getLeaderboard(uint256 count)
        external
        view
        returns (address[] memory agents, uint256[] memory scores);
}
