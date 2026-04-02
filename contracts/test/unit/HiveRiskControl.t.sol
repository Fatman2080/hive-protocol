// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import {BaseTest} from "../BaseTest.sol";
import {HiveRiskControl} from "../../src/HiveRiskControl.sol";

contract HiveRiskControlTest is BaseTest {
    HiveRiskControl public riskControl;

    function setUp() public override {
        super.setUp();

        // 设置合理的时间戳（2026-04-01 00:00 UTC = 1774915200）
        vm.warp(1774915200);

        vm.prank(admin);
        riskControl = new HiveRiskControl(admin);

        vm.prank(admin);
        riskControl.updateReferenceBalance(10_000e6);
    }

    function test_canProceed_initially() public view {
        (bool allowed,) = riskControl.canProceed(1);
        assertTrue(allowed);
    }

    function test_consecutiveLoss_pause() public {
        vm.startPrank(admin);

        // 连亏 5 轮
        for (uint256 i = 1; i <= 5; i++) {
            riskControl.recordResult(i, -int256(100e6), 10_000e6);
        }

        // 第 6 轮应被暂停
        (bool allowed, string memory reason) = riskControl.canProceed(6);
        assertFalse(allowed);
        assertEq(reason, "consecutive loss pause");

        // 第 9 轮（暂停 3 轮后）应该可以
        (allowed,) = riskControl.canProceed(9);
        assertTrue(allowed);

        vm.stopPrank();
    }

    function test_dailyLoss_circuitBreaker() public {
        vm.startPrank(admin);

        // 日亏损 800 USDT = 8% of 10,000
        riskControl.recordResult(1, -int256(800e6), 10_000e6);

        (bool allowed, string memory reason) = riskControl.canProceed(2);
        assertFalse(allowed);
        assertEq(reason, "daily loss limit");

        vm.stopPrank();
    }

    function test_dailyReset_nextDay() public {
        vm.startPrank(admin);

        // 今天亏
        riskControl.recordResult(1, -int256(800e6), 10_000e6);
        (bool allowed,) = riskControl.canProceed(2);
        assertFalse(allowed);

        // 跳到明天
        vm.warp(block.timestamp + 1 days);

        (allowed,) = riskControl.canProceed(100);
        assertTrue(allowed);

        vm.stopPrank();
    }

    function test_emergencyPause() public {
        vm.prank(admin);
        riskControl.emergencyPause("suspicious activity");

        (bool allowed, string memory reason) = riskControl.canProceed(1);
        assertFalse(allowed);
        assertEq(reason, "emergency paused");

        vm.prank(admin);
        riskControl.emergencyResume();

        (allowed,) = riskControl.canProceed(1);
        assertTrue(allowed);
    }

    function test_winResets_consecutiveLosses() public {
        vm.startPrank(admin);

        // 亏 4 轮
        for (uint256 i = 1; i <= 4; i++) {
            riskControl.recordResult(i, -int256(10e6), 10_000e6);
        }
        assertEq(riskControl.consecutiveLosses(), 4);

        // 赢 1 轮
        riskControl.recordResult(5, int256(50e6), 10_000e6);
        assertEq(riskControl.consecutiveLosses(), 0);

        vm.stopPrank();
    }

    function test_getDailyStats() public {
        vm.startPrank(admin);

        riskControl.recordResult(1, int256(100e6), 10_000e6);
        riskControl.recordResult(2, -int256(50e6), 10_000e6);

        (int256 pnl, uint256 rounds, uint256 losses) = riskControl.getDailyStats();
        assertEq(pnl, 50e6);
        assertEq(rounds, 2);
        assertEq(losses, 1);

        vm.stopPrank();
    }

    function test_weeklyLoss_triggers48hPause() public {
        vm.startPrank(admin);

        // 分三天累计亏损 1500 USDT = 15% of 10,000
        // 第一天亏 600（< 8% daily limit）
        riskControl.recordResult(1, -int256(600e6), 10_000e6);

        // 第二天亏 600
        vm.warp(block.timestamp + 1 days);
        riskControl.recordResult(2, -int256(600e6), 10_000e6);

        // 第三天亏 300，累计 1500 → 触发 weekly
        vm.warp(block.timestamp + 1 days);
        riskControl.recordResult(3, -int256(300e6), 10_000e6);

        (bool allowed, string memory reason) = riskControl.canProceed(10);
        assertFalse(allowed);
        assertEq(reason, "time-based pause active"); // 48h 暂停

        vm.stopPrank();
    }
}
