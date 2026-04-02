// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import {HiveScore} from "./HiveScore.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

/// @title HiveReputationBridge — 蜂巢 → Axon 链上声誉桥
/// @notice 每个 Epoch（50 轮）批量将蜂巢预测表现写入 Axon 链上声誉系统。
///
/// 写入规则：
///   Epoch 内正确率 ≥ 80% → 声誉 +2
///   Epoch 内正确率 ≥ 60% → 声誉 +1
///   Epoch 内正确率 < 40% → 声誉 -1
///   Epoch 内正确率 < 20% → 声誉 -2
///
/// Phase 0: 将声誉变动记录到事件日志（链下索引）
/// Phase 1+: 实际调用 Axon 0x0807 IReputationReport 预编译
contract HiveReputationBridge is AccessControl {
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");

    uint256 public constant EPOCH_SIZE = 50; // 每 50 轮刷新一次

    HiveScore public immutable hiveScore;

    uint256 public currentEpoch;
    uint256 public roundsSinceLastFlush;

    struct EpochRecord {
        uint256 epoch;
        uint256 timestamp;
        uint256 agentCount;
        bool flushed;
    }

    struct AgentEpochData {
        uint256 roundsInEpoch;
        uint256 correctInEpoch;
    }

    mapping(uint256 => EpochRecord) public epochs;
    mapping(uint256 => mapping(address => AgentEpochData)) private _epochAgentData;
    mapping(uint256 => address[]) private _epochAgents;

    event EpochStarted(uint256 indexed epoch, uint256 timestamp);
    event AgentRoundRecorded(uint256 indexed epoch, address indexed agent, bool correct);
    event ReputationFlushed(
        uint256 indexed epoch,
        uint256 agentCount,
        uint256 positiveCount,
        uint256 negativeCount
    );
    event ReputationDelta(
        uint256 indexed epoch,
        address indexed agent,
        int8 delta,
        uint256 correctRate
    );

    constructor(address admin, address hiveScore_) {
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(OPERATOR_ROLE, admin);
        hiveScore = HiveScore(hiveScore_);
    }

    /// @notice 记录 Agent 在一轮中的对错（由 HiveRound 在结算时调用）
    function recordRound(address agent, bool correct) external onlyRole(OPERATOR_ROLE) {
        if (roundsSinceLastFlush == 0) {
            currentEpoch++;
            epochs[currentEpoch] = EpochRecord({
                epoch: currentEpoch,
                timestamp: block.timestamp,
                agentCount: 0,
                flushed: false
            });
            emit EpochStarted(currentEpoch, block.timestamp);
        }

        AgentEpochData storage data = _epochAgentData[currentEpoch][agent];
        if (data.roundsInEpoch == 0) {
            _epochAgents[currentEpoch].push(agent);
            epochs[currentEpoch].agentCount++;
        }

        data.roundsInEpoch++;
        if (correct) {
            data.correctInEpoch++;
        }

        emit AgentRoundRecorded(currentEpoch, agent, correct);

        roundsSinceLastFlush++;
        if (roundsSinceLastFlush >= EPOCH_SIZE) {
            _flush(currentEpoch);
            roundsSinceLastFlush = 0;
        }
    }

    /// @notice 手动触发刷新（用于 Epoch 还没满但需要中间刷新的场景）
    function manualFlush() external onlyRole(OPERATOR_ROLE) {
        require(!epochs[currentEpoch].flushed, "Bridge: epoch already flushed");
        require(roundsSinceLastFlush > 0, "Bridge: no data to flush");
        _flush(currentEpoch);
        roundsSinceLastFlush = 0;
    }

    /// @notice 查询 Agent 在当前 Epoch 的表现
    function getAgentEpochStats(uint256 epoch, address agent)
        external
        view
        returns (uint256 rounds, uint256 correct, uint256 rateBps)
    {
        AgentEpochData storage data = _epochAgentData[epoch][agent];
        rounds = data.roundsInEpoch;
        correct = data.correctInEpoch;
        rateBps = rounds > 0 ? (correct * 10000) / rounds : 0;
    }

    /// @notice 查询 Epoch 中的所有 Agent
    function getEpochAgents(uint256 epoch) external view returns (address[] memory) {
        return _epochAgents[epoch];
    }

    // ─── Internal ────────────────────────────────────────

    function _flush(uint256 epoch) internal {
        address[] storage agents = _epochAgents[epoch];
        uint256 positiveCount = 0;
        uint256 negativeCount = 0;

        for (uint256 i = 0; i < agents.length; i++) {
            address agent = agents[i];
            AgentEpochData storage data = _epochAgentData[epoch][agent];

            if (data.roundsInEpoch < 5) continue; // 参与不足 5 轮不计入

            uint256 rateBps = (data.correctInEpoch * 10000) / data.roundsInEpoch;
            int8 delta = _calculateDelta(rateBps);

            if (delta > 0) positiveCount++;
            if (delta < 0) negativeCount++;

            if (delta != 0) {
                // Phase 0: 仅记录事件，链下服务监听事件后调用 HiveAgent.setReputation
                // Phase 1+: 调用 address(0x0807).call(abi.encode(...))
                emit ReputationDelta(epoch, agent, delta, rateBps);
            }
        }

        epochs[epoch].flushed = true;

        emit ReputationFlushed(epoch, agents.length, positiveCount, negativeCount);
    }

    function _calculateDelta(uint256 rateBps) internal pure returns (int8) {
        if (rateBps >= 8000) return 2;  // ≥ 80%
        if (rateBps >= 6000) return 1;  // ≥ 60%
        if (rateBps < 2000) return -2;  // < 20%
        if (rateBps < 4000) return -1;  // < 40%
        return 0;                        // 40-60% 不变
    }
}
