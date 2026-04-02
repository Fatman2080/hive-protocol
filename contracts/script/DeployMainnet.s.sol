// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {HiveAccess} from "../src/HiveAccess.sol";
import {HiveScore} from "../src/HiveScore.sol";
import {HiveAgent} from "../src/HiveAgent.sol";
import {HiveVault} from "../src/HiveVault.sol";
import {HiveRound} from "../src/HiveRound.sol";
import {HiveReputationBridge} from "../src/HiveReputationBridge.sol";
import {HiveRiskControl} from "../src/HiveRiskControl.sol";

/// @dev Phase 0 专用 ERC20 — 带 mint 权限（仅 owner 可调用）
contract HiveToken is ERC20 {
    address public owner;
    uint8 private _dec;

    constructor(string memory name_, string memory symbol_, uint8 decimals_) ERC20(name_, symbol_) {
        owner = msg.sender;
        _dec = decimals_;
    }

    function mint(address to, uint256 amount) external {
        require(msg.sender == owner, "only owner");
        _mint(to, amount);
    }

    function decimals() public view override returns (uint8) {
        return _dec;
    }
}

/// @title DeployMainnet — Axon 主网一键部署
/// @notice 部署 Token + 全部蜂巢合约 + 配置权限 + 初始化金库
contract DeployMainnet is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("OPERATOR_PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);

        console.log("Deployer:", deployer);
        console.log("Chain ID:", block.chainid);

        vm.startBroadcast(deployerKey);

        // ═══ Step 1: 部署 ERC20 Token ═══
        HiveToken axonToken = new HiveToken("Axon Token", "AXON", 18);
        console.log("AXON Token:", address(axonToken));

        HiveToken usdtToken = new HiveToken("Tether USD", "USDT", 6);
        console.log("USDT Token:", address(usdtToken));

        // ═══ Step 2: 部署蜂巢合约 ═══
        HiveAccess access = new HiveAccess();
        console.log("HiveAccess:", address(access));

        HiveScore hiveScore = new HiveScore(deployer);
        console.log("HiveScore:", address(hiveScore));

        HiveAgent agent = new HiveAgent(
            deployer,
            address(axonToken),
            address(access),
            address(hiveScore)
        );
        console.log("HiveAgent:", address(agent));

        HiveVault vault = new HiveVault(
            deployer,
            address(usdtToken),
            deployer,  // buyback receiver = deployer (Phase 0)
            deployer   // ops receiver = deployer (Phase 0)
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

        // ═══ Step 3: 配置权限 ═══
        hiveScore.grantRole(hiveScore.ROUND_ROLE(), address(round));
        vault.grantRole(vault.ROUND_ROLE(), address(round));
        agent.grantRole(agent.DEFAULT_ADMIN_ROLE(), address(round));

        // ═══ Step 4: Mint 初始 Token ═══

        // Mint USDT 到 deployer 用于注入金库
        usdtToken.mint(deployer, 10_000 * 1e6); // 10,000 USDT
        console.log("Minted 10,000 USDT to deployer");

        // 向金库注入 10,000 USDT
        usdtToken.approve(address(vault), 10_000 * 1e6);
        vault.deposit(10_000 * 1e6);
        console.log("Deposited 10,000 USDT to HiveVault");

        // Mint AXON ERC20 给 5 个测试 Agent (每个 200 用于质押)
        address[5] memory agents = [
            address(0xC00df1E74fd818D8F538702C27FB9FEB8E6Be706), // Random
            address(0xF77A0b21Fd53aD5777AcE3140F7F34469db36820), // Momentum
            address(0xba628c5F1aE3a29c1933ff8552Be48722F9e4efa), // Sentiment
            address(0xFC7F55B8d9c0610DfB5C6dEDb6a813bb577FCD0D), // LLM
            address(0xAD70104cf2f7CB75aBac8d6DBC3cC30D29355352)  // Contrarian
        ];

        for (uint256 i = 0; i < agents.length; i++) {
            axonToken.mint(agents[i], 200 * 1e18); // 200 AXON each
        }
        console.log("Minted 200 AXON to each of 5 test agents");

        // 设置每个 Agent 的初始声誉 (Bronze 门槛)
        for (uint256 i = 0; i < agents.length; i++) {
            agent.setReputation(agents[i], 30);
        }
        console.log("Set reputation=30 for 5 agents");

        vm.stopBroadcast();

        // ═══ 输出摘要 ═══
        console.log("");
        console.log("=== DEPLOYMENT COMPLETE ===");
        console.log("AXON_TOKEN=", address(axonToken));
        console.log("USDT_TOKEN=", address(usdtToken));
        console.log("HIVE_ACCESS=", address(access));
        console.log("HIVE_SCORE=", address(hiveScore));
        console.log("HIVE_AGENT=", address(agent));
        console.log("HIVE_VAULT=", address(vault));
        console.log("HIVE_ROUND=", address(round));
        console.log("HIVE_REPUTATION_BRIDGE=", address(repBridge));
        console.log("HIVE_RISK_CONTROL=", address(riskControl));
        console.log("VAULT_BALANCE=", vault.treasuryBalance());
    }
}
