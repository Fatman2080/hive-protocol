// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

/// @title HiveMath — 蜂巢协议数学工具
library HiveMath {
    /// @notice 整数平方根（Babylonian method）
    function sqrt(uint256 x) internal pure returns (uint256) {
        if (x == 0) return 0;
        uint256 z = (x + 1) / 2;
        uint256 y = x;
        while (z < y) {
            y = z;
            z = (x / z + z) / 2;
        }
        return y;
    }

    /// @notice 计算 Agent 权重 = hiveScore × confidence × sqrt(stake)
    /// @dev stake 以 1e18 为单位（ERC20 decimals），先做 sqrt 再归一化
    function calcWeight(uint256 hiveScore, uint8 confidence, uint256 stake) internal pure returns (uint256) {
        uint256 sqrtStake = sqrt(stake / 1e18);
        if (sqrtStake == 0) sqrtStake = 1;
        return hiveScore * uint256(confidence) * sqrtStake;
    }

    /// @notice 基于信心度计算质押冻结比例 (basis points)
    ///   confidence ≤ 30  → 0 bps
    ///   confidence 31-60 → 100 bps (1%)
    ///   confidence 61-80 → 300 bps (3%)
    ///   confidence 81-100→ 500 bps (5%)
    function freezeBps(uint8 confidence) internal pure returns (uint256) {
        if (confidence <= 30) return 0;
        if (confidence <= 60) return 100;
        if (confidence <= 80) return 300;
        return 500;
    }
}
