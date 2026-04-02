// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import {IHiveScore} from "./interfaces/IHiveScore.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

/// @title HiveScore — 蜂巢内部积分系统
/// @notice 仅由 HiveRound 合约在结算时调用 updateScore，外部只读。
///
/// 积分规则：
///   正确 → +(1 + floor(confidence/50))，连胜 ≥ 3 额外 +1
///   错误 → -(1 + floor(confidence/50))，连败 ≥ 5 额外 -1
///   底线 → HiveScore 最低为 0
contract HiveScore is IHiveScore, AccessControl {
    bytes32 public constant ROUND_ROLE = keccak256("ROUND_ROLE");

    struct ScoreData {
        uint256 score;
        uint256 totalRounds;
        uint256 correctRounds;
        int256 streak;
        uint256 bestStreak;
    }

    uint256 public constant INITIAL_SCORE = 50;

    mapping(address => ScoreData) private _scores;

    // 简易排行榜：存储 top-N agent 地址（链下辅助维护更高效，
    // 这里仅提供 getLeaderboard 接口的最小链上实现）
    address[] private _allAgents;
    mapping(address => bool) private _registered;

    constructor(address admin) {
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

    // ─── 写入（仅 HiveRound） ──────────────────────────────

    function updateScore(address agent, bool correct, uint8 confidence) external onlyRole(ROUND_ROLE) {
        ScoreData storage s = _scores[agent];

        if (!_registered[agent]) {
            _registered[agent] = true;
            _allAgents.push(agent);
            s.score = INITIAL_SCORE;
        }

        int256 delta = int256(1 + uint256(confidence) / 50);

        if (correct) {
            s.score += uint256(delta);
            s.correctRounds++;

            if (s.streak >= 0) {
                s.streak++;
            } else {
                s.streak = 1;
            }

            if (s.streak >= 3) {
                s.score += 1; // 连胜加成
            }

            if (uint256(s.streak) > s.bestStreak) {
                s.bestStreak = uint256(s.streak);
            }
        } else {
            uint256 penalty = uint256(delta);
            if (s.streak <= -5) {
                penalty += 1; // 连败加罚
            }
            s.score = s.score > penalty ? s.score - penalty : 0;

            if (s.streak <= 0) {
                s.streak--;
            } else {
                s.streak = -1;
            }
        }

        s.totalRounds++;

        emit ScoreUpdated(agent, s.score, correct ? delta : -delta, correct);
        emit StreakUpdated(agent, s.streak);
    }

    // ─── 只读 ──────────────────────────────────────────────

    function getScore(address agent) external view returns (uint256) {
        if (!_registered[agent]) return INITIAL_SCORE;
        return _scores[agent].score;
    }

    function getStreak(address agent) external view returns (int256) {
        return _scores[agent].streak;
    }

    function getWinRate(address agent) external view returns (uint256 rateBps, uint256 totalRounds) {
        ScoreData storage s = _scores[agent];
        totalRounds = s.totalRounds;
        if (totalRounds == 0) return (0, 0);
        rateBps = (s.correctRounds * 10000) / totalRounds;
    }

    function getFullStats(address agent) external view returns (ScoreData memory) {
        ScoreData memory s = _scores[agent];
        if (!_registered[agent]) {
            s.score = INITIAL_SCORE;
        }
        return s;
    }

    function getLeaderboard(uint256 count)
        external
        view
        returns (address[] memory agents, uint256[] memory scores)
    {
        uint256 len = _allAgents.length;
        if (count > len) count = len;

        // 简单 O(n*k) 选择，链上排行榜仅供小规模使用
        agents = new address[](count);
        scores = new uint256[](count);
        bool[] memory picked = new bool[](len);

        for (uint256 i = 0; i < count; i++) {
            uint256 bestIdx = 0;
            uint256 bestScore = 0;
            for (uint256 j = 0; j < len; j++) {
                if (!picked[j] && _scores[_allAgents[j]].score > bestScore) {
                    bestScore = _scores[_allAgents[j]].score;
                    bestIdx = j;
                }
            }
            picked[bestIdx] = true;
            agents[i] = _allAgents[bestIdx];
            scores[i] = bestScore;
        }
    }
}
