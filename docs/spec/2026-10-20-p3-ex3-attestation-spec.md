# P3 · Attestation —— 规范

**P3 — Attestation: One Number Re-prices the Whole Book**

> **关联规范**
> - ⬆️ **上游** · `2026-10-19-rwa-lab-spec.md` §5.5 / §6.2 —— 本阶段在总路线图中的位置、出口与意义
> - ⬇️ **下游** · 同文件 §5.6 / §6.2 —— P4 · 准入（Ex4）；§5.7 / §6.3 —— P5 · 赎回队列（Ex5）
> - 📖 **原理** · `2026-10-20-p1-bridge-walkthrough.md` §4.3 —— `attest` 的心智模型与实测数字
> - 📄 **上游** · `2026-10-20-p2-ex2-custody-spec.md` —— 托管数字是报告；P3 把同一逻辑推进到 NAV

> 本文件是 P3 的规范：先交代 P2 证明了什么（§1），再讲清两个测试要证明什么（§4–§5），最后用出口清单和自测题判定是否过关（§6–§8）。

---

## 1. 背景

P2 证明了：托管人的 `realHoldings()` 是一个 `CUSTODIAN_ROLE` 可以改写的报告数字，改它不需要 USDC 移动。

P3 要证明的是同一类东西，只不过这次的主角是 **NAV**：

> `navPerShare()` 是一个 `REPORTER_ROLE` 写进 `MockPriceFeed` 的裸数字。它不移动 USDC、不 mint/burn 份额、不调用 custodian，却能让整本账的索取权价值变化。

P1 已经看到过一次：

```text
attest(1.25e8) 前：份额 1000e18，claim value 1000e6，vault 现金 1000e6，custodian 0
attest(1.25e8) 后：份额 1000e18，claim value 1250e6，vault 现金 1000e6，custodian 0
```

份额没动，现金没动，托管报告没动——只有 NAV 和由它算出来的价值动了。

P3 把这一次观察变成两个断言。

### 1.1 为什么 P3 是 Lab 2 的第二个认知拐点

Lab 1 里，价格源只是 Ex5 超额抵押的一个输入：`mWETH` 的价格变了，清算线才动。价格错了，影响的是清算。

Lab 2 里，NAV 是**链上唯一的资产窗口**。`subscribe` 用它定价，`assetsForShares` 用它算索取权，`totalClaimValue` 用它算整本账，Ex5 的 `assetsAtNav` 也用它算赎回金额。**它错了，整个基金都错了。**

而且 `attest` 不移动任何资产。它只改一个数字。一个数字，重估整本账。

### 1.2 读者假定

| | |
|---|---|
| ✅ **需要** | 会写基本 Foundry 测试（`assertEq`、`vm.prank`、`_subscribe` helper）；读过 `TBillVault.attest` / `navPerShare` / `assetsForShares` / `totalClaimValue` |
| ✅ **已具备** | P0/P1/P2 出口已通过；`make test` 核心 7 个全绿；Ex2 两个测试已绿 |
| ❌ **不需要** | 任何 fuzz 测试经验；任何 OpenZeppelin 内部实现知识 |

---

## 2. 这一阶段要回答的问题

> **为什么一次 `attest` 能让份额数量不变、价值变？链上有没有任何东西能核对这个数字？**

---

## 3. 前置条件

- [x] P2 出口已通过：两个 Ex2 测试绿
- [x] `make test` 核心 7 个全绿
- [ ] 能读懂 `TBillVault.navPerShare()`、`assetsForShares()`、`totalClaimValue()` 的换算
- [ ] 能读懂 `01_BridgeTasks.t.sol` 的 `_subscribe()` helper

---

## 4. 心智模型

### 4.1 `attest` 的路径

`vault.attest(nav)` 做两件事：

1. `onlyRole(REPORTER_ROLE)` 检查调用者；
2. `navFeed.setPrice(nav)`：把数字写进 `MockPriceFeed`；
3. 发出 `NavAttested` 事件。

它**没有**：

- `usdc.transfer` / `transferFrom`；
- `tBill.mint` / `burn`；
- `custodian.recordPurchase` / `recordSale`。

所以 `attest` 的本质是：**改单价，不改数量，也不动资产。**

下游全部读这一个数：

```text
navPerShare()          -> 直接读 feed
assetsForShares(x)     -> x * nav / 1e20
sharesForAssets(x)     -> x * 1e20 / nav
totalClaimValue()      -> totalSupply * nav / 1e20
queue.assetsAtNav(x,n) -> x * n / 1e20
```

### 4.2 份额 vs 价值

| 数字 | 单位 | NAV 变了会怎样 |
|---|---|---|
| `tBill.balanceOf(alice)` | 份（18 位小数） | **不变** |
| `navPerShare()` | USDC/份（8 位小数） | **变** |
| `assetsForShares(balance)` | USDC（6 位小数） | **变** |
| `totalClaimValue()` | USDC（6 位小数） | **变** |

一句话：

> **份额是数量，NAV 是单价，索取权价值是两者的乘积。单价变了，数量不变，价值变。**

### 4.3 一次 `attest` 为什么影响所有人

`TBillVault` 不存每个持有人的「价值」，只存 `navPerShare()` 这一个全局数字。每个持有人的 claim value 都是临时算出来的：

```solidity
assetsForShares(balanceOf(who)) = balanceOf(who) * navPerShare() / 1e20
```

所以一次 `attest` 改的是**所有人共用的那个乘数**。alice 和 bob 的份额数量不同，但都乘同一个 NAV，所以一次调用同时改变两个人的价值。

### 4.4 这个数字从哪里来

`MockPriceFeed` 只存一个 `answer`：

```solidity
function setPrice(int256 newAnswer) external {
    answer = newAnswer;
}
```

`TBillVault.navPerShare()` 读 `latestRoundData().answer`，没有和 `custodian.realHoldings()` 对账，也没有检查 `updatedAt` 是否过期（mock 把 `updatedAt` 填成 `block.timestamp`，所以永远看起来是新的）。

> `MockPriceFeed.setPrice` 本身是公开的 mock 测试接口；生产环境应换成不可公开写入的 feed（如 Chainlink）。本阶段讨论的是 `vault.attest` 这个报告人入口。

### 4.5 和 P2 的关系

| 木板 | 报告数字 | 谁写 | 链上能验证吗 |
|---|---|---|---|
| (a) custody | `realHoldings()` | `CUSTODIAN_ROLE` | ❌ 只是数字 |
| (b) attestation | `navPerShare()` | `REPORTER_ROLE` | ❌ 只是数字 |

P2 证明了托管数字可以单独动；P3 证明 NAV 也可以单独动。两个数字都不需要资产移动。

---

## 5. 两个测试的设计说明

> 实现见 `test/exercises/01_BridgeTasks.t.sol` 的 Ex3 两节。

### 5.1 `test_Ex3_TheClaimFloats_TheShareCountDoesNot`

**要证明：** NAV 上涨时，份额数量不变，索取权价值变。

步骤：

1. `_subscribe(alice, 1_000e6)`：在 NAV 1.00 下拿到 `1_000e18` 份；
2. 记录 `sharesBefore = tBill.balanceOf(alice)`、`claimBefore = vault.totalClaimValue()`；
3. 断言 `sharesBefore == 1_000e18`、`claimBefore == 1_000e6`；
4. `vault.attest(int256(NAV_1_25))`：NAV 1.00 → 1.25；
5. 断言：
   - `tBill.balanceOf(alice) == sharesBefore`（份额不变）；
   - `vault.totalClaimValue() == 1_250e6`（价值变了）；
   - `vault.assetsForShares(balanceOf(alice)) == 1_250e6`（单人价值也变了）；
   - `vault.reserveBalance() == 1_000e6`（现金没动）；
   - `custodian.realHoldings() == 0`（托管报告没动）。

**关键：** 五条断言里，只有第 1 条是「不变」，其余都是「变了」或「没动」。这个对比就是「余额不变、价值浮动」。

### 5.2 `test_Ex3_OneCallMovesTheWholeBook`

**要证明：** 一次 `attest` 同时重估所有持有人。

步骤：

1. `_subscribe(alice, 1_000e6)`、`_subscribe(bob, 1_000e6)`：两人各 `1_000e18` 份，整本账 `2_000e6`；
2. 断言 `vault.totalClaimValue() == 2_000e6`；
3. `vault.attest(int256(50e8))`：NAV 1.00 → 50.00（故意选一个大一点的数，让差额明显）；
4. 断言：
   - alice 的 `assetsForShares` = `50_000e6`；
   - bob 的 `assetsForShares` = `50_000e6`；
   - `vault.totalClaimValue()` = `100_000e6`；
   - 两人的 `balanceOf` 都还是 `1_000e18`；
   - `vault.reserveBalance()` 还是 `2_000e6`；
   - `custodian.realHoldings()` 还是 0。

**关键：** 账面价值从 `2_000e6` 变成 `100_000e6`，但 vault 里只有 `2_000e6` 现金，托管人报告 0。**98,000e6 的差额只存在于 NAV 这个数字里。** 这就是「一个数字重估整本账」最直观的样子。

---

## 6. 出口核对清单

**出口** — ✅ **已通过 · 2026-10-20**
证据：`forge test --match-test 'test_Ex2_|test_Ex3_'` → `4 passed; 0 failed`；`make test` → `7 passed; 0 failed`；`forge fmt --check test/exercises/01_BridgeTasks.t.sol` 无输出。

- [x] `test_Ex3_TheClaimFloats_TheShareCountDoesNot` 转绿
- [x] `test_Ex3_OneCallMovesTheWholeBook` 转绿
- [x] `make test` 核心 7 个仍全绿
- [x] `forge fmt --check test/exercises/01_BridgeTasks.t.sol` 无输出
- [ ] 能回答 §7 的四道自测题 ← **这一项由你自己确认**

**验证命令**

```bash
forge test --match-path 'test/exercises/01_BridgeTasks.t.sol' --match-test 'test_Ex3_' -vv
```

---

## 7. 自测题

1. `attest` 移动了哪些链上状态？没有移动哪些？
2. 为什么 `balanceOf` 不变而 `totalClaimValue` 变？这两个数分别是什么单位？
3. 一次 `attest` 为什么能同时改变 alice 和 bob 的 claim value？
4. attest 后，vault 现金 `2_000e6`、custodian 报告 `0`、`totalClaimValue` `100_000e6`。这 `98_000e6` 的差额在哪？链能验证什么、不能验证什么？

<details>
<summary>参考答案（先自己想，卡住再展开）</summary>

1. **移动的：** `MockPriceFeed.answer`（NAV 数字）和 `NavAttested` 事件。**没有移动的：** USDC（vault 和 custodian 的余额都不变）、tBILL（总供应和每个持有人的余额都不变）、custodian 的 `treasury`（不变）。
2. `balanceOf` 的单位是**份额**（18 位小数），它记录你持有多少份；`totalClaimValue` 的单位是 **USDC**（6 位小数），它等于 `totalSupply × nav / 1e20`。NAV 是每份的单价，单价变了，份额数量不变，价值变。
3. 因为 vault 不为每个持有人存「价值」，只存一个全局的 `navPerShare()`。每个持有人的 claim value 都是临时用 `balanceOf(who) * nav / 1e20` 算出来的；一次 `attest` 改的是所有人共用的乘数，所以 alice 和 bob 同时被重估。
4. 这 `98_000e6` **不在链上任何资产里**：vault 的 USDC 还是 `2_000e6`，custodian 的报告还是 0。它只存在于 `navPerShare` 这个数字里。链能验证 `totalClaimValue = supply × nav / 1e20` 这条算术，不能验证 50.00 这个 NAV 是否真实、背后的 T-Bill 是否存在。这就是 P7 B1/B2 和 Ex7 的入口。

</details>

---

## 8. 常见故障

| 症状 | 原因 | 处理 |
|---|---|---|
| `attest` revert `AccessControlUnauthorizedAccount` | 调用者没有 `REPORTER_ROLE` | 用 admin（Anvil 账户 0）调用；`setUp` 里 admin 持有该角色 |
| `navPerShare()` revert `ZeroAmount` | NAV 被设成 0 或负数 | `attest` 一个正数；`navPerShare` 会拒绝 `answer <= 0` |
| 份额数量也变了 | 在 `attest` 之后又调用了 `subscribe`，或算错了 NAV | 先记录 `sharesBefore`，只调用 `attest`，再比较 |
| `totalClaimValue` 不符预期 | NAV 没设成你以为的值，或小数位算错 | 先 `cast call $VAULT "navPerShare()(uint256)"`；换算用 `shares * nav / 1e20` |
| 金额差 10^12 / 10^6 | 18/8/6 三套小数混用 | tBILL 18、NAV 8、USDC 6；除数是 `1e20` |
| 测试通过但你认为它应该失败 | 只断言了份额，没有断言价值 | 同时断言 `balanceOf` 和 `totalClaimValue` |

---

## 9. 本阶段**不**做什么

- ❌ **不写 Ex4 的测试** —— 那是 P4
- ❌ **不实现赎回队列** —— 那是 P5
- ❌ **不改 `src/` 下任何合约** —— P3 是观察，不是修复
- ❌ **不打开 `test/TBill.t.sol`** —— 它含参考答案
- ❌ **不把 `MockPriceFeed.setPrice` 的公开性当成生产设计** —— 它是 mock 的测试接口；生产设计是 P7/Tier 3 的话题
- ❌ **不试图修复「NAV 无法验证」** —— 这是 lab 要你理解的问题，不是 P3 要修的 bug

---

## 10. 变更记录

| 版本 | 日期 | 说明 |
|---|---|---|
| v1.0 | 2026-10-20 | 首版：P3 规范，含 `attest` 的心智模型、两个 Ex3 测试的设计说明、出口清单、四道自测题与故障排查；Ex3 两个测试已实现并通过 |
