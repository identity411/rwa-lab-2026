# P4 · 准入 —— 规范

**P4 — Admission: Where the Guard Is, and How Strong It Is**

> **关联规范**
> - ⬆️ **上游** · `2026-10-19-rwa-lab-spec.md` §5.6 / §6.2 —— 本阶段在总路线图中的位置、出口与意义
> - ⬇️ **下游** · 同文件 §5.7 / §6.3 —— P5 · 赎回队列（Ex5）；§5.9 —— P7 讨论题 D1/D2
> - 📖 **原理** · `2026-10-20-p3-ex3-attestation-spec.md` —— NAV 是报告；P4 转向「谁有资格持有这份报告所代表的份额」
> - 📄 **上游** · `2026-10-20-p2-ex2-custody-spec.md` —— 托管数字是报告；三块木板共用同一套「链只能验证账本」的逻辑

> 本文件是 P4 的规范：先交代 P2/P3 之后还缺什么（§1），再讲清 `_update` 这道守卫（§4），然后说明三个测试各自证明什么（§5），最后用出口清单和自测题判定是否过关（§6–§8）。

---

## 1. 背景

P2 证明了托管数字是报告，P3 证明了 NAV 是报告。P4 转向第四块木板：**准入（admission）**。

tBILL 不是普通 ERC-20。它的底层是受监管的证券，所以**不是谁都能持有**。这个「谁能持有」的规则由两处实现：

| 合约 | 职责 |
|---|---|
| `ComplianceRegistry` | 存名单：`isWhitelisted(address)`；`setWhitelisted()` 由 `COMPLIANCE_ROLE` 控制 |
| `TBillToken._update` | 每一笔余额变动都检查名单：`from` 和 `to` 两端 |

P4 的三个测试分别证明：

1. 没 KYC 的地址，即使付了 USDC，也收不到份额；
2. 白名单持有人也不能把份额转给非白名单地址；
3. 把一个地址移出名单后，它被冻结——**而且发行人也无法 burn 掉它的份额**。

第三条是 P4 最反直觉、也最重要的一条。它直接通向 P7 的 D2。

### 1.1 为什么 P4 是 Lab 2 的第三个认知拐点

Lab 1 的 Ex4 讲的是：**守卫写对了，但钥匙交给了谁**——金库持有 `MINTER_ROLE`，所以它能烧掉任何人的余额。

Lab 2 把同一个问题推进了一步：

- `TBillToken.burn(from, amount)` 仍然是一个中心化权力；
- 但 `_update` 对 **burn** 也检查 `from` 的白名单；
- 所以一旦把 alice 移出名单，**发行人自己也 burn 不掉她的份额**。

同一个守卫，既保护持有人不被没收，也让发行人无法执行「强制转移」。这就是 D2 要你论证的两面。

### 1.2 读者假定

| | |
|---|---|
| ✅ **需要** | 会写 Foundry 测试（`vm.startPrank` / `vm.stopPrank`、`vm.expectRevert`、`abi.encodeWithSelector`）；读过 `TBillToken._update` 与 `ComplianceRegistry` |
| ✅ **已具备** | P0–P3 出口已通过；`make test` 核心 7 个全绿；Ex2/Ex3 共 4 个测试已绿 |
| ❌ **不需要** | 任何 OpenZeppelin 内部实现知识；任何 fuzz 测试经验 |

---

## 2. 这一阶段要回答的问题

> **谁有资格持有 tBILL？守卫在哪里？把一个人移出名单，除了冻结他的转账，还会发生什么？**

---

## 3. 前置条件

- [x] P3 出口已通过：两个 Ex3 测试绿
- [x] `make test` 核心 7 个全绿
- [ ] 能读懂 `TBillToken._update` 的三个入口：mint / transfer / burn
- [ ] 能读懂 `ComplianceRegistry.setWhitelisted` 的角色门

---

## 4. 心智模型

### 4.1 名单在哪里

`ComplianceRegistry` 只做一件事：

```solidity
mapping(address => bool) public isWhitelisted;

function setWhitelisted(address account, bool status) external onlyRole(COMPLIANCE_ROLE) {
    isWhitelisted[account] = status;
}
```

它是「guest list」：链上只存谁在名单上，谁进名单由链下的 KYC 决定。

### 4.2 `_update` 是每一笔余额变动的必经之路

`TBillToken` 覆写了 OpenZeppelin 的 `_update`：

```solidity
function _update(address from, address to, uint256 value) internal override whenNotPaused {
    if (from != address(0) && !compliance.isWhitelisted(from)) {
        revert NotWhitelisted(from);
    }
    if (to != address(0) && !compliance.isWhitelisted(to)) revert NotWhitelisted(to);
    super._update(from, to, value);
}
```

三个入口都会走它：

| 操作 | `from` | `to` | 检查谁 |
|---|---|---|---|
| `mint(to, amount)` | `address(0)` | 接收方 | **`to`** |
| `transfer(to, amount)` | 发送方 | 接收方 | **两端** |
| `burn(from, amount)` | 持有人 | `address(0)` | **`from`** |

> 注意最后一行：**burn 也是余额变动，也要检查 `from`。** 这就是「freeze 也冻结没收」的根源。

### 4.3 三个测试对应三条 revert 路径

| 测试 | 触发方式 | 预期 revert |
|---|---|---|
| `test_Ex4_NoKyc_NoShares_EvenIfYouPay` | attacker 有 USDC、有 allowance，调用 `subscribe` | `NotWhitelisted(attacker)`（`to` 不在名单） |
| `test_Ex4_TransferChecksBothEndpoints` | alice 把份额转给 attacker | `NotWhitelisted(attacker)`（`to` 不在名单） |
| `test_Ex4_FreezeBeatsConfiscation` | alice 被移出名单；alice 转账；admin burn alice | `NotWhitelisted(alice)`（`from` 不在名单） |

### 4.4 freeze 和 pause 是两把不同的刀

| | freeze（`setWhitelisted(addr, false)`） | pause（`PAUSER_ROLE`） |
|---|---|---|
| 范围 | **单个地址** | **全局** |
| 影响 | 该地址不能收、不能转、不能被 burn | 所有人不能转账、mint、赎回 |
| 场景 | 制裁、KYC 失效、司法冻结 | 紧急停机 |
| 讨论题 | D2 | C2 |

P4 只碰 freeze。`pause()` 是另一个问题，不要混。

### 4.5 为什么必须钉死错误选择器

```solidity
vm.expectRevert(abi.encodeWithSelector(TBillToken.NotWhitelisted.selector, attacker));
```

如果只写 `vm.expectRevert()`，那么：

- 守卫被删掉后，测试可能因为别的原因 revert（余额、额度、角色），依然是绿的；
- 你无法知道错误里出现的是 `attacker` 还是 `alice`。

钉死 selector + 地址，测试才真的在证明「这个守卫、这个对象」。

---

## 5. 三个测试的设计说明

> 实现见 `test/exercises/01_BridgeTasks.t.sol` 的 Ex4 三节。

### 5.1 `test_Ex4_NoKyc_NoShares_EvenIfYouPay`

**要证明：** 不在白名单的地址，即使付了 USDC，也收不到份额。

步骤：

1. `usdc.faucet(attacker, 1_000e6)`：给 attacker 钱；
2. attacker `approve(vault, 1_000e6)`：给它额度；
3. `vm.expectRevert(NotWhitelisted(attacker))`；
4. attacker 调用 `vault.subscribe(1_000e6)`；
5. 断言：
   - `tBill.balanceOf(attacker) == 0`；
   - `usdc.balanceOf(attacker) == 1_000e6`（整笔交易回滚，钱还在）；
   - `vault.reserveBalance() == 0`（没有 USDC 进 vault）。

**关键：** 先给钱和额度，是为了排除「余额不足 / 额度不足」这些无关的 revert 原因。这样 revert 只可能是因为白名单。

### 5.2 `test_Ex4_TransferChecksBothEndpoints`

**要证明：** 转账检查接收方，不只是发送方。

步骤：

1. `_subscribe(alice, 1_000e6)`：alice 拿到 `1_000e18` 份；
2. `vm.startPrank(alice)`；
3. `vm.expectRevert(NotWhitelisted(attacker))`；
4. `tBill.transfer(attacker, 1e18)`；
5. 断言：
   - `tBill.balanceOf(alice) == 1_000e18`（没转出去）；
   - `tBill.balanceOf(attacker) == 0`。

**关键：** 错误里出现的是 **`attacker`**，不是 `alice`。这说明 `_update` 检查的是 `to`，不是只检查 `from`。

### 5.3 `test_Ex4_FreezeBeatsConfiscation`

**要证明：** 移出名单会冻结持有人，而且连发行人的 `burn` 也挡住。

步骤：

1. `_subscribe(alice, 1_000e6)`；
2. `compliance.setWhitelisted(alice, false)`（admin 持有 `COMPLIANCE_ROLE`）；
3. alice 尝试 `transfer(bob, 1e18)` → `NotWhitelisted(alice)`；
4. admin 尝试 `tBill.burn(alice, 1_000e18)` → **同样** `NotWhitelisted(alice)`；
5. 断言：
   - `tBill.balanceOf(alice) == 1_000e18`（份额被冻结，但没被没收）；
   - `tBill.balanceOf(bob) == 0`。

**关键：** `burn` 调用的是 `_burn(alice, amount)`，进而走 `_update(alice, address(0), amount)`；`from = alice` 过不了白名单，所以 revert。**同一个守卫，既保护持有人，也挡住发行人。**

---

## 6. 出口核对清单

**出口** — ✅ **已通过 · 2026-10-20**
证据：`forge test --match-path 'test/exercises/01_BridgeTasks.t.sol'` → `7 passed; 0 failed`；`make test` → `7 passed; 0 failed`；`forge fmt --check test/exercises/01_BridgeTasks.t.sol` 无输出。

- [x] `test_Ex4_NoKyc_NoShares_EvenIfYouPay` 转绿
- [x] `test_Ex4_TransferChecksBothEndpoints` 转绿
- [x] `test_Ex4_FreezeBeatsConfiscation` 转绿
- [x] `01_BridgeTasks.t.sol` 整组 7 个测试全绿
- [x] `make test` 核心 7 个仍全绿
- [x] `forge fmt --check test/exercises/01_BridgeTasks.t.sol` 无输出
- [ ] 能回答 §7 的四道自测题 ← **这一项由你自己确认**

**验证命令**

```bash
forge test --match-path 'test/exercises/01_BridgeTasks.t.sol' -vv
```

---

## 7. 自测题

1. `TBillToken._update` 在哪三个入口被调用？每个入口检查哪些地址？
2. 为什么 `test_Ex4_NoKyc_NoShares_EvenIfYouPay` 要先 faucet 和 approve？如果不先做，测试可能在证明什么？
3. 为什么 `vm.expectRevert` 要钉死 `NotWhitelisted(attacker)`，而不是只写 `vm.expectRevert()`？
4. freeze 和 pause 有什么区别？为什么 Ex4.3 的 freeze 会挡住 admin 的 burn？

<details>
<summary>参考答案（先自己想，卡住再展开）</summary>

1. **三个入口：** `mint`（`from = 0`，检查 `to`）、`transfer`（检查 `from` 和 `to`）、`burn`（`to = 0`，检查 `from`）。`_update` 是所有余额变动的必经之路。
2. 因为 `subscribe` 会先 `transferFrom` 拉走 USDC，再 `mint`。如果 attacker 没有 USDC 或没有 approve，它会先因为 `ERC20InsufficientBalance` / `ERC20InsufficientAllowance` revert，测试就变成了「余额不足」而不是「白名单拦截」。先给钱和额度，才能让 revert 原因唯一。
3. 因为模糊的 `expectRevert()` 只断言「它 revert 了」。如果守卫被删掉，测试仍可能因为其他原因（余额、额度、角色）revert 而保持绿色。钉死 `NotWhitelisted(attacker)` 才能证明：**是这个守卫、这个对象**。
4. **freeze** 是 `setWhitelisted(addr, false)`，只影响一个地址；**pause** 是 `PAUSER_ROLE` 的全局开关，冻结所有人的转账、mint、赎回。Ex4.3 的 `burn` 走 `_update(alice, address(0), amount)`，`from = alice` 不在名单，所以同一个守卫也把 `burn` 挡住了。这是 D2 的核心张力：合规权力既保护持有人，也阻止发行人没收。

</details>

---

## 8. 常见故障

| 症状 | 原因 | 处理 |
|---|---|---|
| `subscribe` revert `NotWhitelisted(attacker)` 但你以为应该成功 | attacker 不在名单 | 这是测试要证明的；如果要成功，先 `compliance.setWhitelisted(attacker, true)` |
| `expectRevert` 没匹配上 | 用了错误的 selector 或地址 | 用 `abi.encodeWithSelector(TBillToken.NotWhitelisted.selector, who)`；确认 `who` 是实际出现在错误里的地址 |
| `transfer` 的调用者不是 alice | `vm.prank` 被其他调用消耗，或忘了 `startPrank` | 用 `vm.startPrank(alice)` / `vm.stopPrank()` 包住整段 |
| `burn` revert `AccessControlUnauthorizedAccount` | 调用者没有 `MINTER_ROLE` | 用 admin 调用；`setUp` 里 `admin = address(this)`，持有该角色 |
| `burn` 预期成功但 revert `NotWhitelisted` | 这是 Ex4.3 要证明的行为 | 不要为了让它成功而把 alice 重新加回名单；那会破坏测试 |
| 测试通过但你认为它应该失败 | `expectRevert` 太模糊 | 钉死 selector + 地址 |
| 把 freeze 和 pause 混了 | `pause()` 是全局开关 | freeze 用 `setWhitelisted`；pause 是另一个问题（C2） |

---

## 9. 本阶段**不**做什么

- ❌ **不写 Ex5 的队列** —— 那是 P5
- ❌ **不改 `src/` 下任何合约** —— P4 是观察，不是修复
- ❌ **不打开 `test/TBill.t.sol`** —— 它含参考答案
- ❌ **不用 `pause()` 代替 freeze** —— 它是全局开关，属于 C2
- ❌ **不为了「让 burn 成功」而把 alice 加回名单** —— Ex4.3 要证明的正是它不成功
- ❌ **不弱化 `expectRevert`** —— 必须钉死 selector 和地址

---

## 10. 变更记录

| 版本 | 日期 | 说明 |
|---|---|---|
| v1.0 | 2026-10-20 | 首版：P4 规范，含 `_update` 的三个入口、freeze vs pause、三个 Ex4 测试的设计说明、出口清单、四道自测题与故障排查；Ex4 三个测试已实现并通过 |
