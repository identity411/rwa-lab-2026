# P2 · 托管 —— 规范

**P2 — Custody: The Shares Exist, the Box May Not**

> **关联规范**
> - ⬆️ **上游** · `2026-10-19-rwa-lab-spec.md` §5.4 / §6.2 —— 本阶段在总路线图中的位置、出口与意义
> - ⬇️ **下游** · 同文件 §5.5 / §6.2 —— P3 · Attestation（Ex3）
> - 📖 **原理** · `2026-10-20-p1-bridge-walkthrough.md` §4–§5 —— `subscribe` / `attest` / `enqueue` 的心智模型与实测数字

> 本文件是 P2 的规范：先交代 P1 看到了什么（§1），再讲清两个测试要证明什么（§4–§5），最后用出口清单和自测题判定是否过关（§6–§8）。

---

## 1. 背景

P1 已经看到了：

- `subscribe(1_000e6)` 后，你拿到 `1_000e18` 份；
- `custodian.realHoldings()` 仍然是 **0**；
- `attest(1.25e8)` 后份额不变，账面价值从 `1_000e6` 变成 `1_250e6`；
- `make redeem` 因为队列是 TODO 而 revert。

P2 只做一件事：**把「份额存在、托管人报告 0」从一次观察变成两个测试。**

观察是一次性的，你看完就过去了；断言是一份**机器每次都会重新检查的声明**。把「这个系统允许你在托管人报告 0 的情况下持有份额」写成测试，意味着以后任何人改动代码，这句话都会被重新验证一遍。

**能从今往后自动成立的，才是系统真实的性质。**

### 1.1 为什么 P2 不再需要命令行

P1 的产出是观察，P2 的产出是断言。两个测试不是「把 P1 的命令翻译一遍」，而是把 P1 看到的两个事实固定下来：

1. 份额可以在托管人持有 0 的情况下存在；
2. 托管人的「持有量」是一个权限地址可以改写的数字。

### 1.2 读者假定

| | |
|---|---|
| ✅ **需要** | 会写基本 Foundry 测试（`assertEq`、`vm.prank`、`_subscribe` helper）；读过 `MockTBillCustodian.sol` 与 `TBillVault.subscribe` |
| ✅ **已具备** | P1 出口已通过（买入侧）；`make test` 核心 7 个全绿 |
| ❌ **不需要** | 任何 fuzz 测试经验；任何 OpenZeppelin 内部实现知识 |

---

## 2. 这一阶段要回答的问题

> **为什么份额已经存在，托管人却可以报告 0？这个「0」到底是 bug，还是设计？**

---

## 3. 前置条件

- [x] P1 出口已通过（买入侧）
- [x] `make test` 核心 7 个全绿
- [ ] 能读懂 `test/exercises/01_BridgeTasks.t.sol` 的 `setUp()` 与 `_subscribe()` helper

---

## 4. 心智模型

### 4.1 两个测试的形状

P2 的两个测试是「正常路径 + 反直觉路径」：

| 测试 | 走哪条路径 | 要证明什么 |
|---|---|---|
| `test_Ex2_SharesExistWhileTheCustodianHoldsNothing` | 正常申购 | 份额存在，托管人是 0 |
| `test_Ex2_RealHoldingsIsJustANumber` | 直接改托管人的数字 | 这个数字是敲进去的，不是现金到账 |

### 4.2 `subscribe` 的路径

`_subscribe(alice, 1_000e6)` 做四件事：

1. `usdc.faucet(alice, 1_000e6)`：给 alice 测试 USDC；
2. `alice` 调用 `usdc.approve(vault, 1_000e6)`；
3. `alice` 调用 `vault.subscribe(1_000e6)`：
   - vault 用 `transferFrom` 拉走 1000 USDC；
   - `shares = 1_000e6 * 1e20 / navPerShare()`；
   - 在 NAV 1.00 时，`shares = 1_000e18`；
   - vault 调用 `tBill.mint(alice, 1_000e18)`；
   - `TBillToken._update` 检查 `alice` 在白名单上；
4. **vault 没有调用 custodian。**

所以测试可以同时断言：

- `tBill.balanceOf(alice) == 1_000e18`；
- `tBill.totalSupply() == 1_000e18`；
- `vault.reserveBalance() == 1_000e6`；
- `custodian.realHoldings() == 0`。

### 4.3 `recordPurchase` 的路径

`MockTBillCustodian.recordPurchase(amount)` 做三件事：

1. `onlyRole(CUSTODIAN_ROLE)` 检查调用者；
2. `treasury += amount`；
3. 发出 `PurchaseRecorded` 事件。

它**没有**：

- `usdc.transferFrom(...)`；
- `usdc.transfer(...)`；
- 任何现金移动。

所以第二个测试可以断言：

- `realHoldings()` 从 0 跳到 `1_000_000e6`；
- `usdc.balanceOf(address(custodian))` 仍然是 0。

### 4.4 「背书」的两种可能

| 阶段 | 份额的背书是什么？ | 链上能验证吗？ |
|---|---|---|
| 刚 `subscribe` | vault 里的 1000 USDC | ✅ 能（`reserveBalance`） |
| `invest` 之后 | 托管人报告的 T-Bill 价值 | ❌ 不能（只是一个数字） |
| `attest` 之后 | 报告人写的 NAV | ❌ 不能（只是一个数字） |

P2 的第二个测试把最后一行提前演示了：托管人可以报告任意 value，链上没有对应的现金或资产移动。

### 4.5 为什么两个断言要一起写

只断言 `tBill.balanceOf(alice) == 1_000e18`，证明的是「份额存在」；只断言 `realHoldings() == 0`，证明的是「托管人是 0」。**两个一起断言**，才能说明「份额存在，而托管箱是空的」这个反直觉的事实。

---

## 5. 两个测试的设计说明

> 实现见 `test/exercises/01_BridgeTasks.t.sol` 的 Ex2 两节。

### 5.1 `test_Ex2_SharesExistWhileTheCustodianHoldsNothing`

**要证明：** alice 付 1000 USDC 后持有 1000 份，而托管人报告 0。

断言四件事：

1. `tBill.balanceOf(alice) == 1_000e18`；
2. `tBill.totalSupply() == 1_000e18`；
3. `vault.reserveBalance() == 1_000e6`；
4. `custodian.realHoldings() == 0`。

第 3 条是关键：它说明「背书」目前是 vault 的现金，不是 T-Bill。第 4 条说明托管人没有被通知。

### 5.2 `test_Ex2_RealHoldingsIsJustANumber`

**要证明：** 托管人的 `realHoldings()` 是一个权限地址敲进去的整数，不是到账的现金。

步骤：

1. 断言初始 `realHoldings() == 0`；
2. 调用 `custodian.recordPurchase(1_000_000e6)`；
   - `address(this)` 是 admin，持有 `CUSTODIAN_ROLE`；
3. 断言 `realHoldings() == 1_000_000e6`；
4. 断言 `usdc.balanceOf(address(custodian)) == 0`。

第 4 条是核心：**数字跳了，钱没动。**

---

## 6. 出口核对清单

**出口** — ✅ **已通过 · 2026-10-20**
证据：`forge test --match-test 'test_Ex2_'` → `2 passed; 0 failed`；`make test` → `7 passed; 0 failed`；`forge fmt --check test/exercises/01_BridgeTasks.t.sol` 无输出。

- [x] `test_Ex2_SharesExistWhileTheCustodianHoldsNothing` 转绿
- [x] `test_Ex2_RealHoldingsIsJustANumber` 转绿
- [x] `make test` 核心 7 个仍全绿
- [x] `forge fmt --check test/exercises/01_BridgeTasks.t.sol` 无输出
- [ ] 能回答 §7 的三道自测题 ← **这一项由你自己确认**

**验证命令**

```bash
forge test --match-path 'test/exercises/01_BridgeTasks.t.sol' --match-test 'test_Ex2_' -vv
```

---

## 7. 自测题

1. `subscribe` 的过程中，vault 有没有调用 custodian？如果没有，份额的「背书」是什么？
2. `recordPurchase` 为什么能让 `realHoldings()` 跳起来，却没有 USDC 进入 custodian？谁有权限调用它？
3. 如果 `realHoldings()` 和 `usdc.balanceOf(custodian)` 可以不一致，那么「100% 足额抵押」在链上还能验证什么、不能验证什么？

<details>
<summary>参考答案（先自己想，卡住再展开）</summary>

1. **没有。** `subscribe` 只做「收 USDC、按 NAV 算份额、mint 给用户」，从不调用 custodian。刚申购时，份额的背书是 vault 里的 USDC（`reserveBalance`）；如果之后 `invest`，USDC 会转给 custodian，背书就变成 `realHoldings()` 这个报告数字。
2. `recordPurchase` 只做 `treasury += amount`，没有任何 `transfer`/`transferFrom`。它由 `CUSTODIAN_ROLE` 保护；在 lab 里 admin 和 vault 持有这个角色。所以「托管人报告有多少」是一个权限动作，不是现金到账的结果。
3. **链上能验证：** vault 的 USDC 余额、tBILL 的总量和余额、`totalClaimValue = supply × nav / 1e20` 这条算术。**链上不能验证：** `realHoldings()` 背后的 T-Bill 是否真实存在、`navPerShare()` 是否是真实价值。换句话说，「100% 足额抵押」在链上只能验证账本自洽，不能验证资产真实。

</details>

---

## 8. 常见故障

| 症状 | 原因 | 处理 |
|---|---|---|
| `subscribe` revert `NotWhitelisted(alice)` | alice 不在名单 | `setUp` 已 whitelist alice；自己搭环境时先 `compliance.setWhitelisted(alice, true)` |
| `recordPurchase` revert `AccessControlUnauthorizedAccount` | 调用者没有 `CUSTODIAN_ROLE` | 用 admin 调用；`setUp` 里 `admin = address(this)`，持有该角色 |
| `realHoldings()` 仍是 0 | 没有调用 `recordPurchase`，或调用失败 | 先检查角色，再断言 |
| 金额差 10^12 | USDC 6 位、tBILL 18 位混用 | `1_000e6` vs `1_000e18`，不要混 |
| 测试通过但你认为它应该失败 | 断言太宽 | 用 `assertEq` 钉死具体数值，不要只断言 `> 0` |

---

## 9. 本阶段**不**做什么

- ❌ **不写 Ex3/Ex4 的测试** —— 那是 P3/P4
- ❌ **不改 `src/` 下任何合约** —— P2 是观察，不是修复
- ❌ **不打开 `test/TBill.t.sol`** —— 它含参考答案
- ❌ **不追求 `make exercise` 全绿** —— 现在只有 Ex2 绿，其余红是预期
- ❌ **不为「让测试变绿」而弱化断言** —— 两个测试各对应一个明确命题

---

## 10. 变更记录

| 版本 | 日期 | 说明 |
|---|---|---|
| v1.0 | 2026-10-20 | 首版：P2 规范，含两个 Ex2 测试的设计说明、出口清单、自测题与故障排查；Ex2 两个测试已实现并通过 |
