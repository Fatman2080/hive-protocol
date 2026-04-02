// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {HiveAccess} from "../src/HiveAccess.sol";
import {HiveScore} from "../src/HiveScore.sol";
import {HiveAgent} from "../src/HiveAgent.sol";
import {HiveVault} from "../src/HiveVault.sol";
import {HiveRound} from "../src/HiveRound.sol";

/// @notice 部署全部合约并配置权限
contract DeployScript is Script {
    function run() external {
        address deployer = msg.sender;

        vm.startBroadcast();

        // 需要先部署或指定已存在的 Token 合约地址
        address axonToken = vm.envAddress("AXON_TOKEN");
        address usdtToken = vm.envAddress("USDT_TOKEN");
        address buybackReceiver = vm.envOr("BUYBACK_RECEIVER", deployer);
        address opsReceiver = vm.envOr("OPS_RECEIVER", deployer);

        // 1. 无依赖合约先部署
        HiveAccess access = new HiveAccess();
        console.log("HiveAccess:", address(access));

        HiveScore hiveScore = new HiveScore(deployer);
        console.log("HiveScore:", address(hiveScore));

        // 2. 依赖 Access + Score
        HiveAgent agent = new HiveAgent(deployer, axonToken, address(access), address(hiveScore));
        console.log("HiveAgent:", address(agent));

        // 3. 依赖 USDT
        HiveVault vault = new HiveVault(deployer, usdtToken, buybackReceiver, opsReceiver);
        console.log("HiveVault:", address(vault));

        // 4. 依赖 Vault + Score + Agent
        HiveRound round = new HiveRound(deployer, address(vault), address(hiveScore), address(agent));
        console.log("HiveRound:", address(round));

        // 5. 配置权限：HiveRound 可以更新 Score 和操作 Vault
        hiveScore.grantRole(hiveScore.ROUND_ROLE(), address(round));
        vault.grantRole(vault.ROUND_ROLE(), address(round));

        // HiveRound 需要操作 HiveAgent 的 freeze/unfreeze/slash
        agent.grantRole(agent.DEFAULT_ADMIN_ROLE(), address(round));

        vm.stopBroadcast();

        console.log("--- Deployment Complete ---");
    }
}
