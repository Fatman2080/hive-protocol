// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {HiveAccess} from "../src/HiveAccess.sol";
import {HiveScore} from "../src/HiveScore.sol";
import {HiveAgent} from "../src/HiveAgent.sol";
import {HiveVault} from "../src/HiveVault.sol";
import {HiveRound} from "../src/HiveRound.sol";

/// @dev 测试用 ERC20 Token（可自由 mint）
contract MockERC20 is ERC20 {
    uint8 private _decimals;

    constructor(string memory name, string memory symbol, uint8 dec) ERC20(name, symbol) {
        _decimals = dec;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }
}

/// @title BaseTest — 所有测试的共享基础
/// @notice 部署全套合约，创建 mock token，提供常用 helper
abstract contract BaseTest is Test {
    MockERC20 public axon;
    MockERC20 public usdt;

    HiveAccess public access;
    HiveScore public hiveScore;
    HiveAgent public agentRegistry;
    HiveVault public vault;
    HiveRound public round;

    address public admin = makeAddr("admin");
    address public buyback = makeAddr("buyback");
    address public ops = makeAddr("ops");

    // 测试 Agent 地址
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");
    address public carol = makeAddr("carol");

    function setUp() public virtual {
        vm.startPrank(admin);

        // 部署 mock token
        axon = new MockERC20("Axon Token", "AXON", 18);
        usdt = new MockERC20("Tether USD", "USDT", 6);

        // 部署合约
        access = new HiveAccess();
        hiveScore = new HiveScore(admin);
        agentRegistry = new HiveAgent(admin, address(axon), address(access), address(hiveScore));
        vault = new HiveVault(admin, address(usdt), buyback, ops);
        round = new HiveRound(admin, address(vault), address(hiveScore), address(agentRegistry));

        // 配置权限
        hiveScore.grantRole(hiveScore.ROUND_ROLE(), address(round));
        vault.grantRole(vault.ROUND_ROLE(), address(round));
        agentRegistry.grantRole(agentRegistry.DEFAULT_ADMIN_ROLE(), address(round));

        vm.stopPrank();
    }

    // ─── Helper Functions ──────────────────────────────────

    /// @dev 注册一个 Agent：设置声誉、mint AXON、approve、register
    function _registerAgent(address agent, uint256 reputation, uint256 stakeAmount) internal {
        vm.prank(admin);
        agentRegistry.setReputation(agent, reputation);

        axon.mint(agent, stakeAmount);
        vm.startPrank(agent);
        axon.approve(address(agentRegistry), stakeAmount);
        agentRegistry.register(stakeAmount);
        vm.stopPrank();
    }

    /// @dev 向金库注入 USDT
    function _fundVault(uint256 amount) internal {
        usdt.mint(admin, amount);
        vm.startPrank(admin);
        usdt.approve(address(vault), amount);
        vault.deposit(amount);
        vm.stopPrank();
    }

    /// @dev 生成 commit hash
    function _commitHash(uint8 prediction, uint8 confidence, bytes32 salt) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(prediction, confidence, salt));
    }

    /// @dev 生成 commit hash（用枚举类型）
    function _commitHashTyped(bool isUp, uint8 confidence, bytes32 salt) internal pure returns (bytes32) {
        uint8 pred = isUp ? 0 : 1; // UP=0, DOWN=1
        return keccak256(abi.encodePacked(pred, confidence, salt));
    }
}
