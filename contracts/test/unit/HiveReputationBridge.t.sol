// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import {BaseTest} from "../BaseTest.sol";
import {HiveReputationBridge} from "../../src/HiveReputationBridge.sol";

contract HiveReputationBridgeTest is BaseTest {
    HiveReputationBridge public bridge;

    function setUp() public override {
        super.setUp();
        vm.prank(admin);
        bridge = new HiveReputationBridge(admin, address(hiveScore));
    }

    function test_recordRound_startsEpoch() public {
        vm.prank(admin);
        bridge.recordRound(alice, true);

        assertEq(bridge.currentEpoch(), 1);
    }

    function test_epochFlush_at_50_rounds() public {
        vm.startPrank(admin);

        // 记录 49 轮（不触发 flush）
        for (uint256 i = 0; i < 49; i++) {
            bridge.recordRound(alice, i % 2 == 0); // 交替对错
        }

        (,,bool flushed1) = _getEpochRecord(1);
        assertFalse(flushed1);

        // 第 50 轮触发 flush
        bridge.recordRound(alice, true);

        (,,bool flushed2) = _getEpochRecord(1);
        assertTrue(flushed2);

        vm.stopPrank();
    }

    function test_reputationDelta_highAccuracy() public {
        vm.startPrank(admin);

        // 50 轮中 45 轮正确 (90% → delta = +2)
        for (uint256 i = 0; i < 50; i++) {
            bridge.recordRound(alice, i < 45);
        }

        (uint256 rounds, uint256 correct, uint256 rateBps) = bridge.getAgentEpochStats(1, alice);
        assertEq(rounds, 50);
        assertEq(correct, 45);
        assertEq(rateBps, 9000); // 90%

        vm.stopPrank();
    }

    function test_reputationDelta_lowAccuracy() public {
        vm.startPrank(admin);

        // 50 轮中 8 轮正确 (16% → delta = -2)
        for (uint256 i = 0; i < 50; i++) {
            bridge.recordRound(alice, i < 8);
        }

        (,, uint256 rateBps) = bridge.getAgentEpochStats(1, alice);
        assertEq(rateBps, 1600); // 16%

        vm.stopPrank();
    }

    function test_multipleAgents_inEpoch() public {
        vm.startPrank(admin);

        // 每次 recordRound 计入 roundsSinceLastFlush
        // epoch flush at 50 calls，所以 epoch 1 有 50 条记录
        // 两个 agent 交替 → 每人 25 条在 epoch 1
        for (uint256 i = 0; i < 50; i++) {
            bridge.recordRound(alice, true);
            bridge.recordRound(bob, false);
        }

        // epoch 1: 前 50 条（alice 25, bob 25），epoch 2: 后 50 条
        (uint256 aRounds,,) = bridge.getAgentEpochStats(1, alice);
        (uint256 bRounds,,) = bridge.getAgentEpochStats(1, bob);
        assertEq(aRounds, 25);
        assertEq(bRounds, 25);

        // epoch 2 中两人各 25 条
        (uint256 aRounds2,,) = bridge.getAgentEpochStats(2, alice);
        assertEq(aRounds2, 25);

        vm.stopPrank();
    }

    function test_manualFlush() public {
        vm.startPrank(admin);

        for (uint256 i = 0; i < 10; i++) {
            bridge.recordRound(alice, true);
        }

        bridge.manualFlush();

        (,,bool flushed) = _getEpochRecord(1);
        assertTrue(flushed);

        vm.stopPrank();
    }

    function test_getEpochAgents() public {
        vm.startPrank(admin);

        bridge.recordRound(alice, true);
        bridge.recordRound(bob, true);
        bridge.recordRound(carol, false);

        address[] memory agents = bridge.getEpochAgents(1);
        assertEq(agents.length, 3);

        vm.stopPrank();
    }

    function _getEpochRecord(uint256 epoch) internal view returns (uint256 agentCount, uint256 ts, bool flushed) {
        (, ts, agentCount, flushed) = bridge.epochs(epoch);
    }
}
