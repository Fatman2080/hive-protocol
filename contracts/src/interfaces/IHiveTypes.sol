// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

/// @title IHiveTypes — 蜂巢协议全局类型定义
library HiveTypes {
    enum Prediction {
        UP,
        DOWN
    }

    enum RoundPhase {
        IDLE,
        COMMIT,
        REVEAL,
        SETTLED
    }

    enum Tier {
        NONE,
        BRONZE,
        SILVER,
        GOLD,
        DIAMOND
    }

    struct TierConfig {
        uint256 minBalance;     // 主网最低 AXON 余额
        uint8 maxConfidence;
        uint256 dailyRoundCap;
    }

    struct AgentProfile {
        bool isActive;
        Tier tier;
        uint256 axonBalance;    // 主网余额（只读）
        uint256 hiveScore;      // 协议内部积分
        uint256 totalRounds;
        uint256 correctRounds;
        int256 currentStreak;
        uint256 bestStreak;
        uint256 registeredAt;
    }

    struct RoundData {
        RoundPhase phase;
        uint256 openPrice;
        uint256 closePrice;
        uint256 upWeight;
        uint256 downWeight;
        uint256 participantCount;
        uint256 betAmount;
        int256 profitLoss;
        uint256 startTime;
    }

    struct CommitInfo {
        bytes32 commitHash;
        bool revealed;
        Prediction prediction;
        uint8 confidence;
        uint256 weight;
    }
}
