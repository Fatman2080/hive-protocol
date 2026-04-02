// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import {HiveTypes} from "./interfaces/IHiveTypes.sol";
import {IHiveAccess} from "./interfaces/IHiveAccess.sol";

/// @title HiveAccess — 四级准入门槛（基于主网 AXON 余额）
///
/// 等级体系：
///   青铜 BRONZE  — 余额 ≥ 100 AXON  — 信心度上限 70,  日限 30 轮
///   白银 SILVER  — 余额 ≥ 500 AXON  — 信心度上限 85,  日限 50 轮
///   黄金 GOLD    — 余额 ≥ 2000 AXON — 信心度上限 95,  日限 80 轮
///   钻石 DIAMOND — 余额 ≥ 5000 AXON — 信心度上限 100, 日限 96 轮
contract HiveAccess is IHiveAccess {
    function calculateTier(uint256 balance) external pure returns (HiveTypes.Tier) {
        return _calculateTier(balance);
    }

    function getTierConfig(HiveTypes.Tier tier) external pure returns (HiveTypes.TierConfig memory) {
        return _tierConfig(tier);
    }

    function maxAllowedConfidence(HiveTypes.Tier tier) external pure returns (uint8) {
        return _tierConfig(tier).maxConfidence;
    }

    function dailyRoundCap(HiveTypes.Tier tier) external pure returns (uint256) {
        return _tierConfig(tier).dailyRoundCap;
    }

    function _calculateTier(uint256 balance) internal pure returns (HiveTypes.Tier) {
        uint256 units = balance / 1e18;
        if (units >= 5000) return HiveTypes.Tier.DIAMOND;
        if (units >= 2000) return HiveTypes.Tier.GOLD;
        if (units >= 500)  return HiveTypes.Tier.SILVER;
        if (units >= 100)  return HiveTypes.Tier.BRONZE;
        return HiveTypes.Tier.NONE;
    }

    function _tierConfig(HiveTypes.Tier tier) internal pure returns (HiveTypes.TierConfig memory) {
        if (tier == HiveTypes.Tier.BRONZE)  return HiveTypes.TierConfig(100e18,  70, 30);
        if (tier == HiveTypes.Tier.SILVER)  return HiveTypes.TierConfig(500e18,  85, 50);
        if (tier == HiveTypes.Tier.GOLD)    return HiveTypes.TierConfig(2000e18, 95, 80);
        if (tier == HiveTypes.Tier.DIAMOND) return HiveTypes.TierConfig(5000e18, 100, 96);
        return HiveTypes.TierConfig(0, 0, 0);
    }
}
