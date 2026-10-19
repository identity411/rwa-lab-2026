# P6 · 不变量测试 —— 规范

**P6 — Invariant Testing: Let the Machine Search for a Counterexample**

> **关联规范**
> - ⬆️ **上游** · `2026-10-19-rwa-lab-spec.md` §5.8 / §6.4 —— 本阶段在总路线图中的位置、出口与意义
> - ⬇️ **下游** · 同文件 §5.9 / §7 —— P7 威胁模型（尤其 C1）；§5.10 —— P8 Tier 2
> - 📖 **原理** · `2026-10-20-p5-ex5-redemption-queue-spec.md` —— 队列的实现；P6 给这条队列写不变量
> - 📄 **上游** · `2026-10-20-p3-ex3-attestation-spec.md` —— NAV 是报告；P6 检查「报告变了之后，队列还自洽吗」

> 本文件是 P6 的规范：先交代为什么需要不变量测试（§1），再讲清 handler 和两条不变量（§4），然后逐条说明五个 TODO（§5），最后用出口清单和自测题判定是否过关（§6–§8）。

---

## 1. 背景

P5 把赎回队列实现完了。到 P5 为止，所有测试都是「我构造一个场景，然后检查结果」：

```text
subscribe 1000 → enqueue 1000 → settle 1000 → claim 1000
```

这种测试只能覆盖**你想得到**的攻击。你想不到的——不同的调用顺序、不同的金额组合、NAV 在排队期间变化——它都看不到。

P6 把方向反过来：

> **让机器随机、连续地调用 `subscribe` / `attest` / `enqueue` / `settle` / `claim`，然后问「无论怎么折腾，这两条性质还在不在？」**

Foundry 会重复 N 轮；每一轮之后运行所有 `invariant_*` 函数。第一个失败的断言就是一份**反例调用序列**。

### 1.1 为什么需要 handler

如果直接把 `TBillVault` / `RedemptionQueue` 丢给 fuzzer，会有两个问题：

1. 受权限保护的函数（`attest` / `settle`）fuzzer 调不到；
2. fuzzer 会去调继承来的 helper，浪费预算。

`BridgeHandler` 是一个中间层：

- 它持有 `REPORTER_ROLE` / `OPERATOR_ROLE` / `SETTLER_ROLE`；
- 它把六个动作包装成 fuzzer 可以随机调用、且参数被 `bound` 到合法区间的函数；
- `targetSelector` 只暴露这六个动作；
- `targetContract(address(handler))` 让 fuzzer 只打 handler。

> `ghost_enqueues` / `ghost_settles` / `ghost_claims` 是「fuzzer 真的走到了这里」的证据。如果它们一直是 0，说明 fuzzer 在空转。

### 1.2 读者假定

| | |
|---|---|
| ✅ **需要** | 会写 Solidity（`bound`、`vm.startPrank`、`vm.prank`）；理解 P5 的 `enqueue` / `settle` / `claim` |
| ✅ **已具备** | P0–P5 出口已通过；`make test` 核心 7 个全绿；`02_QueueTasks.t.sol` 11 个测试全绿 |
| ❌ **不需要** | 任何之前的不变量测试经验；任何 fuzz 调参知识 |

---

## 2. 这一阶段要回答的问题

> **无论 fuzzer 以什么顺序、什么金额调用 subscribe / attest / enqueue / settle / claim，队列持有的份额和现金是否始终与它的账本一致？**

---

## 3. 前置条件

- [x] P5 出口已通过：`02_QueueTasks.t.sol` 11 个测试全绿
- [x] `make test` 核心 7 个全绿
- [ ] 能读懂 `BridgeHandler` 的 `users` / `ghost_*` / `targetSelector`
- [ ] 能读懂 `queue.pendingShares()` / `pendingAssets()` / `totalClaimable()` / `claimable()`

---

## 4. 心智模型

### 4.1 普通测试 vs 不变量测试

| | 普通测试 | 不变量测试 |
|---|---|---|
| 谁挑输入 | 你 | 机器 |
| 谁挑顺序 | 你 | 机器 |
| 覆盖范围 | 你想得到的场景 | 机器穷举的组合 |
| 失败时给你什么 | 断言失败 | **反例调用序列** |
| 适合什么 | 已知行为的精确检查 | 「无论怎么折腾都不能破」的性质 |

P5 的 11 个测试是前者；P6 是后者。

### 4.2 handler 的六个动作

`BridgeHandler` 暴露：

```text
subscribe(userSeed, amount)
attest(navSeed)
fundVault(amount)
enqueue(userSeed, sharesSeed)   ← Ex6.1
settle(assetsSeed)              ← Ex6.2
claim(userSeed)                 ← Ex6.3
```

每个动作都：

- 用 `bound` 把随机输入压到合法区间；
- 用 `vm.startPrank` / `vm.prank` 以正确的身份调用；
- 在不可能执行时提前返回（余额为 0、vault 为空、没有 claimable）。

### 4.3 三条 handler TODO

| TODO | 关键点 |
|---|---|
| Ex6.1 `enqueue` | 随机选用户；余额为 0 返回；`bound(shares, 1, balance)`；先 `approve(queue)`，再 `queue.enqueue(shares)`；递增 `ghost_enqueues` |
| Ex6.2 `settle` | `vault.reserveBalance()` 为 0 返回；`bound(assets, 1, reserveBalance)`；`queue.settle(assets)`；递增 `ghost_settles` |
| Ex6.3 `claim` | 随机选用户；`claimable(user) == 0` 返回；`vm.prank(user); queue.claim()`；递增 `ghost_claims` |

> `settle` 用比队头 ticket 更少的现金是合法的——它只是付 0 张。fuzzer 应该能走到这条路径。

### 4.4 两条不变量

```solidity
// Ex6.4 —— escrow conservation
assertEq(tBill.balanceOf(address(queue)), queue.pendingShares());

// Ex6.5 —— settlement solvency
assertGe(usdc.balanceOf(address(queue)), queue.totalClaimable());
```

**第一条：** 队列持有的份额，正好等于它还欠着的份额。不丢一张，也不凭空多一张。

**第二条：** 队列持有的现金，至少覆盖已结算待领取的金额。它不能欠已结算的钱。

> **为什么用 `assertGe` 而不是 `assertEq`？** 有人可能直接给队列转 USDC（捐赠），所以队列的现金可以多于 `totalClaimable`；「至少覆盖」才是正确的方向。

### 4.5 那条看起来像不变量、但不是的关系

```solidity
vault.reserveBalance() >= queue.pendingAssets()     // ❌ 不是不变量
```

`pendingAssets` 是队列还欠的**锁定价**；`reserveBalance` 只是 vault 的 USDC buffer。

- 待赎回的现金可能已经被 `invest` 投到 T-Bill 里；
- NAV 上涨时，额外价值在托管人那里的 T-Bill 里，不在 vault 的 USDC buffer 里。

所以 vault 的现金 buffer 不需要覆盖 `pendingAssets`；它只需要在 `settle` 的那一刻有足够的现金。这个问题的答案就是 P7 的 C1。

### 4.6 读反例

当断言失败时，Foundry 会打印一串调用序列：

```text
[Sequence]
  sender=... addr=... calldata=...
  ...
```

照着序列手工走一遍，你就能看到是哪一步、哪组参数打破了性质。这是本实验中最接近真实安全审计的环节。

> Foundry 会缓存反例到 `cache/invariant/`。如果结果诡异或反复失败，先 `rm -rf cache/invariant` 再跑。

---

## 5. 五个 TODO 的设计说明

> 实现见 `test/exercises/03_InvariantTasks.t.sol`。

### 5.1 Ex6.1 —— handler 的 `enqueue`

```solidity
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
```

**检查点：**

- 余额为 0 的用户必须提前返回，否则 `bound(sharesSeed, 1, 0)` 会 panic；
- `approve` 不能漏，否则 `enqueue` 的 `transferFrom` 会 revert；
- `ghost_enqueues` 证明 fuzzer 真的调到了这里。

### 5.2 Ex6.2 —— handler 的 `settle`

```solidity
function settle(uint256 assetsSeed) external {
    uint256 balance = vault.reserveBalance();
    if (balance == 0) return;
    uint256 assets = bound(assetsSeed, 1, balance);

    queue.settle(assets);

    ++ghost_settles;
}
```

**检查点：**

- vault 为空时提前返回；
- 用 `bound` 而不是 `%`，保证 `assets` 在 `[1, reserveBalance]`；
- `assets` 小于队头 ticket 是合法的，`settle` 会付 0 张。

### 5.3 Ex6.3 —— handler 的 `claim`

```solidity
function claim(uint256 userSeed) external {
    address user = users[bound(userSeed, 0, users.length - 1)];

    if (queue.claimable(user) == 0) return;

    vm.prank(user);
    queue.claim();

    ++ghost_claims;
}
```

**检查点：**

- 没有 claimable 时提前返回，避免 fuzzer 一直撞 `NothingToClaim`；
- `vm.prank(user)` 让队列把钱付给用户，而不是 handler。

### 5.4 Ex6.4 —— `invariant_EscrowConservation`

```solidity
assertEq(tBill.balanceOf(address(queue)), queue.pendingShares(), "queue holds its escrow");
```

**要捍卫：** 队列不丢份额、不造份额。

- `enqueue`：份额从用户转到队列，`pendingShares` 同步增加；
- `settle`：队列烧掉份额，`pendingShares` 同步减少；
- 没有其他路径会改变队列的 tBILL 余额。

### 5.5 Ex6.5 —— `invariant_SettlementSolvency`

```solidity
assertGe(usdc.balanceOf(address(queue)), queue.totalClaimable(), "queue covers its claims");
```

**要捍卫：** 队列不欠已结算的现金。

- `settle`：从 vault 拉现金到队列，同时增加 `totalClaimable`；
- `claim`：队列转出现金，同时减少 `totalClaimable`；
- 任何时刻，队列的现金至少覆盖所有待领取的余额。

---

## 6. 出口核对清单

**出口** — ✅ **已通过 · 2026-10-20**
证据：`03_InvariantTasks.t.sol` 两条不变量通过，`runs: 256, calls: 128000, reverts: 0`；六个 handler 动作都被调用（各约 21k 次）；`make exercise` 的 01 / 02 / 03 三组全绿；`make test` 7 passed；`forge fmt --check test/exercises/03_InvariantTasks.t.sol` 无输出。

- [x] Ex6.1 handler 的 `enqueue` 实现完毕
- [x] Ex6.2 handler 的 `settle` 实现完毕
- [x] Ex6.3 handler 的 `claim` 实现完毕
- [x] `invariant_EscrowConservation` 改成真正要捍卫的性质并通过
- [x] `invariant_SettlementSolvency` 改成真正要捍卫的性质并通过
- [x] `03_InvariantTasks.t.sol` 全绿
- [x] `make exercise` 总体全绿（01 7 + 02 11 + 03 两条不变量）
- [x] `make test` 核心 7 个仍全绿
- [ ] 能回答 §7 的五道自测题 ← **这一项由你自己确认**

**验收命令**

```bash
forge test --match-path 'test/exercises/03_InvariantTasks.t.sol' -vv
```

**本次运行的 handler 覆盖：**

```text
attest     21279 calls
claim      21508 calls
enqueue    21260 calls
fundVault  21554 calls
settle     21065 calls
subscribe  21334 calls
runs: 256, calls: 128000, reverts: 0
```

> `reverts: 0` 很关键：如果 fuzzer 一直在 revert，它就没有真正探索状态空间。

---

## 7. 自测题

1. 普通测试和不变量测试的区别是什么？为什么 P5 的 11 个测试还不够？
2. 为什么需要 `BridgeHandler`？`targetSelector` / `targetContract` 各自做什么？
3. 为什么 `invariant_SettlementSolvency` 用 `assertGe` 而不是 `assertEq`？
4. 为什么 `vault.reserveBalance() >= queue.pendingAssets()` 不是一条可以写出来的不变量？
5. 如果 Foundry 打印了反例序列，你应该怎么用？`cache/invariant/` 是干什么的？

<details>
<summary>参考答案（先自己想，卡住再展开）</summary>

1. 普通测试是「我挑输入、我挑顺序，检查结果」；不变量测试是「机器随机挑输入和顺序，问某条性质是否始终成立」。P5 的 11 个测试只覆盖你想得到的场景；fuzzer 能探索你想不到的调用顺序和金额组合。
2. 因为受权限保护的函数（`attest` / `settle`）fuzzer 直接调不到，而且 fuzzer 会去调继承来的 helper。handler 把六个动作包装成合法的、带角色的入口。`targetSelector` 指定 fuzzer 只能调用这六个 selector；`targetContract` 指定 fuzzer 只打 handler 这个合约。
3. 因为有人可能直接给队列转 USDC（捐赠），队列的现金可以多于 `totalClaimable`。「至少覆盖」才是正确的方向；用 `assertEq` 会把合法的捐赠误判为违反不变量。
4. 因为 `pendingAssets` 是队列还欠的锁定价，而 `reserveBalance` 只是 vault 的 USDC buffer。待赎回的现金可能已经被 `invest` 投到 T-Bill 里；NAV 上涨时，额外价值在托管人那里，不在 buffer 里。Vault 不需要在任何时刻都持有覆盖 `pendingAssets` 的现金，只需要在 `settle` 时有。
5. 照着反例序列手工走一遍：每一步的 sender、calldata、参数。找出哪一步、哪组参数打破了不变量。`cache/invariant/` 是 Foundry 缓存反例的地方；如果结果诡异或反复失败，先 `rm -rf cache/invariant` 再跑，让 fuzzer 重新搜索。

</details>

---

## 8. 常见故障

| 症状 | 原因 | 处理 |
|---|---|---|
| `bound` panic | 上界小于下界（例如 `bound(x, 1, 0)`） | 先检查余额/ reserve 是否为 0，提前返回 |
| `enqueue` revert `ERC20InsufficientAllowance` | 忘了 `approve(queue)` | 在 `vm.startPrank(user)` 里先 approve |
| `settle` revert `AccessControlUnauthorizedAccount` | handler 没有 `SETTLER_ROLE` | `setUp` 里 `queue.grantRole(SETTLER_ROLE, address(handler))` |
| `settle` revert `InsufficientReserves` | `assets` 超过了 vault 的 reserve | 用 `bound(assetsSeed, 1, reserveBalance)` |
| 不变量一直失败 | `cache/invariant/` 里有旧反例 | `rm -rf cache/invariant` 再跑 |
| `ghost_*` 一直是 0 | fuzzer 没调到 handler，或 `targetSelector` 写错 | 检查 `selectors` 和 `targetContract` |
| `make exercise` 卡住 | 不变量搜索在跑；或缓存反例 | 等待；必要时 `rm -rf cache/invariant` |
| 测试通过但 `reverts` 很高 | fuzzer 大部分调用都在 revert，没真正探索 | 检查 handler 的提前返回和 `bound` 区间 |

---

## 9. 本阶段**不**做什么

- ❌ **不改 `src/` 下任何合约** —— P6 是测试，不是修复
- ❌ **不改 `02_QueueTasks.t.sol`** —— 它是给定的验收文件
- ❌ **不打开 `test/TBill.t.sol`** —— 它含参考答案
- ❌ **不追求「更多的 runs」** —— 默认 256 runs 已经足够暴露问题；先把两条性质写对
- ❌ **不试图把第三条关系写成不变量** —— 它不是不变量，答案在 P7 的 C1
- ❌ **不为了变绿而弱化 `assertGe` 为 `assertTrue(true)`** —— 那等于没测

---

## 10. 变更记录

| 版本 | 日期 | 说明 |
|---|---|---|
| v1.0 | 2026-10-20 | 首版：P6 规范，含 handler 的必要性、三个 handler TODO、两条不变量、`assertGe` 的原因、第三条关系的反例、出口清单、五道自测题与故障排查；`03_InvariantTasks.t.sol` 已通过（runs 256 / calls 128000 / reverts 0） |
