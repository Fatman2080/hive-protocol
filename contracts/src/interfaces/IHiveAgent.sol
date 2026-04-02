// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import {HiveTypes} from "./IHiveTypes.sol";

/// @title IHiveAgent — Agent 注册接口（无质押，读主网余额）
interface IHiveAgent {
    event AgentRegistered(address indexed agent, uint256 balance, HiveTypes.Tier tier);
    event AgentDeregistered(address indexed agent);
    event TierChanged(address indexed agent, HiveTypes.Tier oldTier, HiveTypes.Tier newTier);

    /// @notice 注册（读主网余额，自动设 HiveScore=0）
    function register() external;

    /// @notice 退出（即时，无锁定期）
    function deregister() external;

    /// @notice 查询 Agent 完整档案
    function getProfile(address agent) external view returns (HiveTypes.AgentProfile memory);

    /// @notice Agent 是否已注册且活跃
    function isActive(address agent) external view returns (bool);

    /// @notice 查询主网余额（只读）
    function getStake(address agent) external view returns (uint256);

    /// @notice 查询当前等级
    function getTier(address agent) external view returns (HiveTypes.Tier);
}
