// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

/// @title HiveRiskControl — 链上风控规则
/// @notice 独立的风控合约，HiveVault 和 HiveRound 在执行前检查。
///         任一多签持有人可触发紧急暂停。
///
/// 风控规则：
///   - 单轮下注 ≤ 金库 2%（硬编码在 HiveVault）
///   - 日亏损 ≥ 8% → 当日熔断
///   - 周亏损 ≥ 15% → 暂停 48 小时
///   - 连败 ≥ 5 次 → 暂停 3 轮
///   - 紧急暂停（任一 PAUSER 可触发）
contract HiveRiskControl is AccessControl {
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    struct DailyStats {
        uint256 date;       // block.timestamp / 1 days
        int256 pnl;         // 当日累计盈亏
        uint256 rounds;     // 当日已跑轮次
        uint256 losses;     // 当日亏损轮次
    }

    struct WeeklyStats {
        uint256 weekStart;  // 周一 timestamp
        int256 pnl;
    }

    uint256 public constant DAILY_LOSS_LIMIT_BPS = 800;   // 8%
    uint256 public constant WEEKLY_LOSS_LIMIT_BPS = 1500;  // 15%
    uint256 public constant CONSECUTIVE_LOSS_PAUSE = 5;
    uint256 public constant PAUSE_ROUNDS = 3;

    DailyStats public dailyStats;
    WeeklyStats public weeklyStats;

    uint256 public consecutiveLosses;
    uint256 public pausedUntilRound;  // 暂停到哪一轮
    bool public emergencyPaused;
    uint256 public pausedUntilTimestamp; // 时间维度暂停

    uint256 public referenceBalance; // 风控参考金库余额（每日更新）

    event DailyCircuitBreaker(uint256 date, int256 dailyPnl, uint256 limitBps);
    event WeeklyCircuitBreaker(uint256 weekStart, int256 weeklyPnl, uint256 limitBps);
    event ConsecutiveLossPause(uint256 losses, uint256 pauseRounds);
    event EmergencyPause(address indexed pauser, string reason);
    event EmergencyResume(address indexed admin);
    event RiskCheckPassed(uint256 roundId);

    constructor(address admin) {
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(OPERATOR_ROLE, admin);
        _grantRole(PAUSER_ROLE, admin);
    }

    /// @notice 每轮开始前检查是否允许下注
    function canProceed(uint256 roundId) external view returns (bool allowed, string memory reason) {
        if (emergencyPaused) return (false, "emergency paused");
        if (block.timestamp < pausedUntilTimestamp) return (false, "time-based pause active");
        if (roundId <= pausedUntilRound) return (false, "consecutive loss pause");
        if (_isDailyLimitHit()) return (false, "daily loss limit");
        if (_isWeeklyLimitHit()) return (false, "weekly loss limit");
        return (true, "");
    }

    /// @notice 记录一轮结果（由 operator 在结算后调用）
    function recordResult(uint256 roundId, int256 pnl, uint256 currentBalance)
        external
        onlyRole(OPERATOR_ROLE)
    {
        _updateDaily(pnl);
        _updateWeekly(pnl);

        referenceBalance = currentBalance;

        if (pnl < 0) {
            consecutiveLosses++;
            if (consecutiveLosses >= CONSECUTIVE_LOSS_PAUSE) {
                pausedUntilRound = roundId + PAUSE_ROUNDS;
                emit ConsecutiveLossPause(consecutiveLosses, PAUSE_ROUNDS);
            }
        } else if (pnl > 0) {
            consecutiveLosses = 0;
        }

        // 日熔断
        if (_isDailyLimitHit()) {
            emit DailyCircuitBreaker(dailyStats.date, dailyStats.pnl, DAILY_LOSS_LIMIT_BPS);
        }

        // 周熔断
        if (_isWeeklyLimitHit()) {
            pausedUntilTimestamp = block.timestamp + 48 hours;
            emit WeeklyCircuitBreaker(weeklyStats.weekStart, weeklyStats.pnl, WEEKLY_LOSS_LIMIT_BPS);
        }
    }

    /// @notice 紧急暂停（任一 PAUSER 可触发）
    function emergencyPause(string calldata reason) external onlyRole(PAUSER_ROLE) {
        emergencyPaused = true;
        emit EmergencyPause(msg.sender, reason);
    }

    /// @notice 解除紧急暂停（仅 admin）
    function emergencyResume() external onlyRole(DEFAULT_ADMIN_ROLE) {
        emergencyPaused = false;
        consecutiveLosses = 0;
        emit EmergencyResume(msg.sender);
    }

    /// @notice 更新参考余额（每日由 operator 调用）
    function updateReferenceBalance(uint256 balance) external onlyRole(OPERATOR_ROLE) {
        referenceBalance = balance;
    }

    // ─── Internal ────────────────────────────────────────

    function _updateDaily(int256 pnl) internal {
        uint256 today = block.timestamp / 1 days;
        if (dailyStats.date != today) {
            dailyStats = DailyStats({date: today, pnl: 0, rounds: 0, losses: 0});
        }
        dailyStats.pnl += pnl;
        dailyStats.rounds++;
        if (pnl < 0) dailyStats.losses++;
    }

    function _updateWeekly(int256 pnl) internal {
        uint256 weekStart = _getWeekStart();
        if (weeklyStats.weekStart != weekStart) {
            weeklyStats = WeeklyStats({weekStart: weekStart, pnl: 0});
        }
        weeklyStats.pnl += pnl;
    }

    function _isDailyLimitHit() internal view returns (bool) {
        if (referenceBalance == 0) return false;
        uint256 today = block.timestamp / 1 days;
        if (dailyStats.date != today) return false;
        if (dailyStats.pnl >= 0) return false;
        // safe: pnl < 0 已检查，取反不会溢出（int256.min 不可能出现在正常 PnL 中）
        uint256 loss = uint256(-dailyStats.pnl);
        return (loss * 10000) / referenceBalance >= DAILY_LOSS_LIMIT_BPS;
    }

    function _isWeeklyLimitHit() internal view returns (bool) {
        if (referenceBalance == 0) return false;
        uint256 weekStart = _getWeekStart();
        if (weeklyStats.weekStart != weekStart) return false;
        if (weeklyStats.pnl >= 0) return false;
        uint256 loss = uint256(-weeklyStats.pnl);
        return (loss * 10000) / referenceBalance >= WEEKLY_LOSS_LIMIT_BPS;
    }

    function _getWeekStart() internal view returns (uint256) {
        // 将 timestamp 对齐到本周一 00:00 UTC
        uint256 daysSinceEpoch = block.timestamp / 1 days;
        uint256 dayOfWeek = (daysSinceEpoch + 3) % 7; // 0=Mon
        return (daysSinceEpoch - dayOfWeek) * 1 days;
    }

    // ─── 只读 ────────────────────────────────────────────

    function getDailyStats() external view returns (int256 pnl, uint256 rounds, uint256 losses) {
        uint256 today = block.timestamp / 1 days;
        if (dailyStats.date != today) return (0, 0, 0);
        return (dailyStats.pnl, dailyStats.rounds, dailyStats.losses);
    }

    function getWeeklyPnl() external view returns (int256) {
        uint256 weekStart = _getWeekStart();
        if (weeklyStats.weekStart != weekStart) return 0;
        return weeklyStats.pnl;
    }
}
