// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

import {TBillToken} from "../TBillToken.sol";
import {TBillVault} from "../TBillVault.sol";

/// @title 赎回队列（Ex5）——四个 TODO 在等你
/// @notice 这是桥的木板 (c)，物理的一侧。卖出一张 T-Bill、把现金汇回来需要一天
///         （T+1 结算），所以赎回不能原子完成。持有人把份额交进来，拿到一张
///         ticket；等发行人的现金到账，ticket 严格按先进先出兑付。现金不够时，
///         队列会积压——排在后面的人等待。
///
///         这里也是小数再次咬人的地方。三套精度：
///           shares    18 位小数（tBILL）
///           NAV        8 位小数（每份）
///           assets     6 位小数（USDC）
contract RedemptionQueue is AccessControl {
    using SafeERC20 for IERC20;

    TBillVault public immutable vault;
    TBillToken public immutable tBill;
    IERC20 public immutable usdc;

    bytes32 public constant SETTLER_ROLE = keccak256("SETTLER_ROLE");

    uint256 public constant NAV_PRECISION = 1e8;
    uint256 public constant SHARE_PRECISION = 1e18;
    uint256 public constant ASSET_PRECISION = 1e6;
    /// @dev 18 + 8 - 6 —— 和 vault 里同一个数
    uint256 public constant DECIMALS_SCALE = 1e20;

    struct Request {
        address owner;
        uint256 shares; // 托管的份额，18 位小数
        uint256 assetsLocked; // enqueue 时按 NAV 锁定的 payout，6 位小数
        bool settled;
    }

    Request[] public requests;

    /// @dev 第一张尚未结算的 request 的下标——队列头
    uint256 public head;
    /// @dev 本合约持有的份额，对应尚未结算的 request
    uint256 public pendingShares;
    /// @dev 尚未结算的 request 还欠的资产，6 位小数
    uint256 public pendingAssets;
    /// @dev 已结算、等待领取的现金
    uint256 public totalClaimable;
    mapping(address => uint256) public claimable;

    event RedeemRequested(
        uint256 indexed id, address indexed owner, uint256 shares, uint256 assetsLocked
    );
    event Settled(uint256 indexed id, address indexed owner, uint256 assets);
    event Claimed(address indexed owner, uint256 assets);

    error ZeroAddress();
    error ZeroAmount();
    error NothingToClaim();

    constructor(TBillVault vault_, TBillToken tBill_, IERC20 usdc_, address admin) {
        if (
            address(vault_) == address(0) || address(tBill_) == address(0)
                || address(usdc_) == address(0) || admin == address(0)
        ) revert ZeroAddress();
        vault = vault_;
        tBill = tBill_;
        usdc = usdc_;
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(SETTLER_ROLE, admin);
    }

    // ==================================================================
    // 已经给你——只读 helper，不要改
    // ==================================================================

    function queueLength() external view returns (uint256) {
        return requests.length;
    }

    function requestAt(uint256 id) external view returns (Request memory) {
        return requests[id];
    }

    // ==================================================================
    // TODO Ex5.1 —— 小数换算
    // ==================================================================

    /// @notice 把 `shares`（18 位小数）按 8 位小数的 NAV 换算成 USDC 最小单位（6 位小数）
    /// @dev 乘积有 18 + 8 = 26 位小数，你想要 6 位——除以 10 的几次方？
    function assetsAtNav(uint256 shares, uint256 nav) public pure returns (uint256) {
        return shares * nav / DECIMALS_SCALE;
    }

    // ==================================================================
    // TODO Ex5.2 —— 拿 ticket
    // ==================================================================

    /// @notice 交进 `shares`，按今天的 NAV 锁定 payout
    /// @dev 步骤：
    ///        1) 拒绝 0 数量
    ///        2) 把份额拉进来——调用者必须先 approve 本合约
    ///        3) 读今天的 NAV，用 assetsAtNav 锁定 payout
    ///        4) 记录 ticket 并返回它的 id
    ///        5) 让 pendingShares 和 pendingAssets 与未结清的数量保持同步
    ///      现在就锁定汇率是关键：payout 不能在 ticket 排队时随 NAV 漂移。
    function enqueue(uint256 shares) external returns (uint256 id) {
        if (shares == 0) revert ZeroAmount();

        // 先把份额拉进队列：调用者必须先 approve 本合约。
        IERC20(address(tBill)).safeTransferFrom(msg.sender, address(this), shares);

        // 按今天的 NAV 锁定 payout；之后 NAV 再变，这张 ticket 也不变。
        uint256 assetsLocked = assetsAtNav(shares, vault.navPerShare());

        id = requests.length;
        requests.push(
            Request({owner: msg.sender, shares: shares, assetsLocked: assetsLocked, settled: false})
        );

        pendingShares += shares;
        pendingAssets += assetsLocked;

        emit RedeemRequested(id, msg.sender, shares, assetsLocked);
    }

    // ==================================================================
    // TODO Ex5.3 —— 按先进先出兑付队列
    // ==================================================================

    /// @notice 卖出底层资产后，`assets` 现金到账；严格从队头开始，最老的先付
    /// @dev 一张 ticket 要么全额兑付，要么完全不付。如果剩余现金不够付下一张，
    ///      就停下，留给下一次结算——绝不允许跳过前面的票去付后面的票。
    ///      对每一张你结算的 ticket：
    ///        - 从 vault 拉出正好这张票的现金
    ///        - 标记为已结算，并推进 `head`
    ///        - 烧掉它托管的份额
    ///        - 减少 pendingShares 和 pendingAssets
    ///        - 给 owner 的 claimable 和 totalClaimable 记账
    ///      返回你实际付出去多少。
    function settle(uint256 assets) external onlyRole(SETTLER_ROLE) returns (uint256 filled) {
        uint256 remaining = assets;
        uint256 id = head;
        uint256 length = requests.length;

        while (id < length) {
            Request storage request = requests[id];

            // 一张 ticket 是 all-or-nothing：剩余现金不够付它，就停在这里。
            if (request.assetsLocked > remaining) break;

            // 先更新状态（CEI），再做外部调用。
            request.settled = true;
            head = id + 1;
            pendingShares -= request.shares;
            pendingAssets -= request.assetsLocked;

            uint256 payout = request.assetsLocked;
            remaining -= payout;
            filled += payout;

            claimable[request.owner] += payout;
            totalClaimable += payout;

            // 从 vault 拉现金；vault 只认 queue 这个调用者。
            vault.releaseReserves(address(this), payout);
            // 烧掉队列托管的份额；需要 MINTER_ROLE，且队列在白名单上。
            tBill.burn(address(this), request.shares);

            emit Settled(id, request.owner, payout);

            ++id;
        }
    }

    // ==================================================================
    // TODO Ex5.4 —— 领取
    // ==================================================================

    /// @notice 提取已结算 ticket 记给你的现金
    /// @dev Checks-effects-interactions：先清零余额，再转账。
    function claim() external returns (uint256 assets) {
        assets = claimable[msg.sender];
        if (assets == 0) revert NothingToClaim();

        // CEI：先把状态清零，再转账。
        claimable[msg.sender] = 0;
        totalClaimable -= assets;

        usdc.safeTransfer(msg.sender, assets);

        emit Claimed(msg.sender, assets);
    }
}
