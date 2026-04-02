// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {HiveAccess} from "../src/HiveAccess.sol";
import {HiveScore} from "../src/HiveScore.sol";
import {HiveAgent} from "../src/HiveAgent.sol";
import {HiveVault} from "../src/HiveVault.sol";
import {HiveRound} from "../src/HiveRound.sol";
import {HiveReputationBridge} from "../src/HiveReputationBridge.sol";
import {HiveRiskControl} from "../src/HiveRiskControl.sol";

/// @title DeployMainnet — Axon 主网部署（v2 无质押模型）
/// @notice 不再部署 ERC-20 AXON Token，Agent 直接用主网余额注册
contract DeployMainnet is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("OPERATOR_PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);

        console.log("Deployer:", deployer);
        console.log("Chain ID:", block.chainid);

        vm.startBroadcast(deployerKey);

        // ═══ Step 1: 部署蜂巢合约 ═══
        HiveAccess access = new HiveAccess();
        console.log("HiveAccess:", address(access));

        HiveScore hiveScore = new HiveScore(deployer);
        console.log("HiveScore:", address(hiveScore));

        HiveAgent agent = new HiveAgent(
            deployer,
            address(access),
            address(hiveScore)
        );
        console.log("HiveAgent:", address(agent));

        // HiveVault 仍需 USDT 合约地址（链上记账用，实际分发在 Polygon 链下完成）
        address usdtPlaceholder = address(0x1);
        HiveVault vault = new HiveVault(
            deployer,
            usdtPlaceholder,
            deployer,
            deployer
        );
        console.log("HiveVault:", address(vault));

        HiveRound round = new HiveRound(
            deployer,
            address(vault),
            address(hiveScore),
            address(agent)
        );
        console.log("HiveRound:", address(round));

        HiveReputationBridge repBridge = new HiveReputationBridge(deployer, address(hiveScore));
        console.log("HiveReputationBridge:", address(repBridge));

        HiveRiskControl riskControl = new HiveRiskControl(deployer);
        console.log("HiveRiskControl:", address(riskControl));

        // ═══ Step 2: 配置权限 ═══
        hiveScore.grantRole(hiveScore.ROUND_ROLE(), address(round));
        vault.grantRole(vault.ROUND_ROLE(), address(round));
        agent.grantRole(agent.DEFAULT_ADMIN_ROLE(), address(round));

        vm.stopBroadcast();

        // ═══ 输出摘要 ═══
        console.log("");
        console.log("=== DEPLOYMENT COMPLETE (v2 no-stake) ===");
        console.log("HIVE_ACCESS=", address(access));
        console.log("HIVE_SCORE=", address(hiveScore));
        console.log("HIVE_AGENT=", address(agent));
        console.log("HIVE_VAULT=", address(vault));
        console.log("HIVE_ROUND=", address(round));
        console.log("HIVE_REPUTATION_BRIDGE=", address(repBridge));
        console.log("HIVE_RISK_CONTROL=", address(riskControl));
    }
}
