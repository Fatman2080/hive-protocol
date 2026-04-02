// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {HiveAccess} from "../src/HiveAccess.sol";
import {HiveScore} from "../src/HiveScore.sol";
import {HiveAgent} from "../src/HiveAgent.sol";
import {HiveVault} from "../src/HiveVault.sol";
import {HiveRound} from "../src/HiveRound.sol";

/// @notice 部署全部合约并配置权限（v2 无质押模型）
contract DeployScript is Script {
    function run() external {
        address deployer = msg.sender;

        vm.startBroadcast();

        address usdtToken = vm.envAddress("USDT_TOKEN");
        address buybackReceiver = vm.envOr("BUYBACK_RECEIVER", deployer);
        address opsReceiver = vm.envOr("OPS_RECEIVER", deployer);

        HiveAccess access = new HiveAccess();
        console.log("HiveAccess:", address(access));

        HiveScore hiveScore = new HiveScore(deployer);
        console.log("HiveScore:", address(hiveScore));

        HiveAgent agent = new HiveAgent(deployer, address(access), address(hiveScore));
        console.log("HiveAgent:", address(agent));

        HiveVault vault = new HiveVault(deployer, usdtToken, buybackReceiver, opsReceiver);
        console.log("HiveVault:", address(vault));

        HiveRound round = new HiveRound(deployer, address(vault), address(hiveScore), address(agent));
        console.log("HiveRound:", address(round));

        hiveScore.grantRole(hiveScore.ROUND_ROLE(), address(round));
        vault.grantRole(vault.ROUND_ROLE(), address(round));
        agent.grantRole(agent.DEFAULT_ADMIN_ROLE(), address(round));

        vm.stopBroadcast();

        console.log("--- Deployment Complete (v2 no-stake) ---");
    }
}
