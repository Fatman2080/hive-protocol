// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import {IHiveVault} from "./interfaces/IHiveVault.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title HiveVault — 金库管理 + 利润分配
/// @notice 管理 USDT 资金池。盈利时按 35/40/10/10/5 分配，亏损时从金库扣除。
///
/// 分配比例：
///   35% — Agent 利润池（按权重分配给正确方）
///   40% — 金库留存（复利增长）
///   10% — AXON 回购销毁（发送到 buyback 地址）
///   10% — 风险准备金
///    5% — 运营费用
contract HiveVault is IHiveVault, AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;

    bytes32 public constant ROUND_ROLE = keccak256("ROUND_ROLE");

    uint256 public constant BET_BPS = 200; // 金库的 2%
    uint256 public constant BPS = 10000;

    uint256 public constant AGENT_BPS = 3500;
    uint256 public constant RETAIN_BPS = 4000;
    uint256 public constant BUYBACK_BPS = 1000;
    uint256 public constant RESERVE_BPS = 1000;
    uint256 public constant OPS_BPS = 500;

    IERC20 public immutable usdt;
    address public buybackReceiver;
    address public opsReceiver;

    uint256 private _treasury;
    uint256 private _reserve;
    mapping(address => uint256) private _pendingRewards;
    mapping(address => uint256) private _totalEarned;

    constructor(address admin, address usdt_, address buyback_, address ops_) {
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        usdt = IERC20(usdt_);
        buybackReceiver = buyback_;
        opsReceiver = ops_;
    }

    // ─── 写入（仅 HiveRound）──────────────────────────────

    function distributeProfit(
        uint256 roundId,
        address[] calldata agents,
        uint256[] calldata weights,
        uint256 profit
    ) external onlyRole(ROUND_ROLE) nonReentrant {
        require(agents.length == weights.length, "HiveVault: length mismatch");
        require(agents.length > 0, "HiveVault: no agents");

        uint256 agentPool = (profit * AGENT_BPS) / BPS;
        uint256 retained = (profit * RETAIN_BPS) / BPS;
        uint256 buyback = (profit * BUYBACK_BPS) / BPS;
        uint256 reserve = (profit * RESERVE_BPS) / BPS;
        uint256 ops = profit - agentPool - retained - buyback - reserve;

        // Agent 按权重分配
        uint256 totalWeight = 0;
        for (uint256 i = 0; i < weights.length; i++) {
            totalWeight += weights[i];
        }

        for (uint256 i = 0; i < agents.length; i++) {
            uint256 share = (agentPool * weights[i]) / totalWeight;
            _pendingRewards[agents[i]] += share;
            _totalEarned[agents[i]] += share;
        }

        _treasury += retained;
        _reserve += reserve;

        if (_hasTokenContract()) {
            usdt.safeTransfer(buybackReceiver, buyback);
            usdt.safeTransfer(opsReceiver, ops);
        } else {
            emit TransferDeferred(roundId, buybackReceiver, buyback, "no token contract");
            emit TransferDeferred(roundId, opsReceiver, ops, "no token contract");
        }

        emit ProfitDistributed(roundId, agentPool, retained, buyback, reserve, ops);
    }

    function recordLoss(uint256 roundId, uint256 amount) external onlyRole(ROUND_ROLE) {
        if (amount > _treasury) {
            uint256 gap = amount - _treasury;
            uint256 fromReserve = gap > _reserve ? _reserve : gap;
            _reserve -= fromReserve;
            _treasury = 0;
            if (fromReserve > 0) emit ReserveUsed(fromReserve);
        } else {
            _treasury -= amount;
        }
        emit LossRecorded(roundId, amount);
    }

    // ─── Agent 领取 ─────────────────────────────────────────

    function claim() external nonReentrant {
        uint256 amount = _pendingRewards[msg.sender];
        require(amount > 0, "HiveVault: nothing to claim");
        require(_hasTokenContract(), "HiveVault: no token contract on this chain");

        _pendingRewards[msg.sender] = 0;
        usdt.safeTransfer(msg.sender, amount);

        emit AgentClaimed(msg.sender, amount);
    }

    // ─── 注资 ──────────────────────────────────────────────

    function deposit(uint256 amount) external {
        usdt.safeTransferFrom(msg.sender, address(this), amount);
        _treasury += amount;
        emit Deposited(msg.sender, amount);
    }

    // ─── 只读 ──────────────────────────────────────────────

    function treasuryBalance() external view returns (uint256) {
        return _treasury;
    }

    function reserveBalance() external view returns (uint256) {
        return _reserve;
    }

    function currentBetSize() external view returns (uint256) {
        return (_treasury * BET_BPS) / BPS;
    }

    function pendingReward(address agent) external view returns (uint256) {
        return _pendingRewards[agent];
    }

    function totalEarned(address agent) external view returns (uint256) {
        return _totalEarned[agent];
    }

    // ─── 内部 ──────────────────────────────────────────────

    /// @dev 判断 usdt 地址是否为真实 ERC-20 合约（非占位符）
    function _hasTokenContract() internal view returns (bool) {
        return address(usdt).code.length > 0;
    }

    // ─── 管理 ──────────────────────────────────────────────

    function setBuybackReceiver(address addr) external onlyRole(DEFAULT_ADMIN_ROLE) {
        buybackReceiver = addr;
    }

    function setOpsReceiver(address addr) external onlyRole(DEFAULT_ADMIN_ROLE) {
        opsReceiver = addr;
    }
}
