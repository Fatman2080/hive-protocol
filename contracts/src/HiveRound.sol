// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import {IHiveRound} from "./interfaces/IHiveRound.sol";
import {HiveTypes} from "./interfaces/IHiveTypes.sol";
import {HiveVault} from "./HiveVault.sol";
import {HiveScore} from "./HiveScore.sol";
import {HiveAgent} from "./HiveAgent.sol";
import {HiveAccess} from "./HiveAccess.sol";
import {HiveMath} from "./libraries/HiveMath.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title HiveRound — 轮次管理（commit → reveal → settle）
/// @notice 无质押冻结/slash，惩罚仅通过 HiveScore 扣分实现。
contract HiveRound is IHiveRound, AccessControl, ReentrancyGuard {
    using HiveMath for uint256;

    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    uint256 public constant DECISION_THRESHOLD_BPS = 6000;

    HiveVault public immutable vault;
    HiveScore public immutable score;
    HiveAgent public immutable agentRegistry;

    uint256 private _currentRoundId;

    struct RoundState {
        HiveTypes.RoundPhase phase;
        uint256 openPrice;
        uint256 closePrice;
        uint256 upWeight;
        uint256 downWeight;
        uint256 participantCount;
        uint256 betAmount;
        int256 profitLoss;
        uint256 startTime;
        address[] participants;
    }

    mapping(uint256 => RoundState) private _rounds;
    mapping(uint256 => mapping(address => HiveTypes.CommitInfo)) private _commits;

    constructor(address admin, address vault_, address score_, address agent_) {
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(OPERATOR_ROLE, admin);
        vault = HiveVault(vault_);
        score = HiveScore(score_);
        agentRegistry = HiveAgent(agent_);
    }

    // ─── 轮次生命周期 ──────────────────────────────────

    function startRound(uint256 openPrice) external onlyRole(OPERATOR_ROLE) returns (uint256 roundId) {
        if (_currentRoundId > 0) {
            require(
                _rounds[_currentRoundId].phase == HiveTypes.RoundPhase.SETTLED
                    || _rounds[_currentRoundId].phase == HiveTypes.RoundPhase.IDLE,
                "HiveRound: previous round not settled"
            );
        }

        _currentRoundId++;
        roundId = _currentRoundId;

        _rounds[roundId].phase = HiveTypes.RoundPhase.COMMIT;
        _rounds[roundId].openPrice = openPrice;
        _rounds[roundId].startTime = block.timestamp;

        emit RoundStarted(roundId, openPrice, block.timestamp);
    }

    function advanceToReveal(uint256 roundId) external onlyRole(OPERATOR_ROLE) {
        require(_rounds[roundId].phase == HiveTypes.RoundPhase.COMMIT, "HiveRound: not in COMMIT phase");
        _rounds[roundId].phase = HiveTypes.RoundPhase.REVEAL;
    }

    // ─── Agent 提交预测 ─────────────────────────────────

    function commit(uint256 roundId, bytes32 commitHash) external {
        RoundState storage r = _rounds[roundId];
        require(r.phase == HiveTypes.RoundPhase.COMMIT, "HiveRound: not in COMMIT phase");
        require(agentRegistry.isActive(msg.sender), "HiveRound: agent not active");
        require(agentRegistry.canParticipateToday(msg.sender), "HiveRound: daily cap reached");
        require(_commits[roundId][msg.sender].commitHash == bytes32(0), "HiveRound: already committed");

        _commits[roundId][msg.sender].commitHash = commitHash;
        r.participants.push(msg.sender);
        r.participantCount++;

        agentRegistry.recordRoundParticipation(msg.sender);

        emit PredictionCommitted(roundId, msg.sender);
    }

    function reveal(uint256 roundId, HiveTypes.Prediction prediction, uint8 confidence, bytes32 salt) external {
        RoundState storage r = _rounds[roundId];
        require(r.phase == HiveTypes.RoundPhase.REVEAL, "HiveRound: not in REVEAL phase");

        HiveTypes.CommitInfo storage ci = _commits[roundId][msg.sender];
        require(ci.commitHash != bytes32(0), "HiveRound: no commit found");
        require(!ci.revealed, "HiveRound: already revealed");

        bytes32 expected = keccak256(abi.encodePacked(prediction, confidence, salt));
        require(expected == ci.commitHash, "HiveRound: hash mismatch");

        HiveTypes.Tier tier = agentRegistry.getTier(msg.sender);
        uint8 maxConf = HiveAccess(address(agentRegistry.accessControl())).maxAllowedConfidence(tier);
        require(confidence <= maxConf, "HiveRound: confidence exceeds tier limit");
        require(confidence >= 1 && confidence <= 100, "HiveRound: confidence out of range");

        ci.revealed = true;
        ci.prediction = prediction;
        ci.confidence = confidence;

        uint256 agentBalance = msg.sender.balance;
        uint256 w = HiveMath.calcWeight(score.getScore(msg.sender), confidence, agentBalance);
        ci.weight = w;

        if (prediction == HiveTypes.Prediction.UP) {
            r.upWeight += w;
        } else {
            r.downWeight += w;
        }

        emit PredictionRevealed(roundId, msg.sender, prediction, confidence);
    }

    // ─── 结算 ──────────────────────────────────────────

    function settle(uint256 roundId, uint256 closePrice, int256 profitLoss) external onlyRole(OPERATOR_ROLE) nonReentrant {
        RoundState storage r = _rounds[roundId];
        require(r.phase == HiveTypes.RoundPhase.REVEAL, "HiveRound: not in REVEAL phase");

        r.phase = HiveTypes.RoundPhase.SETTLED;
        r.closePrice = closePrice;
        r.profitLoss = profitLoss;
        r.betAmount = vault.currentBetSize();

        HiveTypes.Prediction actualResult = closePrice > r.openPrice
            ? HiveTypes.Prediction.UP
            : HiveTypes.Prediction.DOWN;

        uint256 totalWeight = r.upWeight + r.downWeight;
        bool skipped = false;
        HiveTypes.Prediction groupDecision;

        if (totalWeight == 0) {
            skipped = true;
        } else {
            uint256 upBps = (r.upWeight * 10000) / totalWeight;
            if (upBps >= DECISION_THRESHOLD_BPS) {
                groupDecision = HiveTypes.Prediction.UP;
            } else if (upBps <= (10000 - DECISION_THRESHOLD_BPS)) {
                groupDecision = HiveTypes.Prediction.DOWN;
            } else {
                skipped = true;
            }
        }

        if (skipped) {
            emit RoundSkipped(roundId, "signal insufficient");
            return;
        }

        (address[] memory correctAgents, uint256[] memory correctWeights, uint256 correctCount) =
            _classifyAndScore(roundId, actualResult);

        if (profitLoss > 0) {
            vault.distributeProfit(roundId, correctAgents, correctWeights, uint256(profitLoss));
        } else if (profitLoss < 0) {
            vault.recordLoss(roundId, uint256(-profitLoss));
        }

        emit RoundSettled(roundId, actualResult, profitLoss, correctCount);
    }

    // ─── 内部方法 ──────────────────────────────────────

    function _classifyAndScore(uint256 roundId, HiveTypes.Prediction actualResult)
        internal
        returns (address[] memory, uint256[] memory, uint256)
    {
        RoundState storage r = _rounds[roundId];
        uint256 len = r.participants.length;

        address[] memory tempCorrect = new address[](len);
        uint256[] memory tempWeights = new uint256[](len);
        uint256 correctCount = 0;

        for (uint256 i = 0; i < len; i++) {
            address agent = r.participants[i];
            HiveTypes.CommitInfo storage ci = _commits[roundId][agent];

            if (!ci.revealed) {
                score.updateScore(agent, false, 1);
                continue;
            }

            bool isCorrect = ci.prediction == actualResult;
            score.updateScore(agent, isCorrect, ci.confidence);

            if (isCorrect) {
                tempCorrect[correctCount] = agent;
                tempWeights[correctCount] = ci.weight;
                correctCount++;
            }
        }

        address[] memory correctAgents = new address[](correctCount);
        uint256[] memory correctWeights = new uint256[](correctCount);
        for (uint256 i = 0; i < correctCount; i++) {
            correctAgents[i] = tempCorrect[i];
            correctWeights[i] = tempWeights[i];
        }

        return (correctAgents, correctWeights, correctCount);
    }

    // ─── 只读 ──────────────────────────────────────────

    function getRound(uint256 roundId) external view returns (HiveTypes.RoundData memory) {
        RoundState storage r = _rounds[roundId];
        return HiveTypes.RoundData({
            phase: r.phase,
            openPrice: r.openPrice,
            closePrice: r.closePrice,
            upWeight: r.upWeight,
            downWeight: r.downWeight,
            participantCount: r.participantCount,
            betAmount: r.betAmount,
            profitLoss: r.profitLoss,
            startTime: r.startTime
        });
    }

    function currentRoundId() external view returns (uint256) {
        return _currentRoundId;
    }

    function getCommit(uint256 roundId, address agent) external view returns (HiveTypes.CommitInfo memory) {
        return _commits[roundId][agent];
    }

    function getParticipants(uint256 roundId) external view returns (address[] memory) {
        return _rounds[roundId].participants;
    }
}
