// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {MockUSDC} from "../../src/MockUSDC.sol";
import {ComplianceRegistry} from "../../src/ComplianceRegistry.sol";
import {TBillToken} from "../../src/TBillToken.sol";
import {TBillVault} from "../../src/TBillVault.sol";
import {MockPriceFeed} from "../../src/exercises/MockPriceFeed.sol";
import {MockTBillCustodian} from "../../src/exercises/MockTBillCustodian.sol";

/// @title Ex2 + Ex3 + Ex4 —— 桥的三块木板：托管 (a)、attestation (b)、准入 (d)
/// @notice 桥是链下资产变成链上代币的装置。下面的每个练习各拉一块木板，
///         让你看到是什么在支撑这座桥——以及什么没有。
///         第四块木板“赎回 (c)”是你在 Ex5 里要写的队列。
///
///         下面每一个 `assertTrue(false, "TODO ...")` 都是占位符。写出真正的断言，
///         看着测试变绿，那个练习就完成了。
///
///         验收：make exercise（完成前应该是红的）。
///         不要打开 test/TBill.t.sol——它里面有答案。先写你自己的，卡住了再看。
contract BridgeTasksTest is Test {
    MockUSDC internal usdc;
    ComplianceRegistry internal compliance;
    MockPriceFeed internal feed;
    TBillToken internal tBill;
    MockTBillCustodian internal custodian;
    TBillVault internal vault;

    address internal admin = address(this);
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal attacker = makeAddr("attacker");

    uint256 internal constant PAR = 1e8;
    uint256 internal constant NAV_1_25 = 1.25e8;

    function setUp() public {
        usdc = new MockUSDC();
        compliance = new ComplianceRegistry(admin);
        feed = new MockPriceFeed(int256(PAR));
        tBill = new TBillToken(admin, compliance);
        custodian = new MockTBillCustodian(admin);
        vault = new TBillVault(usdc, tBill, feed, custodian, admin);

        tBill.grantRole(tBill.MINTER_ROLE(), address(vault));
        custodian.grantRole(custodian.CUSTODIAN_ROLE(), address(vault));

        compliance.setWhitelisted(admin, true);
        compliance.setWhitelisted(alice, true);
        compliance.setWhitelisted(bob, true);
    }

    /// @dev 给定：支付 `assets` 数量的 USDC，按今天的 NAV 换取份额
    function _subscribe(address user, uint256 assets) internal {
        usdc.faucet(user, assets);
        vm.startPrank(user);
        usdc.approve(address(vault), assets);
        vault.subscribe(assets);
        vm.stopPrank();
    }

    // ==================================================================
    // Ex2 · 木板 (a) 托管 —— 份额存在，箱子可能不存在
    // ==================================================================

    /// @dev 按 par 申购 1000 USDC，然后同时看桥的两侧：
    ///      alice 现在持有的份额，以及托管人实际持有什么。
    ///      提示：_subscribe(alice, 1_000e6)，然后比较 tBill.balanceOf(alice) 与
    ///      custodian.realHoldings()。一个是 1000e18，另一个是 0。两个都断言，
    ///      然后问自己：到底哪一个合约和 custodian 说过话？
    function test_Ex2_SharesExistWhileTheCustodianHoldsNothing() public {
        _subscribe(alice, 1_000e6);

        // subscribe 只做三件事：收 USDC、按 NAV 算份额、mint 给 alice。
        // 它从头到尾没有调用 custodian，所以份额在买 T-Bill 之前就已经存在。
        assertEq(tBill.balanceOf(alice), 1_000e18, "alice holds 1000 shares");
        assertEq(tBill.totalSupply(), 1_000e18, "alice's shares are the whole supply");
        assertEq(vault.reserveBalance(), 1_000e6, "the USDC is in the vault");
        assertEq(custodian.realHoldings(), 0, "the custodian reports zero T-Bills");
    }

    /// @dev 托管人的 `treasury` 是一个有权限的地址可以移动的数字。证明这个
    ///      “背书”是一个敲进去的整数，而不是到账的现金。
    ///      提示：recordPurchase 是 onlyRole(CUSTODIAN_ROLE)，`admin` 持有它。调用
    ///      custodian.recordPurchase(1_000_000e6)，然后断言 realHoldings() 跳变，
    ///      而 usdc.balanceOf(address(custodian)) 仍然是 0。
    function test_Ex2_RealHoldingsIsJustANumber() public {
        uint256 reported = 1_000_000e6;

        // recordPurchase 由 CUSTODIAN_ROLE 控制，测试合约（admin）持有这个角色。
        // 它只改 custodian 账面上的 treasury，不移动任何 USDC：
        // 链上相信的这个数字是敲进去的，不是现金到账的结果。
        assertEq(custodian.realHoldings(), 0, "the custodian starts at zero");
        custodian.recordPurchase(reported);
        assertEq(custodian.realHoldings(), reported, "the reported holdings jumped");
        assertEq(usdc.balanceOf(address(custodian)), 0, "but no USDC arrived");
    }

    // ==================================================================
    // Ex3 · 木板 (b) attestation —— 链上唯一的窗口是一个数字
    // ==================================================================

    /// @dev 按 par 申购，然后让报告人把 NAV 调高。断言两件事，它们让这个系统
    ///      成为 RWA 而不是稳定币：份额“数量”不变，头寸的“价值”变了。
    ///      稳定币会保持 1:1。
    ///      提示：_subscribe(alice, 1_000e6)；读 tBill.balanceOf(alice) 和
    ///      vault.totalClaimValue()；然后 vault.attest(int256(NAV_1_25))；再读一次。
    ///      份额保持 1000e18；索取权从 1000e6 -> 1250e6。
    function test_Ex3_TheClaimFloats_TheShareCountDoesNot() public {
        _subscribe(alice, 1_000e6);

        uint256 sharesBefore = tBill.balanceOf(alice);
        uint256 claimBefore = vault.totalClaimValue();
        assertEq(sharesBefore, 1_000e18, "alice holds 1000 shares");
        assertEq(claimBefore, 1_000e6, "the claim starts at 1000 USDC");

        // 只改 NAV：不移动 USDC，也不 mint/burn 份额。
        vault.attest(int256(NAV_1_25));

        // 份额是数量，NAV 是单价；单价变了，数量不变，价值变。
        assertEq(tBill.balanceOf(alice), sharesBefore, "the share count does not move");
        assertEq(vault.totalClaimValue(), 1_250e6, "the book is re-priced to 1250 USDC");
        assertEq(vault.assetsForShares(tBill.balanceOf(alice)), 1_250e6, "alice's claim moved");
        assertEq(vault.reserveBalance(), 1_000e6, "the vault's cash did not move");
        assertEq(custodian.realHoldings(), 0, "the custodian still reports nothing");
    }

    /// @dev 一个数字重估整本账。两个持有人、一次调用，两个 claim value 同时变。
    ///      attest 由 REPORTER_ROLE 控制——`admin` 持有它——但下游没有任何东西
    ///      能质疑它写下的数字。
    ///      提示：先 _subscribe alice 和 bob，然后 vault.attest。单个持有人的 claim value
    ///      是 vault.assetsForShares(tBill.balanceOf(who))。选一个适中的 NAV（例如 50e8），
    ///      让总数保持小且可读。
    function test_Ex3_OneCallMovesTheWholeBook() public {
        _subscribe(alice, 1_000e6);
        _subscribe(bob, 1_000e6);

        assertEq(vault.totalClaimValue(), 2_000e6, "the book starts at 2000 USDC");

        // 一个报告人写一个数字，整本账按同一个 NAV 重估。
        vault.attest(int256(50e8));

        // 两个持有人、一次 attest、两本账同时变；份额数量都不变。
        assertEq(vault.assetsForShares(tBill.balanceOf(alice)), 50_000e6, "alice: 1000 -> 50k");
        assertEq(vault.assetsForShares(tBill.balanceOf(bob)), 50_000e6, "bob: 1000 -> 50k");
        assertEq(vault.totalClaimValue(), 100_000e6, "the whole book is 100k");
        assertEq(tBill.balanceOf(alice), 1_000e18, "alice's share count is unchanged");
        assertEq(tBill.balanceOf(bob), 1_000e18, "bob's share count is unchanged");

        // 账面价值涨了 98k，但链上的现金和托管报告都没有动。
        assertEq(vault.reserveBalance(), 2_000e6, "the vault's cash did not move");
        assertEq(custodian.realHoldings(), 0, "the custodian still reports nothing");
    }

    // ==================================================================
    // Ex4 · 木板 (d) 准入 —— 守卫在哪里，钥匙在谁手里
    // ==================================================================

    /// @dev 一个从未通过 KYC 的地址收不到份额，即使付了钱也不行。
    ///      提示：先给 attacker faucet 并 approve vault，否则你会因为错误的原因 revert。
    ///      然后用 vm.expectRevert + abi.encodeWithSelector 钉死
    ///      TBillToken.NotWhitelisted(attacker)。模糊的“它 revert 了”在守卫被移除后
    ///      依然是绿的，所以必须断言精确的 selector。
    function test_Ex4_NoKyc_NoShares_EvenIfYouPay() public {
        // 先给 attacker 钱并授权，否则 revert 的原因可能是余额/额度，而不是白名单。
        usdc.faucet(attacker, 1_000e6);
        vm.startPrank(attacker);
        usdc.approve(address(vault), 1_000e6);

        // 钉死错误选择器：必须是 NotWhitelisted(attacker)，不是模糊的“它 revert 了”。
        vm.expectRevert(abi.encodeWithSelector(TBillToken.NotWhitelisted.selector, attacker));
        vault.subscribe(1_000e6);
        vm.stopPrank();

        // 整笔订阅回滚：attacker 没拿到份额，钱也还在。
        assertEq(tBill.balanceOf(attacker), 0, "attacker received no shares");
        assertEq(usdc.balanceOf(attacker), 1_000e6, "the subscription was rolled back");
        assertEq(vault.reserveBalance(), 0, "no USDC entered the vault");
    }

    /// @dev 白名单持有人也不能把份额“发送”给非白名单地址——
    ///      _update 检查两端，不只是发送方。
    ///      提示：alice 先申购，然后 alice 调用 tBill.transfer(attacker, 1e18)。把 revert
    ///      钉在 NotWhitelisted(attacker) 上——注意错误里出现的是“哪一个”地址。
    function test_Ex4_TransferChecksBothEndpoints() public {
        _subscribe(alice, 1_000e6);

        // alice 在白名单上，但接收方 attacker 不在；错误里出现的是 attacker。
        vm.startPrank(alice);
        vm.expectRevert(abi.encodeWithSelector(TBillToken.NotWhitelisted.selector, attacker));
        tBill.transfer(attacker, 1e18);
        vm.stopPrank();

        assertEq(tBill.balanceOf(alice), 1_000e18, "alice's shares did not move");
        assertEq(tBill.balanceOf(attacker), 0, "attacker received nothing");
    }

    /// @dev 把一个地址移出名单会冻结这个持有人——而且比看起来更强。同一个 _update
    ///      守卫也挡在 burn() 前面，所以一旦 alice 被移出名单，发行人也无法没收她的份额。
    ///      提示：alice 先申购；compliance.setWhitelisted(alice, false)；断言 alice 的
    ///      transfer revert；然后断言 admin 调用的 tBill.burn(alice, 1_000e18) 也
    ///      以 NotWhitelisted(alice) revert。不要用 pause()——那是全局开关，
    ///      是另一个问题（STUDENT-QUESTIONS.md C2）。
    function test_Ex4_FreezeBeatsConfiscation() public {
        _subscribe(alice, 1_000e6);

        // 把 alice 移出名单：她不能再转出。
        compliance.setWhitelisted(alice, false);

        vm.startPrank(alice);
        vm.expectRevert(abi.encodeWithSelector(TBillToken.NotWhitelisted.selector, alice));
        tBill.transfer(bob, 1e18);
        vm.stopPrank();

        // 同一个 _update 守卫也挡在 burn 前面：admin 也无法没收 alice 的份额。
        vm.expectRevert(abi.encodeWithSelector(TBillToken.NotWhitelisted.selector, alice));
        tBill.burn(alice, 1_000e18);

        assertEq(tBill.balanceOf(alice), 1_000e18, "alice's shares are frozen, not seized");
        assertEq(tBill.balanceOf(bob), 0, "bob received nothing");
    }
}
