// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import {BaseTest} from "../BaseTest.sol";
import {HiveTypes} from "../../src/interfaces/IHiveTypes.sol";

/// @title VaultInvariant — 金库不变量测试
/// @notice 验证无论怎么操作，金库的关键属性始终成立
contract VaultInvariantTest is BaseTest {
    function setUp() public override {
        super.setUp();
        _registerAgent(alice, 15, 200e18);
        _registerAgent(bob, 12, 150e18);
        _fundVault(10_000e6);

        // 给 round 合约更多 USDT 以模拟利润
        usdt.mint(address(vault), 5_000e6);

        targetContract(address(this));
    }

    /// @notice 不变量：Agent 的 pending reward 之和不超过合约 USDT 余额
    function invariant_pendingRewardsNotExceedBalance() public view {
        uint256 aliceReward = vault.pendingReward(alice);
        uint256 bobReward = vault.pendingReward(bob);
        uint256 contractBalance = usdt.balanceOf(address(vault));

        assertTrue(
            aliceReward + bobReward <= contractBalance,
            "pending rewards exceed contract balance"
        );
    }

    /// @notice 不变量：HiveScore 永不为负
    function invariant_scoreNeverNegative() public view {
        assertTrue(hiveScore.getScore(alice) >= 0);
        assertTrue(hiveScore.getScore(bob) >= 0);
    }

    // ─── Handler functions（fuzzer 调用这些函数）────────

    function handler_profitRound() external {
        uint256 profit = 100e6;

        vm.startPrank(admin);
        uint256 rid = round.startRound(84000e8);
        vm.stopPrank();

        bytes32 saltA = keccak256(abi.encodePacked(rid, "alice"));
        bytes32 saltB = keccak256(abi.encodePacked(rid, "bob"));

        vm.prank(alice);
        round.commit(rid, _commitHashTyped(true, 50, saltA));
        vm.prank(bob);
        round.commit(rid, _commitHashTyped(true, 50, saltB));

        vm.prank(admin);
        round.advanceToReveal(rid);

        vm.prank(alice);
        round.reveal(rid, HiveTypes.Prediction.UP, 50, saltA);
        vm.prank(bob);
        round.reveal(rid, HiveTypes.Prediction.UP, 50, saltB);

        vm.prank(admin);
        round.settle(rid, 84500e8, int256(profit));
    }

    function handler_lossRound() external {
        vm.startPrank(admin);
        uint256 rid = round.startRound(84000e8);
        vm.stopPrank();

        bytes32 saltA = keccak256(abi.encodePacked(rid, "alice_loss"));

        vm.prank(alice);
        round.commit(rid, _commitHashTyped(true, 50, saltA));

        vm.prank(admin);
        round.advanceToReveal(rid);

        vm.prank(alice);
        round.reveal(rid, HiveTypes.Prediction.UP, 50, saltA);

        vm.prank(admin);
        round.settle(rid, 83500e8, -int256(50e6));
    }
}
