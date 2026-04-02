// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import {IHiveAgent} from "./interfaces/IHiveAgent.sol";
import {HiveTypes} from "./interfaces/IHiveTypes.sol";
import {HiveAccess} from "./HiveAccess.sol";
import {HiveScore} from "./HiveScore.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

/// @title HiveAgent — Agent 注册、质押、等级管理
/// @notice Agent 注册时质押 AXON Token，合约自动根据质押量+链上声誉判定准入等级。
///         退出有 7 天冷却期，防止闪退攻击。
contract HiveAgent is IHiveAgent, AccessControl {
    using SafeERC20 for IERC20;

    uint256 public constant EXIT_COOLDOWN = 7 days;

    IERC20 public immutable axonToken;
    HiveAccess public immutable accessControl;
    HiveScore public immutable hiveScore;

    struct AgentState {
        bool isActive;
        HiveTypes.Tier tier;
        uint256 staked;
        uint256 registeredAt;
        uint256 exitRequestedAt; // 0 = not requested
        uint256 frozenStake;    // 信心度冻结部分
        uint256 dailyRoundsUsed;
        uint256 lastRoundDay;   // 用于重置每日计数
    }

    mapping(address => AgentState) private _agents;
    address[] private _activeAgents;

    // Phase 0 简化：声誉由外部传入或使用固定值
    // Phase 1+ 接入 Axon 0x0802 预编译
    mapping(address => uint256) private _reputations;

    constructor(address admin, address axonToken_, address accessControl_, address hiveScore_) {
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        axonToken = IERC20(axonToken_);
        accessControl = HiveAccess(accessControl_);
        hiveScore = HiveScore(hiveScore_);
    }

    // ─── 注册 ──────────────────────────────────────────────

    function register(uint256 axonAmount) external {
        require(!_agents[msg.sender].isActive, "HiveAgent: already registered");

        uint256 reputation = _reputations[msg.sender];
        HiveTypes.Tier tier = accessControl.calculateTier(reputation, axonAmount);
        require(tier != HiveTypes.Tier.NONE, "HiveAgent: below minimum tier");

        axonToken.safeTransferFrom(msg.sender, address(this), axonAmount);

        _agents[msg.sender] = AgentState({
            isActive: true,
            tier: tier,
            staked: axonAmount,
            registeredAt: block.timestamp,
            exitRequestedAt: 0,
            frozenStake: 0,
            dailyRoundsUsed: 0,
            lastRoundDay: 0
        });
        _activeAgents.push(msg.sender);

        emit AgentRegistered(msg.sender, axonAmount, tier);
    }

    // ─── 质押管理 ───────────────────────────────────────────

    function addStake(uint256 axonAmount) external {
        AgentState storage a = _agents[msg.sender];
        require(a.isActive, "HiveAgent: not active");

        axonToken.safeTransferFrom(msg.sender, address(this), axonAmount);
        a.staked += axonAmount;

        HiveTypes.Tier oldTier = a.tier;
        HiveTypes.Tier newTier = accessControl.calculateTier(_reputations[msg.sender], a.staked);
        if (newTier != oldTier) {
            a.tier = newTier;
            emit TierChanged(msg.sender, oldTier, newTier);
        }

        emit StakeAdded(msg.sender, axonAmount, a.staked);
    }

    function requestExit() external {
        AgentState storage a = _agents[msg.sender];
        require(a.isActive, "HiveAgent: not active");
        require(a.exitRequestedAt == 0, "HiveAgent: exit already requested");
        require(a.frozenStake == 0, "HiveAgent: has frozen stake in active round");

        a.exitRequestedAt = block.timestamp;
        a.isActive = false;

        emit ExitRequested(msg.sender, block.timestamp + EXIT_COOLDOWN);
    }

    function withdrawStake() external {
        AgentState storage a = _agents[msg.sender];
        require(a.exitRequestedAt > 0, "HiveAgent: no exit requested");
        require(block.timestamp >= a.exitRequestedAt + EXIT_COOLDOWN, "HiveAgent: cooldown not passed");

        uint256 amount = a.staked;
        a.staked = 0;
        a.exitRequestedAt = 0;

        axonToken.safeTransfer(msg.sender, amount);

        emit StakeWithdrawn(msg.sender, amount);
    }

    // ─── 信心度质押冻结（由 HiveRound 调用）─────────────────

    /// @notice 冻结质押（预测提交时）
    function freezeStake(address agent, uint256 amount) external onlyRole(DEFAULT_ADMIN_ROLE) {
        AgentState storage a = _agents[agent];
        require(a.staked - a.frozenStake >= amount, "HiveAgent: insufficient unfrozen stake");
        a.frozenStake += amount;
    }

    /// @notice 解冻并返还（预测正确）
    function unfreezeStake(address agent, uint256 amount) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _agents[agent].frozenStake -= amount;
    }

    /// @notice 扣除冻结质押（预测错误，50% 扣入风险准备金）
    function slashFrozenStake(address agent, uint256 amount, address recipient)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        AgentState storage a = _agents[agent];
        require(a.frozenStake >= amount, "HiveAgent: slash exceeds frozen");
        a.frozenStake -= amount;
        a.staked -= amount;
        axonToken.safeTransfer(recipient, amount);
    }

    // ─── 每日轮次计数 ──────────────────────────────────────

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

    // ─── 声誉管理（Phase 0 简化版）─────────────────────────

    function setReputation(address agent, uint256 reputation) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _reputations[agent] = reputation;

        if (_agents[agent].isActive) {
            AgentState storage a = _agents[agent];
            HiveTypes.Tier oldTier = a.tier;
            HiveTypes.Tier newTier = accessControl.calculateTier(reputation, a.staked);
            if (newTier != oldTier) {
                a.tier = newTier;
                emit TierChanged(agent, oldTier, newTier);
            }
        }
    }

    // ─── 只读 ──────────────────────────────────────────────

    function getProfile(address agent) external view returns (HiveTypes.AgentProfile memory) {
        AgentState storage a = _agents[agent];
        HiveScore.ScoreData memory sd = hiveScore.getFullStats(agent);

        return HiveTypes.AgentProfile({
            isActive: a.isActive,
            tier: a.tier,
            axonStaked: a.staked,
            hiveScore: sd.score,
            totalRounds: sd.totalRounds,
            correctRounds: sd.correctRounds,
            currentStreak: sd.streak,
            bestStreak: sd.bestStreak,
            totalEarnedUSDT: 0, // 从 Vault 查询
            registeredAt: a.registeredAt
        });
    }

    function isActive(address agent) external view returns (bool) {
        return _agents[agent].isActive;
    }

    function getStake(address agent) external view returns (uint256) {
        return _agents[agent].staked;
    }

    function getTier(address agent) external view returns (HiveTypes.Tier) {
        return _agents[agent].tier;
    }

    function getReputation(address agent) external view returns (uint256) {
        return _reputations[agent];
    }

    function activeAgentCount() external view returns (uint256) {
        uint256 count = 0;
        for (uint256 i = 0; i < _activeAgents.length; i++) {
            if (_agents[_activeAgents[i]].isActive) count++;
        }
        return count;
    }
}
