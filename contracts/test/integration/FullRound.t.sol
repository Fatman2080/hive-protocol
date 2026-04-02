// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import {BaseTest} from "../BaseTest.sol";
import {HiveTypes} from "../../src/interfaces/IHiveTypes.sol";
import {console} from "forge-std/console.sol";

/// @title FullRoundTest — 端到端集成测试
/// @notice 验证从 Agent 注册 → commit → reveal → 结算 → 分润的完整流程
contract FullRoundTest is BaseTest {
    bytes32 constant SALT_ALICE = keccak256("alice_salt");
    bytes32 constant SALT_BOB = keccak256("bob_salt");
    bytes32 constant SALT_CAROL = keccak256("carol_salt");

    function setUp() public override {
        super.setUp();

        // 注册 3 个 Agent（青铜等级：声誉 ≥ 10, 质押 ≥ 100 AXON）
        _registerAgent(alice, 15, 200e18);
        _registerAgent(bob, 12, 150e18);
        _registerAgent(carol, 20, 300e18);

        // 金库注入 10,000 USDT
        _fundVault(10_000e6);
    }

    /// @notice 完整盈利轮次：3 个 Agent 预测，2 个正确，1 个错误
    function test_fullRound_profit() public {
        // ─── 1. 开启轮次 ───────────────────────────
        vm.prank(admin);
        uint256 roundId = round.startRound(84000e8);

        assertEq(roundId, 1);
        HiveTypes.RoundData memory rd = round.getRound(roundId);
        assertEq(uint256(rd.phase), uint256(HiveTypes.RoundPhase.COMMIT));

        // ─── 2. Commit 阶段 ────────────────────────
        // Alice: UP, confidence 60
        vm.prank(alice);
        round.commit(roundId, _commitHashTyped(true, 60, SALT_ALICE));

        // Bob: UP, confidence 50
        vm.prank(bob);
        round.commit(roundId, _commitHashTyped(true, 50, SALT_BOB));

        // Carol: DOWN, confidence 40
        vm.prank(carol);
        round.commit(roundId, _commitHashTyped(false, 40, SALT_CAROL));

        // ─── 3. 推进到 Reveal ──────────────────────
        vm.prank(admin);
        round.advanceToReveal(roundId);

        // ─── 4. Reveal 阶段 ────────────────────────
        vm.prank(alice);
        round.reveal(roundId, HiveTypes.Prediction.UP, 60, SALT_ALICE);

        vm.prank(bob);
        round.reveal(roundId, HiveTypes.Prediction.UP, 50, SALT_BOB);

        vm.prank(carol);
        round.reveal(roundId, HiveTypes.Prediction.DOWN, 40, SALT_CAROL);

        // 验证权重聚合
        rd = round.getRound(roundId);
        assertTrue(rd.upWeight > 0);
        assertTrue(rd.downWeight > 0);
        assertEq(rd.participantCount, 3);

        // ─── 5. 结算（BTC 涨了 → UP 正确）─────────
        // 模拟：执行引擎从 Polymarket 赚了 100 USDT
        int256 profit = int256(100e6);
        usdt.mint(address(vault), uint256(profit)); // 利润入库

        vm.prank(admin);
        round.settle(roundId, 84500e8, profit); // 收盘价 > 开盘价 → UP

        // ─── 6. 验证结果 ──────────────────────────
        rd = round.getRound(roundId);
        assertEq(uint256(rd.phase), uint256(HiveTypes.RoundPhase.SETTLED));
        assertEq(rd.profitLoss, profit);

        // Alice 和 Bob 预测 UP（正确），应有奖励
        assertTrue(vault.pendingReward(alice) > 0, "alice should have reward");
        assertTrue(vault.pendingReward(bob) > 0, "bob should have reward");

        // Carol 预测 DOWN（错误），不应有奖励
        assertEq(vault.pendingReward(carol), 0, "carol should have no reward");

        // Alice 权重更高（confidence 60 > Bob 50），分到更多
        assertTrue(vault.pendingReward(alice) > vault.pendingReward(bob), "alice > bob reward");

        // HiveScore 验证
        assertTrue(hiveScore.getScore(alice) > hiveScore.INITIAL_SCORE(), "alice score up");
        assertTrue(hiveScore.getScore(bob) > hiveScore.INITIAL_SCORE(), "bob score up");
        assertTrue(hiveScore.getScore(carol) < hiveScore.INITIAL_SCORE(), "carol score down");

        // 金库留存增加
        assertTrue(vault.treasuryBalance() > 10_000e6, "treasury grew");

        console.log("Alice reward:", vault.pendingReward(alice));
        console.log("Bob reward:", vault.pendingReward(bob));
        console.log("Treasury after:", vault.treasuryBalance());
        console.log("Reserve:", vault.reserveBalance());
    }

    /// @notice 完整亏损轮次
    function test_fullRound_loss() public {
        vm.prank(admin);
        uint256 roundId = round.startRound(84000e8);

        // 所有人预测 UP
        vm.prank(alice);
        round.commit(roundId, _commitHashTyped(true, 50, SALT_ALICE));
        vm.prank(bob);
        round.commit(roundId, _commitHashTyped(true, 50, SALT_BOB));

        vm.prank(admin);
        round.advanceToReveal(roundId);

        vm.prank(alice);
        round.reveal(roundId, HiveTypes.Prediction.UP, 50, SALT_ALICE);
        vm.prank(bob);
        round.reveal(roundId, HiveTypes.Prediction.UP, 50, SALT_BOB);

        uint256 treasuryBefore = vault.treasuryBalance();

        // BTC 跌了 → UP 错误，亏损 200 USDT
        vm.prank(admin);
        round.settle(roundId, 83500e8, -int256(200e6));

        // 金库减少
        assertTrue(vault.treasuryBalance() < treasuryBefore, "treasury decreased");

        // 所有人 score 下降
        assertTrue(hiveScore.getScore(alice) < hiveScore.INITIAL_SCORE());
        assertTrue(hiveScore.getScore(bob) < hiveScore.INITIAL_SCORE());
    }

    /// @notice 信号不足跳过轮次
    function test_fullRound_skip_insufficient_signal() public {
        vm.prank(admin);
        uint256 roundId = round.startRound(84000e8);

        // Alice: UP conf 50, Bob: DOWN conf 50 → 50/50 < 60% 阈值
        vm.prank(alice);
        round.commit(roundId, _commitHashTyped(true, 50, SALT_ALICE));
        vm.prank(bob);
        round.commit(roundId, _commitHashTyped(false, 50, SALT_BOB));

        vm.prank(admin);
        round.advanceToReveal(roundId);

        vm.prank(alice);
        round.reveal(roundId, HiveTypes.Prediction.UP, 50, SALT_ALICE);
        vm.prank(bob);
        round.reveal(roundId, HiveTypes.Prediction.DOWN, 50, SALT_BOB);

        uint256 treasuryBefore = vault.treasuryBalance();

        // 结算（传 0 profitLoss，因为跳过了没下注）
        vm.prank(admin);
        round.settle(roundId, 84100e8, 0);

        // 金库不变（跳过轮次）
        assertEq(vault.treasuryBalance(), treasuryBefore);
    }

    /// @notice commit hash 不匹配应 revert
    function test_reveal_wrong_hash_reverts() public {
        vm.prank(admin);
        uint256 roundId = round.startRound(84000e8);

        vm.prank(alice);
        round.commit(roundId, _commitHashTyped(true, 60, SALT_ALICE));

        vm.prank(admin);
        round.advanceToReveal(roundId);

        // Alice 试图用不同的 direction reveal
        vm.prank(alice);
        vm.expectRevert("HiveRound: hash mismatch");
        round.reveal(roundId, HiveTypes.Prediction.DOWN, 60, SALT_ALICE);
    }

    /// @notice 不能重复 commit
    function test_double_commit_reverts() public {
        vm.prank(admin);
        uint256 roundId = round.startRound(84000e8);

        vm.prank(alice);
        round.commit(roundId, _commitHashTyped(true, 50, SALT_ALICE));

        vm.prank(alice);
        vm.expectRevert("HiveRound: already committed");
        round.commit(roundId, _commitHashTyped(false, 50, SALT_ALICE));
    }

    /// @notice 未注册 Agent 不能参与
    function test_unregistered_cannot_commit() public {
        address stranger = makeAddr("stranger");

        vm.prank(admin);
        uint256 roundId = round.startRound(84000e8);

        vm.prank(stranger);
        vm.expectRevert("HiveRound: agent not active");
        round.commit(roundId, _commitHashTyped(true, 50, SALT_ALICE));
    }

    /// @notice 信心度超过等级上限应 revert
    function test_confidence_exceeds_tier_limit() public {
        vm.prank(admin);
        uint256 roundId = round.startRound(84000e8);

        // Alice 是 BRONZE，信心度上限 70
        bytes32 hash = _commitHashTyped(true, 80, SALT_ALICE);
        vm.prank(alice);
        round.commit(roundId, hash);

        vm.prank(admin);
        round.advanceToReveal(roundId);

        vm.prank(alice);
        vm.expectRevert("HiveRound: confidence exceeds tier limit");
        round.reveal(roundId, HiveTypes.Prediction.UP, 80, SALT_ALICE);
    }

    /// @notice Agent 可以领取奖励
    function test_agent_can_claim_rewards() public {
        // 先跑一轮盈利
        test_fullRound_profit();

        uint256 aliceReward = vault.pendingReward(alice);
        assertTrue(aliceReward > 0);

        vm.prank(alice);
        vault.claim();

        assertEq(usdt.balanceOf(alice), aliceReward);
        assertEq(vault.pendingReward(alice), 0);
    }

    /// @notice 多轮连续运行（全部盈利轮，验证连续运行稳定性）
    function test_multipleRounds() public {
        for (uint256 i = 0; i < 5; i++) {
            uint256 openPrice = 84000e8 + i * 100e8;

            vm.prank(admin);
            uint256 rid = round.startRound(openPrice);

            // 两人都预测 UP，confidence 50（青铜上限 70 内）
            vm.prank(alice);
            round.commit(rid, _commitHashTyped(true, 50, bytes32(i)));
            vm.prank(bob);
            round.commit(rid, _commitHashTyped(true, 50, bytes32(i + 100)));

            vm.prank(admin);
            round.advanceToReveal(rid);

            vm.prank(alice);
            round.reveal(rid, HiveTypes.Prediction.UP, 50, bytes32(i));
            vm.prank(bob);
            round.reveal(rid, HiveTypes.Prediction.UP, 50, bytes32(i + 100));

            // 每轮盈利 50 USDT，closePrice > openPrice → UP 正确
            usdt.mint(address(vault), 50e6);

            vm.prank(admin);
            round.settle(rid, openPrice + 200e8, int256(50e6));
        }

        assertEq(round.currentRoundId(), 5);
        (uint256 rate,) = hiveScore.getWinRate(alice);
        assertEq(rate, 10000); // 100% 胜率
    }
}
