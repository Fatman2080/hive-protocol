// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {HiveAccess} from "../../src/HiveAccess.sol";
import {HiveTypes} from "../../src/interfaces/IHiveTypes.sol";

contract HiveAccessTest is Test {
    HiveAccess public access;

    function setUp() public {
        access = new HiveAccess();
    }

    function test_calculateTier_none() public view {
        assertEq(uint256(access.calculateTier(0)), uint256(HiveTypes.Tier.NONE));
        assertEq(uint256(access.calculateTier(99e18)), uint256(HiveTypes.Tier.NONE));
    }

    function test_calculateTier_bronze() public view {
        assertEq(uint256(access.calculateTier(100e18)), uint256(HiveTypes.Tier.BRONZE));
        assertEq(uint256(access.calculateTier(499e18)), uint256(HiveTypes.Tier.BRONZE));
    }

    function test_calculateTier_silver() public view {
        assertEq(uint256(access.calculateTier(500e18)), uint256(HiveTypes.Tier.SILVER));
    }

    function test_calculateTier_gold() public view {
        assertEq(uint256(access.calculateTier(2000e18)), uint256(HiveTypes.Tier.GOLD));
    }

    function test_calculateTier_diamond() public view {
        assertEq(uint256(access.calculateTier(5000e18)), uint256(HiveTypes.Tier.DIAMOND));
    }

    function test_tierConfig_confidence_caps() public view {
        assertEq(access.maxAllowedConfidence(HiveTypes.Tier.BRONZE), 70);
        assertEq(access.maxAllowedConfidence(HiveTypes.Tier.SILVER), 85);
        assertEq(access.maxAllowedConfidence(HiveTypes.Tier.GOLD), 95);
        assertEq(access.maxAllowedConfidence(HiveTypes.Tier.DIAMOND), 100);
    }

    function test_tierConfig_daily_caps() public view {
        assertEq(access.dailyRoundCap(HiveTypes.Tier.BRONZE), 30);
        assertEq(access.dailyRoundCap(HiveTypes.Tier.DIAMOND), 96);
    }

    function testFuzz_calculateTier_bounded(uint256 balance) public view {
        balance = bound(balance, 0, 10_000e18);

        HiveTypes.Tier tier = access.calculateTier(balance);
        // 等级应该在 NONE 到 DIAMOND 之间
        assertTrue(uint256(tier) <= uint256(HiveTypes.Tier.DIAMOND));
    }
}
