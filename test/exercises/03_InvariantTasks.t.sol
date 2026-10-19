// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {MockUSDC} from "../../src/MockUSDC.sol";
import {ComplianceRegistry} from "../../src/ComplianceRegistry.sol";
import {TBillToken} from "../../src/TBillToken.sol";
import {TBillVault} from "../../src/TBillVault.sol";
import {MockPriceFeed} from "../../src/exercises/MockPriceFeed.sol";
import {MockTBillCustodian} from "../../src/exercises/MockTBillCustodian.sol";
import {RedemptionQueue} from "../../src/exercises/RedemptionQueue.sol";

/// @title Ex6 —— 桥的两条不变量
/// @notice 不变量测试把普通测试反过来：让机器随机、连续地调用操作，
///         然后问「无论怎么折腾，这条性质还在不在？」桥就应该这样测——
///         你永远猜不到攻击者会以什么顺序做事。
///
///         验收：make exercise（完成前应该是红的）。
///
/// @dev Ex6 依赖 Ex5：下面的 handler 调用 enqueue / settle / claim，
///      也就是你在 RedemptionQueue.sol 里实现的四个函数。先完成 Ex5，
///      否则 fuzzer 只会看到 revert。
///
///      工作原理：Foundry 从 handler 里随机挑一个函数、随机挑参数、调用它，
///      重复 N 次；每一轮之后运行所有 invariant_* 函数。第一个失败的断言
///      就是反例。
contract BridgeHandler is Test {
    MockUSDC internal usdc;
    TBillToken internal tBill;
    TBillVault internal vault;
    RedemptionQueue internal queue;

    address[3] public users;

    /// @dev 记账：证明 fuzzer 真的调到了 handler，而不是在空转
    uint256 public ghost_enqueues;
    uint256 public ghost_settles;
    uint256 public ghost_claims;

    constructor(MockUSDC usdc_, TBillToken tBill_, TBillVault vault_, RedemptionQueue queue_) {
        usdc = usdc_;
        tBill = tBill_;
        vault = vault_;
        queue = queue_;

        users[0] = makeAddr("user0");
        users[1] = makeAddr("user1");
        users[2] = makeAddr("user2");
        for (uint256 i; i < users.length; ++i) {
            usdc.faucet(users[i], 100_000e6);
        }
    }

    /// @dev 给定——支付 USDC，按今天的 NAV 收到份额
    function subscribe(uint256 userSeed, uint256 amount) external {
        address user = users[bound(userSeed, 0, users.length - 1)];

        uint256 balance = usdc.balanceOf(user);
        if (balance == 0) return;
        amount = bound(amount, 1, balance);

        vm.startPrank(user);
        usdc.approve(address(vault), amount);
        vault.subscribe(amount);
        vm.stopPrank();
    }

    /// @dev 给定——报告人移动 NAV。保持在合理区间内，让 fuzzer 把预算花在
    ///      队列上，而不是荒谬的价格上。
    function attest(uint256 navSeed) external {
        vault.attest(int256(bound(navSeed, 0.5e8, 2e8)));
    }

    /// @dev 给定——SPV 把现金汇回 vault，就像 T+1 的 proceeds 到账一样
    function fundVault(uint256 amount) external {
        uint256 balance = usdc.balanceOf(address(this));
        if (balance == 0) return;
        amount = bound(amount, 1, balance);

        usdc.approve(address(vault), amount);
        vault.depositReserves(amount);
    }

    /// Ex6.1 —— 实现 enqueue
    /// @dev 步骤：
    ///       1) 随机选一个用户（用户可能持有 0 tBILL——如果是，提前返回）
    ///       2) 把 shares 约束在 [1, 该用户的 tBILL 余额]
    ///       3) 以该用户身份调用 queue.enqueue(shares)
    ///       4) 别忘了 approve——enqueue 用 transferFrom 把份额拉进去
    ///      提示：两个参数还没有名字。先给它们命名。
    function enqueue(uint256 userSeed, uint256 sharesSeed) external {
        address user = users[bound(userSeed, 0, users.length - 1)];

        uint256 balance = tBill.balanceOf(user);
        if (balance == 0) return;
        uint256 shares = bound(sharesSeed, 1, balance);

        vm.startPrank(user);
        tBill.approve(address(queue), shares);
        queue.enqueue(shares);
        vm.stopPrank();

        ++ghost_enqueues;
    }

    /// Ex6.2 —— 实现 settle
    /// @dev 步骤：
    ///       1) 把 `assets` 约束在 [1, vault.reserveBalance()]（vault 为空则提前返回）
    ///       2) 调用 queue.settle(assets)
    ///      用比队头 ticket 更少的现金结算也是合法的——它只是什么都不付。
    function settle(uint256 assetsSeed) external {
        uint256 balance = vault.reserveBalance();
        if (balance == 0) return;
        uint256 assets = bound(assetsSeed, 1, balance);

        queue.settle(assets);

        ++ghost_settles;
    }

    /// Ex6.3 —— 实现 claim
    /// @dev 步骤：
    ///       1) 随机选一个用户
    ///       2) 如果该用户没有可领取的金额，提前返回
    ///       3) 以该用户身份调用 queue.claim()
    function claim(uint256 userSeed) external {
        address user = users[bound(userSeed, 0, users.length - 1)];

        if (queue.claimable(user) == 0) return;

        vm.prank(user);
        queue.claim();

        ++ghost_claims;
    }
}

contract InvariantTasksTest is Test {
    MockUSDC internal usdc;
    ComplianceRegistry internal compliance;
    TBillToken internal tBill;
    MockTBillCustodian internal custodian;
    TBillVault internal vault;
    RedemptionQueue internal queue;
    BridgeHandler internal handler;

    address internal admin = address(this);

    function setUp() public {
        usdc = new MockUSDC();
        compliance = new ComplianceRegistry(admin);
        MockPriceFeed feed = new MockPriceFeed(1e8);
        tBill = new TBillToken(admin, compliance);
        custodian = new MockTBillCustodian(admin);
        vault = new TBillVault(usdc, tBill, feed, custodian, admin);
        queue = new RedemptionQueue(vault, tBill, usdc, admin);

        tBill.grantRole(tBill.MINTER_ROLE(), address(vault));
        tBill.grantRole(tBill.MINTER_ROLE(), address(queue));
        custodian.grantRole(custodian.CUSTODIAN_ROLE(), address(vault));
        vault.setQueue(address(queue));

        compliance.setWhitelisted(address(queue), true);

        handler = new BridgeHandler(usdc, tBill, vault, queue);

        for (uint256 i; i < 3; ++i) {
            compliance.setWhitelisted(handler.users(i), true);
        }
        compliance.setWhitelisted(address(handler), true);

        vault.grantRole(vault.REPORTER_ROLE(), address(handler));
        vault.grantRole(vault.OPERATOR_ROLE(), address(handler));
        queue.grantRole(queue.SETTLER_ROLE(), address(handler));

        // 让 fuzzer 只调用 handler 自己的动作，不要调用它继承来的 helper
        bytes4[] memory selectors = new bytes4[](6);
        selectors[0] = BridgeHandler.subscribe.selector;
        selectors[1] = BridgeHandler.attest.selector;
        selectors[2] = BridgeHandler.fundVault.selector;
        selectors[3] = BridgeHandler.enqueue.selector;
        selectors[4] = BridgeHandler.settle.selector;
        selectors[5] = BridgeHandler.claim.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    /// Ex6.4 —— escrow conservation（木板 c）
    /// @dev 队列持有的份额，正好等于它还欠着的 payout 份额。不丢一张，也不凭空多一张。
    ///      原来的断言是故意写错的（它断言常量 1），所以它是红的。现在它捍卫的是
    ///      真正要成立的性质。
    function invariant_EscrowConservation() public view {
        assertEq(tBill.balanceOf(address(queue)), queue.pendingShares(), "queue holds its escrow");
    }

    /// Ex6.5 —— settlement solvency（木板 c）
    /// @dev 队列不欠已结算的、自己没有的现金：它持有的现金至少等于所有 claimable
    ///      余额之和。原来的断言是故意写错的。
    ///
    ///      然后问自己：为什么没有人能写出那条更诱人的不变量：
    ///        vault.reserveBalance() >= queue.pendingAssets()
    ///      提示：NAV 上涨时，多出来的价值物理上在哪里？在 vault 的 USDC buffer 里，
    ///      还是在托管人那里的 T-Bill 里？这个缺口就是整个 lab 的教训——把答案写进
    ///      讨论题 C1。
    function invariant_SettlementSolvency() public view {
        assertGe(usdc.balanceOf(address(queue)), queue.totalClaimable(), "queue covers its claims");
    }
}
