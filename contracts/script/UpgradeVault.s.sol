// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {HiveVault} from "../src/HiveVault.sol";
import {HiveRound} from "../src/HiveRound.sol";
import {HiveScore} from "../src/HiveScore.sol";
import {HiveAgent} from "../src/HiveAgent.sol";

/// @title UpgradeVault — 重部署 HiveVault + HiveRound (vault 是 immutable)
contract UpgradeVault is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("OPERATOR_PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);

        address scoreAddr = vm.envAddress("HIVE_SCORE_ADDRESS");
        address agentAddr = vm.envAddress("HIVE_AGENT_ADDRESS");

        console.log("Deployer:", deployer);

        vm.startBroadcast(deployerKey);

        // 1. 部署新 HiveVault
        address usdtPlaceholder = address(0x1);
        HiveVault newVault = new HiveVault(deployer, usdtPlaceholder, deployer, deployer);
        console.log("New HiveVault:", address(newVault));

        // 2. 部署新 HiveRound → 指向新 Vault
        HiveRound newRound = new HiveRound(deployer, address(newVault), scoreAddr, agentAddr);
        console.log("New HiveRound:", address(newRound));

        // 3. 配置权限
        newVault.grantRole(newVault.ROUND_ROLE(), address(newRound));
        HiveScore(scoreAddr).grantRole(HiveScore(scoreAddr).ROUND_ROLE(), address(newRound));
        HiveAgent(agentAddr).grantRole(HiveAgent(agentAddr).DEFAULT_ADMIN_ROLE(), address(newRound));

        vm.stopBroadcast();

        console.log("");
        console.log("=== UPGRADE COMPLETE ===");
        console.log("HIVE_VAULT_ADDRESS=", address(newVault));
        console.log("HIVE_ROUND_ADDRESS=", address(newRound));
        console.log("Update .env with these new addresses!");
    }
}
