// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import {HiveTypes} from "./IHiveTypes.sol";

/// @title IHiveAgent — Agent 注册与质押接口
interface IHiveAgent {
    event AgentRegistered(address indexed agent, uint256 stakeAmount, HiveTypes.Tier tier);
    event StakeAdded(address indexed agent, uint256 amount, uint256 newTotal);
    event ExitRequested(address indexed agent, uint256 unlockTime);
    event StakeWithdrawn(address indexed agent, uint256 amount);
    event TierChanged(address indexed agent, HiveTypes.Tier oldTier, HiveTypes.Tier newTier);

    /// @notice 注册并质押 AXON（需先 approve）
    /// BSC/其他 EVM 链收款地址 = Axon 地址（同一把私钥）
    function register(uint256 axonAmount) external;

    /// @notice 追加质押（可触发升级）
    function addStake(uint256 axonAmount) external;

    /// @notice 申请退出（7 天冷却期）
    function requestExit() external;

    /// @notice 冷却期后取回质押
    function withdrawStake() external;

    /// @notice 查询 Agent 完整档案
    function getProfile(address agent) external view returns (HiveTypes.AgentProfile memory);

    /// @notice Agent 是否已注册且活跃
    function isActive(address agent) external view returns (bool);

    /// @notice 查询质押量
    function getStake(address agent) external view returns (uint256);

    /// @notice 查询当前等级
    function getTier(address agent) external view returns (HiveTypes.Tier);
}
