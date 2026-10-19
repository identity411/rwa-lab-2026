# P5 · 赎回队列 —— 规范

**P5 — Redemption Queue: T+1, FIFO, and the 10^20**

> **关联规范**
> - ⬆️ **上游** · `2026-10-19-rwa-lab-spec.md` §5.7 / §6.3 —— 本阶段在总路线图中的位置、出口与意义
> - ⬇️ **下游** · 同文件 §5.8 / §6.4 —— P6 · 不变量（Ex6）；§5.9 —— P7 讨论题 C1/C2
> - 📖 **原理** · `2026-10-20-p1-bridge-walkthrough.md` §4.4–§4.5 —— 赎回为什么是队列、三套小数
> - 📄 **上游** · `2026-10-20-p2-ex2-custody-spec.md` / `2026-10-20-p4-ex4-admission-spec.md` —— 托管与准入；P5 转向「份额怎么变回现金」

> 本文件是 P5 的规范：先交代为什么赎回不能原子完成（§1），再讲清 enqueue / settle / claim 三步（§4），然后逐条说明四个 TODO（§5），最后用出口清单和自测题判定是否过关（§6–§8）。

---

## 1. 背景

Lab 1 里，`redeem()` 是原子的：

```text
burn 你的 sUSD → 从 vault 转 USDC 给你     // 一笔交易完成
```

因为抵押物就在 vault 里，链上现金足够，一步就能完成。

Lab 2 做不到。基金的资产是链下的 T-Bill：

- 你要赎回，基金必须先卖掉 T-Bill；
- 卖出 T-Bill 到现金到账，需要时间（T+1）；
- 所以赎回不能在一笔交易里完成。

于是赎回被拆成三步：

```text
enqueue  ──▶  份额进队列，按今天的 NAV 锁定 payout，拿到 ticket
settle   ──▶  现金到账，按 ticket 顺序（FIFO）放款
claim    ──▶  用户把属于自己的现金提走
```

`RedemptionQueue.sol` 就是这条队列。

### 1.1 为什么 P5 是四块木板里最「工程」的一块

Ex2/Ex3/Ex4 都是「写断言，证明一个事实」。P5 是「写代码，让一个机制跑起来」。

它同时考四件事：

1. **小数换算**：18 + 8 − 6 = 20，除以 `1e20`；
2. **FIFO 公平性**：先来的先付，不能跳过队头；
3. **all-or-nothing**：一张 ticket 要么全付，要么留到下次；
4. **CEI**：先改状态，再做外部调用。

这四件事里任何一件错了，测试都会红；而且有些错误**不会 revert**，只是把钱算错——这是本阶段最像真实审计的地方。

### 1.2 读者假定

| | |
|---|---|
| ✅ **需要** | 会写 Solidity（`mapping`、`struct`、`storage`、`while`）；理解 ERC-20 的 `approve` / `transferFrom`；读过 `TBillVault.releaseReserves` |
| ✅ **已具备** | P0–P4 出口已通过；`make test` 核心 7 个全绿；`01_BridgeTasks.t.sol` 的 7 个测试已绿 |
| ❌ **不需要** | 任何 fuzz/invariant 测试经验（P6 才需要）；任何 OpenZeppelin 内部实现知识 |

---

## 2. 这一阶段要回答的问题

> **当现金要 T+1 才到账时，怎么把「份额」公平、可验证地换回「USDC」？**

---

## 3. 前置条件

- [x] P4 出口已通过：`01_BridgeTasks.t.sol` 全绿
- [x] `make test` 核心 7 个全绿
- [ ] 能读懂 `RedemptionQueue.sol` 的 state 变量：`head` / `pendingShares` / `pendingAssets` / `totalClaimable` / `claimable`
- [ ] 能读懂 `TBillVault.releaseReserves` 为什么只认 queue

---

## 4. 心智模型

### 4.1 三个角色，三步动作

| 谁 | 做什么 | 触发哪个函数 |
|---|---|---|
| 持有人 | 交进份额，锁定 payout | `enqueue(shares)` |
| settler（`SETTLER_ROLE`） | 现金到账后，按 FIFO 放款 | `settle(assets)` |
| 持有人 | 提走已结算的现金 | `claim()` |

### 4.2 `enqueue`：份额进队列，价格锁定

```text
1. 拒绝 shares == 0
2. tBill.transferFrom(你 → queue, shares)      // 需要你先 approve(queue)
3. assetsLocked = shares * navPerShare() / 1e20
4. requests.push(Request({owner: 你, shares, assetsLocked, settled: false}))
5. pendingShares += shares; pendingAssets += assetsLocked
6. emit RedeemRequested(id, 你, shares, assetsLocked)
```

**关键：payout 在 enqueue 时锁定。** 之后 NAV 再涨再跌，这张 ticket 都是 `assetsLocked`。

> 这就是讨论题 C1：NAV 在排队期间上涨，赎回人拿不到上涨的部分；留下来的持有人拿到了。这个风险分配是否合理，是 C1 要论证的。

### 4.3 `settle`：现金到账，严格 FIFO

`settle(assets)` 的 `assets` 是**本次到账的现金预算**，不是 vault 的全部余额。

```text
remaining = assets
id = head

while id < requests.length:
    request = requests[id]
    if request.assetsLocked > remaining: break     // 不够付这张，停
    标记 settled；head = id + 1
    pendingShares -= request.shares
    pendingAssets -= request.assetsLocked
    payout = request.assetsLocked
    remaining -= payout；filled += payout
    claimable[owner] += payout；totalClaimable += payout
    vault.releaseReserves(queue, payout)           // 从 vault 拉现金
    tBill.burn(queue, request.shares)              // 烧掉 escrow 份额
    emit Settled(id, owner, payout)
    ++id
```

**三个必须记住的规则：**

1. **严格 FIFO**：从 `head` 开始，不能跳过前面的票去付后面的；
2. **all-or-nothing**：一张 ticket 要么全付，要么完全不付；部分现金留给下一次；
3. **先改状态，再做外部调用**（CEI）：`releaseReserves` 和 `burn` 都是外部调用，但状态已经更新；如果它们 revert，整笔交易回滚。

### 4.4 `claim`：CEI 提现

```text
assets = claimable[msg.sender]
if assets == 0: revert NothingToClaim
claimable[msg.sender] = 0        // 先清零
totalClaimable -= assets
usdc.safeTransfer(msg.sender, assets)
emit Claimed(msg.sender, assets)
```

**先清零再转账**，否则可以重入/重复提取。

### 4.5 三套小数：18 / 8 / 6

```
shares   tBILL   18 位小数
NAV      feed     8 位小数
assets   USDC     6 位小数     18 + 8 - 6 = 20  ->  除以 1e20
```

例：

```text
1000e18 shares × 1.00e8 NAV / 1e20 = 1000e6 USDC
1000e18 shares × 1.25e8 NAV / 1e20 = 1250e6 USDC
 800e18 shares × 1.25e8 NAV / 1e20 = 1000e6 USDC
```

除错 10 的幂**不会 revert**，只是每一笔 payout 都错。Ex5 的测试会把这个错误直接暴露出来。

### 4.6 三个接线，缺一个就 revert

| 接线 | 漏掉会怎样 |
|---|---|
| `tBill.grantRole(MINTER_ROLE, queue)` | `settle` 烧不掉 escrow 份额 |
| `compliance.setWhitelisted(queue, true)` | `burn` 时 `_update` 检查 `from = queue`，revert `NotWhitelisted(queue)` |
| `vault.setQueue(queue)` | `releaseReserves` 检查 `msg.sender == queue`，revert `NotQueue` |

> `script/Deploy.s.sol` 已经把这些都接好了；手工搭环境时最容易漏第 2 条。

---

## 5. 四个 TODO 的设计说明

> 实现见 `src/exercises/RedemptionQueue.sol`；验收见 `test/exercises/02_QueueTasks.t.sol`（11 个测试，**不要改这个文件**）。

### 5.1 `assetsAtNav`

**要做的事：** 把份额换算成 USDC。

```solidity
return shares * nav / DECIMALS_SCALE;   // DECIMALS_SCALE = 1e20
```

**检查点：**

- `assetsAtNav(1000e18, 1e8) == 1000e6`；
- `assetsAtNav(1000e18, 1.25e8) == 1250e6`；
- `assetsAtNav(800e18, 1.25e8) == 1000e6`。

### 5.2 `enqueue`

**要做的事：**

1. `shares == 0` → `ZeroAmount`；
2. `tBill.transferFrom(msg.sender, address(this), shares)`（用户先 `approve(queue)`）；
3. `assetsLocked = assetsAtNav(shares, vault.navPerShare())`；
4. `id = requests.length`；`requests.push(Request(...))`；
5. `pendingShares += shares`；`pendingAssets += assetsLocked`；
6. `emit RedeemRequested(...)`；返回 `id`。

**检查点：**

- 第一张 ticket 的 `id == 0`；
- alice 的份额变成 0，queue 持有 `1000e18`；
- `pendingShares == 1000e18`；`pendingAssets == 1000e6`；
- ticket 的 `assetsLocked` 在 enqueue 后不随 NAV 漂移。

### 5.3 `settle`

**要做的事：**

1. 用 `assets` 作为预算 `remaining`；
2. 从 `head` 开始，逐张检查 `assetsLocked <= remaining`；
3. 满足则：
   - 标记 `settled`、`head++`；
   - 减 `pendingShares` / `pendingAssets`；
   - 加 `claimable[owner]` / `totalClaimable`；
   - `vault.releaseReserves(address(this), payout)`；
   - `tBill.burn(address(this), shares)`；
   - `remaining -= payout`；`filled += payout`；
   - emit `Settled`；
4. 不满足则 `break`（all-or-nothing，不跳票）；
5. 返回 `filled`。

**检查点：**

- 两张 1000e6 的票，`settle(2000e6)` → 两张都付，`head == 2`，`filled == 2000e6`；
- `settle(1500e6)` → 只付第一张，`head == 1`，`filled == 1000e6`，第二张留在队列；
- `settle(500e6)` → 一张都付不了，`head == 0`，`filled == 0`；
- vault buffer 为 0 时，`settle` revert `InsufficientReserves`；`depositReserves` 之后才能付。

### 5.4 `claim`

**要做的事：**

1. `assets = claimable[msg.sender]`；
2. `assets == 0` → `NothingToClaim`；
3. `claimable[msg.sender] = 0`；`totalClaimable -= assets`；
4. `usdc.safeTransfer(msg.sender, assets)`；
5. emit `Claimed`；返回 `assets`。

**检查点：**

- claim 后用户 USDC 增加 `assets`；
- `claimable` 和 `totalClaimable` 归零；
- 第二次 claim revert `NothingToClaim`；
- queue 的 USDC 余额在 claim 后归零。

---

## 6. 出口核对清单

**出口** — ✅ **已通过 · 2026-10-20**
证据：`forge test --match-path 'test/exercises/02_QueueTasks.t.sol'` → `11 passed; 0 failed`；`make test` → `7 passed; 0 failed`；`forge fmt --check src/exercises/RedemptionQueue.sol` 无输出。

- [x] `assetsAtNav` 实现完毕
- [x] `enqueue` 实现完毕
- [x] `settle` 实现完毕
- [x] `claim` 实现完毕
- [x] `02_QueueTasks.t.sol` 的 11 个测试全绿
- [x] `make test` 核心 7 个仍全绿
- [x] `forge fmt --check src/exercises/RedemptionQueue.sol` 无输出
- [ ] 能回答 §7 的五道自测题 ← **这一项由你自己确认**

**验收命令**

```bash
forge test --match-path 'test/exercises/02_QueueTasks.t.sol' -vv
```

**11 个测试：**

```
test_Ex5_1_AssetsAtNav_AtPar
test_Ex5_1_AssetsAtNav_AtHigherNav
test_Ex5_2_Enqueue_EscrowsSharesAndLocksNav
test_Ex5_2_Enqueue_LocksTheRate
test_Ex5_3_Settle_PaysTheWholeQueue
test_Ex5_3_Settle_PartialFillCarriesTheRemainder
test_Ex5_3_Settle_StopsWhenItCannotCoverTheHead
test_Ex5_3_Settle_NeedsTheVaultToHoldCash
test_Ex5_4_Claim_PaysOutAndZeroesTheBalance
test_Ex5_4_Claim_RevertsWithNothingToClaim
test_Ex5_4_Claim_CannotBeDrawnTwice
```

---

## 7. 自测题

1. `enqueue` 为什么需要用户先 `approve(queue)`？`claim` 为什么不需要？
2. `assetsAtNav` 为什么除以 `1e20`，而不是 `1e12`？写出 1000e18 份在 NAV 1.25 下的计算。
3. 两张各 1000e6 的 ticket，`settle(1500e6)` 会发生什么？为什么不能「平均分」给两张？
4. `settle` 为什么需要 vault 先有现金？`releaseReserves` 检查了什么？
5. 队列为什么必须持有 `MINTER_ROLE`，并且必须在白名单上？

<details>
<summary>参考答案（先自己想，卡住再展开）</summary>

1. `enqueue` 用 `tBill.transferFrom(你 → queue, shares)` **主动拉走**你的份额，所以你必须先 `approve(queue)`。`claim` 是队列把**自己的 USDC** 转给你，动的是队列的余额，不需要你授权。
2. 乘积有 `18 + 8 = 26` 位小数，USDC 要 6 位，所以除以 `10^(26−6) = 10^20`。`1000e18 × 1.25e8 / 1e20 = 1250e6`（1250 USDC）。用 `1e12` 只算了 `18 − 6`，漏掉了 NAV 的 8 位。
3. 只付第一张，`filled = 1000e6`，`head = 1`，第二张留在队列，`pendingAssets = 1000e6`。因为一张 ticket 是 all-or-nothing：如果平均分，两张都变成「部分付款」，`assetsLocked` 的语义被破坏，而且会违反 FIFO 的公平性。
4. 因为 `settle` 要从 vault 拉现金付给队列。`releaseReserves` 检查 `msg.sender == queue`（`NotQueue`）和 `assets <= reserveBalance()`（`InsufficientReserves`）。如果 vault 的现金都投出去了（`invest`），就必须等 SPV 把现金汇回来（`depositReserves`）。
5. `settle` 要 `tBill.burn(queue, shares)` 烧掉 escrow 份额。`burn` 是 `onlyRole(MINTER_ROLE)`，所以队列必须有这个角色；`burn` 也走 `_update(from=queue, to=0)`，所以队列必须在白名单上，否则 `NotWhitelisted(queue)`。

</details>

---

## 8. 常见故障

| 症状 | 原因 | 处理 |
|---|---|---|
| `enqueue` revert `ERC20InsufficientAllowance` | 用户没有 `approve(queue)` | 先 `tBill.approve(queue, shares)`；测试的 `_enqueue` helper 已包含 |
| `settle` revert `NotWhitelisted(queue)` | 队列不在名单 | `compliance.setWhitelisted(address(queue), true)` |
| `settle` revert `AccessControlUnauthorizedAccount` | 调用者没有 `SETTLER_ROLE` | 用 admin 调用；`setUp` 里 admin 持有该角色 |
| `settle` revert `NotQueue` | `vault.setQueue(queue)` 没做 | 部署脚本会做；手工搭环境时补上 |
| `settle` revert `InsufficientReserves` | vault buffer 不够 | 先 `vault.depositReserves(assets)`，模拟 SPV 把现金汇回来 |
| `claim` revert `NothingToClaim` | 没有已结算的 claimable | 先 `settle`；或检查是不是已经 claim 过 |
| 金额差 10^12 / 10^6 | 18/8/6 混用 | `shares * nav / 1e20`，不是 `/1e12` |
| `settle(1500e6)` 付了两张 | 用了 vault 的全部余额作为预算，而不是传入的 `assets` | 用 `remaining = assets`，逐张减 |
| 跳过了队头去付后面的票 | 没有从 `head` 开始，或没有 `break` | 严格从 `head` 开始；不够付就 `break` |
| 第二次 `claim` 还能提款 | 没有先清零 | CEI：`claimable[msg.sender] = 0` 在 `safeTransfer` 之前 |

---

## 9. 本阶段**不**做什么

- ❌ **不写 Ex6 的 handler / invariant** —— 那是 P6
- ❌ **不改 `02_QueueTasks.t.sol`** —— 它是给定的验收文件，文件里明确说不要改
- ❌ **不改 `src/` 下其他合约** —— P5 只填 `RedemptionQueue.sol` 的四个 TODO
- ❌ **不打开 `test/TBill.t.sol`** —— 它含参考答案
- ❌ **不追求 `make exercise` 全绿** —— 现在 `01` + `02` 绿，`03` 还红是预期
- ❌ **不为「让测试变绿」而弱化 FIFO 或 all-or-nothing** —— 这两条是机制的核心

---

## 10. 变更记录

| 版本 | 日期 | 说明 |
|---|---|---|
| v1.0 | 2026-10-20 | 首版：P5 规范，含 enqueue / settle / claim 的心智模型、四个 TODO 的设计说明、三套小数、出口清单、五道自测题与故障排查；`02_QueueTasks.t.sol` 的 11 个测试已全部通过 |
