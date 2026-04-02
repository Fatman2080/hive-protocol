// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {HiveAccess} from "../src/HiveAccess.sol";
import {HiveScore} from "../src/HiveScore.sol";
import {HiveAgent} from "../src/HiveAgent.sol";
import {HiveVault} from "../src/HiveVault.sol";
import {HiveRound} from "../src/HiveRound.sol";

/// @dev 测试用 ERC20 Token（金库 USDT 记账用）
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

/// @title BaseTest — 所有测试的共享基础（v2 无质押模型）
abstract contract BaseTest is Test {
    MockERC20 public usdt;

    HiveAccess public access;
    HiveScore public hiveScore;
    HiveAgent public agentRegistry;
    HiveVault public vault;
    HiveRound public round;

    address public admin = makeAddr("admin");
    address public buyback = makeAddr("buyback");
    address public ops = makeAddr("ops");

    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");
    address public carol = makeAddr("carol");

    function setUp() public virtual {
        vm.startPrank(admin);

        usdt = new MockERC20("Tether USD", "USDT", 6);

        access = new HiveAccess();
        hiveScore = new HiveScore(admin);
        agentRegistry = new HiveAgent(admin, address(access), address(hiveScore));
        vault = new HiveVault(admin, address(usdt), buyback, ops);
        round = new HiveRound(admin, address(vault), address(hiveScore), address(agentRegistry));

        hiveScore.grantRole(hiveScore.ROUND_ROLE(), address(round));
        vault.grantRole(vault.ROUND_ROLE(), address(round));
        agentRegistry.grantRole(agentRegistry.DEFAULT_ADMIN_ROLE(), address(round));

        vm.stopPrank();
    }

    /// @dev 注册 Agent：给主网余额然后调 register()
    function _registerAgent(address agent, uint256 balance) internal {
        vm.deal(agent, balance);
        vm.prank(agent);
        agentRegistry.register();
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

    function _commitHashTyped(bool isUp, uint8 confidence, bytes32 salt) internal pure returns (bytes32) {
        uint8 pred = isUp ? 0 : 1;
        return keccak256(abi.encodePacked(pred, confidence, salt));
    }
}
