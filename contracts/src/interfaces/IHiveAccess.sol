// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import {HiveTypes} from "./IHiveTypes.sol";

/// @title IHiveAccess — 准入控制接口（基于主网余额）
interface IHiveAccess {
    /// @notice 根据主网余额计算 Agent 等级
    function calculateTier(uint256 balance) external pure returns (HiveTypes.Tier);

    /// @notice 查询各等级门槛配置
    function getTierConfig(HiveTypes.Tier tier) external pure returns (HiveTypes.TierConfig memory);

    /// @notice 查询某等级允许的最大信心度
    function maxAllowedConfidence(HiveTypes.Tier tier) external pure returns (uint8);

    /// @notice 查询某等级的每日轮次上限
    function dailyRoundCap(HiveTypes.Tier tier) external pure returns (uint256);
}
