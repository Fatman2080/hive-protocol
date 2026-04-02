// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import {HiveTypes} from "./interfaces/IHiveTypes.sol";
import {IHiveAccess} from "./interfaces/IHiveAccess.sol";

/// @title HiveAccess — 四级准入门槛
/// @notice 纯计算合约，无状态。外部合约调用 calculateTier 判定等级。
///
/// 等级体系：
///   青铜 BRONZE  — 声誉 ≥ 10,  质押 ≥ 100 AXON  — 信心度上限 70,  日限 30 轮
///   白银 SILVER  — 声誉 ≥ 30,  质押 ≥ 500 AXON  — 信心度上限 85,  日限 50 轮
///   黄金 GOLD    — 声誉 ≥ 60,  质押 ≥ 2000 AXON — 信心度上限 95,  日限 80 轮
///   钻石 DIAMOND — 声誉 ≥ 100, 质押 ≥ 5000 AXON — 信心度上限 100, 日限 96 轮
contract HiveAccess is IHiveAccess {
    function checkAccess(address) external pure returns (bool, HiveTypes.Tier) {
        revert("HiveAccess: use calculateTier with reputation and stake");
    }

    function getTierConfig(HiveTypes.Tier tier) external pure returns (HiveTypes.TierConfig memory) {
        return _tierConfig(tier);
    }

    function calculateTier(uint256 reputation, uint256 stake) external pure returns (HiveTypes.Tier) {
        return _calculateTier(reputation, stake);
    }

    function maxAllowedConfidence(HiveTypes.Tier tier) external pure returns (uint8) {
        return _tierConfig(tier).maxConfidence;
    }

    function dailyRoundCap(HiveTypes.Tier tier) external pure returns (uint256) {
        return _tierConfig(tier).dailyRoundCap;
    }

    // ─── Internal ────────────────────────────────────────────

    function _calculateTier(uint256 reputation, uint256 stake) internal pure returns (HiveTypes.Tier) {
        // stake 以 1e18 为单位，比较时转换
        uint256 stakeUnits = stake / 1e18;

        if (reputation >= 100 && stakeUnits >= 5000) return HiveTypes.Tier.DIAMOND;
        if (reputation >= 60 && stakeUnits >= 2000) return HiveTypes.Tier.GOLD;
        if (reputation >= 30 && stakeUnits >= 500) return HiveTypes.Tier.SILVER;
        if (reputation >= 10 && stakeUnits >= 100) return HiveTypes.Tier.BRONZE;
        return HiveTypes.Tier.NONE;
    }

    function _tierConfig(HiveTypes.Tier tier) internal pure returns (HiveTypes.TierConfig memory) {
        if (tier == HiveTypes.Tier.BRONZE) return HiveTypes.TierConfig(10, 100e18, 70, 30);
        if (tier == HiveTypes.Tier.SILVER) return HiveTypes.TierConfig(30, 500e18, 85, 50);
        if (tier == HiveTypes.Tier.GOLD) return HiveTypes.TierConfig(60, 2000e18, 95, 80);
        if (tier == HiveTypes.Tier.DIAMOND) return HiveTypes.TierConfig(100, 5000e18, 100, 96);
        return HiveTypes.TierConfig(0, 0, 0, 0);
    }
}
