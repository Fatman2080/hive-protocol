// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import {HiveTypes} from "./IHiveTypes.sol";

/// @title IHiveAccess — 准入控制接口
/// @notice 四级准入门槛（青铜/白银/黄金/钻石），基于链上声誉 + 质押量
interface IHiveAccess {
    /// @notice 检查 Agent 是否满足参与条件
    function checkAccess(address agent) external view returns (bool allowed, HiveTypes.Tier tier);

    /// @notice 查询各等级门槛配置
    function getTierConfig(HiveTypes.Tier tier) external pure returns (HiveTypes.TierConfig memory);

    /// @notice 根据声誉 + 质押计算 Agent 等级
    function calculateTier(uint256 reputation, uint256 stake) external pure returns (HiveTypes.Tier);

    /// @notice 查询某等级允许的最大信心度
    function maxAllowedConfidence(HiveTypes.Tier tier) external pure returns (uint8);

    /// @notice 查询某等级的每日轮次上限
    function dailyRoundCap(HiveTypes.Tier tier) external pure returns (uint256);
}
