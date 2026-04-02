// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import {BaseTest} from "../BaseTest.sol";

contract HiveScoreTest is BaseTest {
    function setUp() public override {
        super.setUp();
    }

    function test_initialScore() public view {
        assertEq(hiveScore.getScore(alice), hiveScore.INITIAL_SCORE());
    }

    function test_correctPrediction_increases_score() public {
        vm.prank(address(round));
        hiveScore.updateScore(alice, true, 50);

        // delta = 1 + 50/50 = 2，初始分为 0
        assertEq(hiveScore.getScore(alice), 2);
    }

    function test_wrongPrediction_decreases_score() public {
        vm.prank(address(round));
        hiveScore.updateScore(alice, false, 50);

        // delta = -(1 + 50/50) = -2，不得低于 0
        assertEq(hiveScore.getScore(alice), 0);
    }

    function test_streak_tracking() public {
        vm.startPrank(address(round));

        hiveScore.updateScore(alice, true, 30);
        assertEq(hiveScore.getStreak(alice), 1);

        hiveScore.updateScore(alice, true, 30);
        assertEq(hiveScore.getStreak(alice), 2);

        // 连胜到 3，触发额外 +1
        hiveScore.updateScore(alice, true, 30);
        assertEq(hiveScore.getStreak(alice), 3);

        // 错了，streak 重置
        hiveScore.updateScore(alice, false, 30);
        assertEq(hiveScore.getStreak(alice), -1);

        vm.stopPrank();
    }

    function test_streak_bonus_at_3() public {
        vm.startPrank(address(round));

        // confidence=30: delta = 1 + 30/50 = 1
        hiveScore.updateScore(alice, true, 30); // 0 + 1 = 1
        hiveScore.updateScore(alice, true, 30); // 1 + 1 = 2
        hiveScore.updateScore(alice, true, 30); // 2 + 1 + 1(streak bonus) = 4

        assertEq(hiveScore.getScore(alice), 4);
        vm.stopPrank();
    }

    function test_score_never_below_zero() public {
        vm.startPrank(address(round));

        // 大量连续错误，confidence 高
        for (uint256 i = 0; i < 50; i++) {
            hiveScore.updateScore(alice, false, 99);
        }

        assertEq(hiveScore.getScore(alice), 0);
        vm.stopPrank();
    }

    function test_winRate() public {
        vm.startPrank(address(round));

        hiveScore.updateScore(alice, true, 50);
        hiveScore.updateScore(alice, true, 50);
        hiveScore.updateScore(alice, false, 50);
        hiveScore.updateScore(alice, true, 50);

        vm.stopPrank();

        (uint256 rate, uint256 total) = hiveScore.getWinRate(alice);
        assertEq(total, 4);
        assertEq(rate, 7500); // 75%
    }

    function test_onlyRoundRole_can_update() public {
        vm.prank(alice);
        vm.expectRevert();
        hiveScore.updateScore(alice, true, 50);
    }
}
