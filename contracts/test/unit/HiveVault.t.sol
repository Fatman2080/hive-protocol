// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import {BaseTest} from "../BaseTest.sol";

contract HiveVaultTest is BaseTest {
    function setUp() public override {
        super.setUp();
        _fundVault(10_000e6); // 10,000 USDT
    }

    function test_deposit() public view {
        assertEq(vault.treasuryBalance(), 10_000e6);
    }

    function test_currentBetSize() public view {
        // 金库 10,000 × 2% = 200
        assertEq(vault.currentBetSize(), 200e6);
    }

    function test_distributeProfit() public {
        address[] memory agents = new address[](2);
        agents[0] = alice;
        agents[1] = bob;

        uint256[] memory weights = new uint256[](2);
        weights[0] = 700;
        weights[1] = 300;

        uint256 profit = 100e6; // 100 USDT

        // 先把利润 USDT 转给 vault 合约（模拟执行引擎回款）
        usdt.mint(address(vault), profit);

        vm.prank(address(round));
        vault.distributeProfit(1, agents, weights, profit);

        // 35% = 35 USDT 给 agent
        // alice 70% of 35 = 24.5
        // bob   30% of 35 = 10.5
        assertEq(vault.pendingReward(alice), 24_500000);
        assertEq(vault.pendingReward(bob), 10_500000);

        // 40% = 40 retained
        assertEq(vault.treasuryBalance(), 10_000e6 + 40e6);

        // 10% reserve
        assertEq(vault.reserveBalance(), 10e6);

        // buyback + ops 收到
        assertEq(usdt.balanceOf(buyback), 10e6);
        assertEq(usdt.balanceOf(ops), 5e6);
    }

    function test_claim() public {
        address[] memory agents = new address[](1);
        agents[0] = alice;
        uint256[] memory weights = new uint256[](1);
        weights[0] = 100;

        usdt.mint(address(vault), 100e6);

        vm.prank(address(round));
        vault.distributeProfit(1, agents, weights, 100e6);

        uint256 pending = vault.pendingReward(alice);
        assertTrue(pending > 0);

        vm.prank(alice);
        vault.claim();

        assertEq(usdt.balanceOf(alice), pending);
        assertEq(vault.pendingReward(alice), 0);
    }

    function test_recordLoss() public {
        vm.prank(address(round));
        vault.recordLoss(1, 500e6);

        assertEq(vault.treasuryBalance(), 9_500e6);
    }

    function test_recordLoss_uses_reserve() public {
        // 先制造一些 reserve
        usdt.mint(address(vault), 100e6);
        address[] memory agents = new address[](1);
        agents[0] = alice;
        uint256[] memory weights = new uint256[](1);
        weights[0] = 1;
        vm.prank(address(round));
        vault.distributeProfit(1, agents, weights, 100e6);

        uint256 reserveBefore = vault.reserveBalance();
        assertTrue(reserveBefore > 0);

        // 亏损超过 treasury
        uint256 treasuryBefore = vault.treasuryBalance();
        vm.prank(address(round));
        vault.recordLoss(2, treasuryBefore + 5e6);

        // treasury 归零，reserve 被动用
        assertEq(vault.treasuryBalance(), 0);
    }

    function test_onlyRoundRole_can_distribute() public {
        address[] memory agents = new address[](1);
        agents[0] = alice;
        uint256[] memory weights = new uint256[](1);
        weights[0] = 1;

        vm.prank(alice);
        vm.expectRevert();
        vault.distributeProfit(1, agents, weights, 100);
    }
}
