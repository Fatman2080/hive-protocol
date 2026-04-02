// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import {IHiveAgent} from "./interfaces/IHiveAgent.sol";
import {HiveTypes} from "./interfaces/IHiveTypes.sol";
import {HiveAccess} from "./HiveAccess.sol";
import {HiveScore} from "./HiveScore.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

/// @title HiveAgent — Agent 注册与等级管理（无质押）
/// @notice 不持有 Agent 任何代币。通过读取主网 AXON 余额判定等级，
///         协议内部 HiveScore 从 0 开始，靠预测表现积累。
contract HiveAgent is IHiveAgent, AccessControl {
    HiveAccess public immutable accessControl;
    HiveScore public immutable hiveScore;

    struct AgentState {
        bool isActive;
        HiveTypes.Tier tier;
        uint256 registeredAt;
        uint256 dailyRoundsUsed;
        uint256 lastRoundDay;
    }

    mapping(address => AgentState) private _agents;
    address[] private _activeAgents;

    constructor(address admin, address accessControl_, address hiveScore_) {
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        accessControl = HiveAccess(accessControl_);
        hiveScore = HiveScore(hiveScore_);
    }

    // ─── 注册（开放，读主网余额）────────────────────────

    function register() external {
        require(!_agents[msg.sender].isActive, "HiveAgent: already registered");

        HiveTypes.Tier tier = accessControl.calculateTier(msg.sender.balance);
        require(tier != HiveTypes.Tier.NONE, "HiveAgent: balance below 100 AXON");

        _agents[msg.sender] = AgentState({
            isActive: true,
            tier: tier,
            registeredAt: block.timestamp,
            dailyRoundsUsed: 0,
            lastRoundDay: 0
        });
        _activeAgents.push(msg.sender);

        emit AgentRegistered(msg.sender, msg.sender.balance, tier);
    }

    // ─── 退出（即时）───────────────────────────────────

    function deregister() external {
        require(_agents[msg.sender].isActive, "HiveAgent: not active");
        _agents[msg.sender].isActive = false;
        emit AgentDeregistered(msg.sender);
    }

    // ─── 每轮刷新等级（余额可能变化）─────────────────

    function refreshTier(address agent) external {
        AgentState storage a = _agents[agent];
        if (!a.isActive) return;

        HiveTypes.Tier newTier = accessControl.calculateTier(agent.balance);
        if (newTier == HiveTypes.Tier.NONE) {
            a.isActive = false;
            emit AgentDeregistered(agent);
            return;
        }
        if (newTier != a.tier) {
            HiveTypes.Tier oldTier = a.tier;
            a.tier = newTier;
            emit TierChanged(agent, oldTier, newTier);
        }
    }

    // ─── 每日轮次计数（由 HiveRound 调用）──────────────

    function recordRoundParticipation(address agent) external onlyRole(DEFAULT_ADMIN_ROLE) {
        AgentState storage a = _agents[agent];
        uint256 today = block.timestamp / 1 days;
        if (a.lastRoundDay != today) {
            a.dailyRoundsUsed = 0;
            a.lastRoundDay = today;
        }
        a.dailyRoundsUsed++;
    }

    function canParticipateToday(address agent) external view returns (bool) {
        AgentState storage a = _agents[agent];
        uint256 today = block.timestamp / 1 days;
        uint256 used = a.lastRoundDay == today ? a.dailyRoundsUsed : 0;
        uint256 cap = accessControl.dailyRoundCap(a.tier);
        return used < cap;
    }

    // ─── 只读 ──────────────────────────────────────────

    function getProfile(address agent) external view returns (HiveTypes.AgentProfile memory) {
        AgentState storage a = _agents[agent];
        HiveScore.ScoreData memory sd = hiveScore.getFullStats(agent);

        return HiveTypes.AgentProfile({
            isActive: a.isActive,
            tier: a.tier,
            axonBalance: agent.balance,
            hiveScore: sd.score,
            totalRounds: sd.totalRounds,
            correctRounds: sd.correctRounds,
            currentStreak: sd.streak,
            bestStreak: sd.bestStreak,
            registeredAt: a.registeredAt
        });
    }

    function isActive(address agent) external view returns (bool) {
        return _agents[agent].isActive;
    }

    function getStake(address agent) external view returns (uint256) {
        return agent.balance;
    }

    function getTier(address agent) external view returns (HiveTypes.Tier) {
        return _agents[agent].tier;
    }

    function activeAgentCount() external view returns (uint256) {
        uint256 count = 0;
        for (uint256 i = 0; i < _activeAgents.length; i++) {
            if (_agents[_activeAgents[i]].isActive) count++;
        }
        return count;
    }
}
