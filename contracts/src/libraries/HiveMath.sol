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

    /// @notice 计算 Agent 权重 = effectiveScore × confidence × sqrt(balance)
    /// @param hiveScore 协议内部积分（从 0 开始）；为 0 时按 1 计，避免首轮无法产生信号
    /// @param confidence 信心度 1-100
    /// @param balance 主网 AXON 余额（18 decimals）
    function calcWeight(uint256 hiveScore, uint8 confidence, uint256 balance) internal pure returns (uint256) {
        uint256 s = hiveScore == 0 ? 1 : hiveScore;
        uint256 sqrtBal = sqrt(balance / 1e18);
        if (sqrtBal == 0) sqrtBal = 1;
        return s * uint256(confidence) * sqrtBal;
    }
}
