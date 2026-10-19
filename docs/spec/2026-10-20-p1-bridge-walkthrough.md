# P1 · 走一遍桥 —— 操作规范

**P1 — Bridge Walkthrough (Hands-on Runbook)**

> **关联规范**
> - ⬆️ **上游** · `2026-10-19-rwa-lab-spec.md` §5.3 / §6.1 —— 本阶段在总路线图中的位置、出口与意义
> - ⬇️ **下游** · 同文件 §5.4 / §6.2 —— P2 · 托管（Ex2）；§5.7 / §6.3 —— P5 · 赎回队列（Ex5）
> - 📖 **原理** · `README.md` §3、`EXERCISES.md` Ex1、`FOUNDRY-101.md` —— 四块木板、命令与测试工具

> 本文件是 P1 的操作规范：先交代背景（§1），再讲清要看懂什么（§4），然后给出可照抄的命令（§5），最后用出口清单和自测题判定是否过关（§7–§8）。

---

## 1. 背景

本实验的核心命题只有一句：

> **链上的 tBILL 不是 T-Bill，而是对 T-Bill 的索取权。**

Lab 1 里，抵押物本身就是链上代币，所以 `totalCollateral() == totalSupply()` 是链自己能验证的事实。Lab 2 把资产放到链下（托管人/SPV 的 T-Bill），链上只剩下两样东西：

- 一份账本：`tBill.totalSupply()` 和每个地址的 `balanceOf`；
- 一个数字：`navPerShare()`，由 `REPORTER_ROLE` 通过 `attest()` 写进 `MockPriceFeed`。

`TBillVault.totalClaimValue()` 把这两个东西乘起来：

```solidity
totalClaimValue = tBill.totalSupply() * navPerShare() / 1e20;
```

这个等式在链上永远算得通，但它**不证明** T-Bill 真的在托管人那里。P1 就是去亲眼看这件事：份额存在、NAV 会动、托管人却可能什么都没有。

### 1.1 为什么这一步不能跳

P0 刚把工具链装好，P2 就要开始写测试。中间插一个「不写代码、只跑一遍」的阶段，理由很具体——后面的 Ex2–Ex6 全都在描述这座桥的行为：

- Ex2 的托管测试，问的是「份额存在时，托管人到底持有什么」；
- Ex3 的 attestation 测试，问的是「一个 NAV 数字如何重估整本账」；
- Ex4 的准入测试，问的是「谁能持有这份索取权」；
- Ex5 的赎回队列，问的是「T+1 的现金怎么按 FIFO 分」；
- Ex6 的不变量，问的是「无论怎么折腾，哪条等式必须成立」。

**没在命令行上见过它怎么动，写测试就只是照着 `test/TBill.t.sol` 的形状填空**——测试会绿，但你说不清绿的是什么。

### 1.2 读者假定

| | |
|---|---|
| ✅ **需要** | 会敲命令行；能看懂 Solidity 基本语法（函数、`mapping`、`revert`） |
| ✅ **已具备** | P0 出口已通过：`make doctor` 无 ✗、`make test` = 7 passed |
| ❌ **不需要** | 任何 OpenZeppelin 内部实现知识；任何写测试的经验 |

---

## 2. 这一阶段要回答的问题

**一句话：把「代币是索取权，不是资产」这句话，从一句断言变成你亲眼见过的事实。**

到 P0 为止，你手上有的是一堆全绿的测试——但那些测试是别人写的。P1 不写任何代码，只做一件事：**在 Anvil 上亲手走一遍买入侧，盯着份额、NAV、索取权价值、托管人报告这四个数字看它们怎么变。**

> P1 只走**买入侧**。卖出侧（`enqueue` → `settle` → `claim`）要等 Ex5 的队列实现完，P5 之后回补。现在 `make redeem` 会 revert，这是设计，不是 bug。

---

## 3. 前置条件

- [ ] P0 出口已通过：`make doctor` 无 ✗、`make test` = 7 passed
- [ ] `forge` / `cast` / `anvil` 在 PATH 中（`forge --version` 有输出）
- [ ] 两个终端窗口可用（一个常驻跑链，一个用来敲命令）
- [ ] `RedemptionQueue.sol` 的四个 TODO **还没有**实现（如果你已经做完 Ex5，`make redeem` 会成功，跳过 §5 步骤 9 的「预期 revert」即可）

---

## 4. 心智模型：先看懂，再动手

> 这一节是 P1 真正的重点。命令只是手段，看懂这些才是目的。

### 4.1 七份合约各自负责什么

| 合约 | 一句话职责 | 它掌握的权力 |
|---|---|---|
| `MockUSDC` | **现金**。6 位小数，开放 faucet | 无权限；`faucet()` 谁都能调（仅测试用） |
| `ComplianceRegistry` | **guest list**。谁可以持有 tBILL | `COMPLIANCE_ROLE` 能改名单 |
| `TBillToken` | **索取权**。ERC-20，18 位小数 | `MINTER_ROLE` 能 mint/burn；`PAUSER_ROLE` 能全局暂停 |
| `TBillVault` | **上桥口 + 账本**。收 USDC、按 NAV 发份额、记 buffer | `REPORTER_ROLE` 能 `attest`；`OPERATOR_ROLE` 能 `invest` / `depositReserves` |
| `MockPriceFeed` | **NAV oracle**。8 位小数，`1.00e8` 为 par | 无权限；`setPrice` 是公开的 mock 测试接口 |
| `MockTBillCustodian` | **托管人 / SPV**。只回答 `realHoldings()` | `CUSTODIAN_ROLE` 能 `recordPurchase` / `recordSale` |
| `RedemptionQueue` | **T+1 队列**。份额进、ticket 出、现金后到 | `SETTLER_ROLE` 能 `settle`；四个 TODO 还没实现 |

> 注意最后一行：P1 期间 `RedemptionQueue` 还是 stub。这正是 `make redeem` 会 revert 的原因。

### 4.2 一笔 `subscribe(1000e6)` 按顺序发生四件事

1. 你调用 `vault.subscribe(1000000000)`（`1000e6`）。
2. vault 执行 `usdc.safeTransferFrom(你 → vault, 1000e6)`：**从你的钱包拉走** 1000 USDC。
   - 这一步需要你事先 `approve` 过；没有额度就报 `ERC20InsufficientAllowance`。
3. vault 计算 `shares = 1000e6 * 1e20 / navPerShare()`：在 NAV 1.00 时是 `1000e18`。
4. vault 执行 `tBill.mint(你, 1000e18)`：**给你铸** 1000 份。
   - 这一步需要 vault 持有 `MINTER_ROLE`；没有就报 `AccessControlUnauthorizedAccount`。
   - `TBillToken._update` 还会检查接收方 `to` 是否在白名单；没有就报 `NotWhitelisted`。

> **关键**：第 2 步和第 4 步在**同一次交易**里——要么都成功，要么一起回滚。
> **但整个过程中 vault 没有调用过 custodian。** 份额在你付钱的那一刻就存在了，跟托管箱里有没有 T-Bill 完全无关。

### 4.3 一次 `attest(1.25e8)` 按顺序发生两件事

1. reporter 调用 `vault.attest(125000000)`。
2. vault 执行 `navFeed.setPrice(125000000)`：把 `1.25e8` 写进 `MockPriceFeed`。

就这些。没有对账、没有检查 `realHoldings`、没有更新任何 T-Bill 持仓。

但下游全都会跟着变：

- `navPerShare()` 读 `1.25e8`；
- `assetsForShares(1000e18)` 从 `1000e6` 变成 `1250e6`；
- `totalClaimValue()` 从 `1000e6` 变成 `1250e6`；
- 将来 Ex5 的 `queue.assetsAtNav(shares, nav)` 也会用这个数。

**一个裸数字，重估整本账。**

> `MockPriceFeed.setPrice` 本身没有权限控制，是 mock 的测试接口；`vault.attest` 才是本实验讨论的报告人入口。生产环境应换成不可公开写入的 feed（如 Chainlink）。详见主规范 §3.1 的 mock 说明。

### 4.4 一次 `make redeem(1 share)` 为什么先 `approve`、再 `enqueue`、然后 revert

`make redeem` 实际做两步：

```text
tBill.approve(queue, 1e18)     # 允许队列拉走你的 1 份
queue.enqueue(1e18)            # 把份额交给队列，换一张 ticket
```

1. **`approve` 是必需的**：`enqueue` 会用 `tBill.transferFrom(你 → queue, shares)` **主动拉走**你的份额，而不是你推给队列。
2. **`enqueue` 现在会 revert**：`RedemptionQueue.enqueue` 还是 `revert("TODO Ex5.2: enqueue")`。所以第二笔交易失败，队列保持空，你的份额还在你手里。
3. **它不能像 Lab 1 的 `redeem` 一样一步完成**：RWA 的赎回是 T+1——份额先进队列锁定 NAV，等 SPV 把现金汇回来，`settle` 才按 FIFO 放款，`claim` 才把 USDC 给你。这是 Ex5 要实现的。

> 如果你已经做完 Ex5，`enqueue` 会成功，你会拿到一张 ticket，`pendingAssets` 变成 `1000e6`。这时 P1 的「预期 revert」观察点就不适用了，直接看 `queue.pendingAssets()` 即可。

### 4.5 三套小数：18 / 8 / 6

```
shares   tBILL   18 decimals
NAV      feed     8 decimals
assets   USDC     6 decimals     18 + 8 - 6 = 20  ->  divide by 10^20
```

`1000e18` 份在 NAV `1.25e8` 下值：

```
1000e18 * 1.25e8 / 1e20 = 1250e6   // 1250 USDC
```

除错 10 的幂**不会 revert，不变量也照样成立**，只是每一笔赔付都错得离谱。这是 Lab 1 Ex2 的「不变量只约束关系，不约束量级」在 RWA 里的重演。Ex5 会正面考这个换算。

### 4.6 「余额不变、价值浮动」——和稳定币的 1:1 对比

| | Lab 1 · sUSD | Lab 2 · tBILL |
|---|---|---|
| 余额含义 | 1000 枚币 | 1000 份基金份额 |
| NAV 上涨时 | 币价仍是 1 美元 | 份额数量仍是 1000；每份价值从 1.00 涨到 1.25 |
| 价值来源 | 抵押物 1:1 | `navPerShare()` 这个报告数字 |
| 余额变了？ | 不变 | **不变** |
| 价值变了？ | 不变 | **变了** |

这就是「pegged token」和「claim」的全部区别。P1 的核心观察就是这一行：**`balanceOf` 不动，`totalClaimValue` 动了。**

---

## 5. 操作手册（Runbook）

> 命令可逐条照抄。方括号 `<...>` 处需要替换成实际值。以下地址来自本次实测；**重启 Anvil 后一切以终端实际打印为准**。

### 步骤 0 · 准备

```bash
cd rwa-lab-2026
```

### 步骤 1 · 起链（终端 A）

```bash
make anvil
```

**预期**：打印 10 个测试账户及其私钥，最后一行显示监听 `127.0.0.1:8545`。
**⚠️ 这个终端不要关**——关了链就没了，所有合约消失。

### 步骤 2 · 部署（终端 B）

```bash
make deploy-anvil
```

**预期**：输出 admin + 七份合约地址：

```text
admin      : 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266
MockUSDC   : 0x5FbDB2315678afecb367f032d93F642f64180aa3
Compliance : 0xe7f1725E7734CE288F8367e1Bb143E90bb3F0512
NAV feed   : 0x9fE46736679d2D9a65F0992F2272dE9f3c7fa6e0
TBillToken : 0xCf7Ed3AccA5a467e9e704C703E8D87F634fB0Fc9
Custodian  : 0xDc64a140Aa3E981100a9becA4E685f962f0cF6C9
TBillVault : 0x5FC8d32690cc91D4c39d9d3abcBD16989F875707
Queue      : 0x0165878A594ca255338adfa4d48449f69242Eb8F
```

> **⚠️ 一切以终端实际打印的为准。** 重启 Anvil 后必须重新部署——旧地址上已经没有代码了。

### 步骤 3 · 设置变量（终端 B）

```bash
export ADMIN=0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266
export USDC=0x5FbDB2315678afecb367f032d93F642f64180aa3
export COMPLIANCE=0xe7f1725E7734CE288F8367e1Bb143E90bb3F0512
export FEED=0x9fE46736679d2D9a65F0992F2272dE9f3c7fa6e0
export TBILL=0xCf7Ed3AccA5a467e9e704C703E8D87F634fB0Fc9
export CUSTODIAN=0xDc64a140Aa3E981100a9becA4E685f962f0cF6C9
export VAULT=0x5FC8d32690cc91D4c39d9d3abcBD16989F875707
export QUEUE=0x0165878A594ca255338adfa4d48449f69242Eb8F
export RPC=http://127.0.0.1:8545
```

> `ADMIN` 是 Anvil 的**账户 0**，也是 `Makefile` 里 `ANVIL_KEY` 对应的账户。`make subscribe` / `make attest` / `make redeem` 都用这个账户。这些是公开的测试密钥，**永远不要用于真实资金**。

### 步骤 4 · 领现金

```bash
cast send $USDC "faucet(address,uint256)" $ADMIN 1000000000000 \
  --rpc-url $RPC \
  --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
```

**预期**：`status 1 (success)`；`$ADMIN` 的 USDC 余额变成 `1_000_000e6`（`1000000000000` 个最小单位）。

### 步骤 5 · 上桥：subscribe 1000 USDC

```bash
make subscribe AMOUNT=1000000000
```

等价于：

```text
usdc.approve(vault, 1000e6)
vault.subscribe(1000e6)
```

**预期**：两笔交易都 `status 1`。vault 拉走 1000 USDC，给你 mint `1000e18` 份 tBILL。

### 步骤 6 · 核心观察：读六个数字 ← **本阶段重点**

```bash
cast call $TBILL     "balanceOf(address)(uint256)" $ADMIN --rpc-url $RPC
cast call $TBILL     "totalSupply()(uint256)"             --rpc-url $RPC
cast call $VAULT     "navPerShare()(uint256)"             --rpc-url $RPC
cast call $VAULT     "totalClaimValue()(uint256)"         --rpc-url $RPC
cast call $VAULT     "reserveBalance()(uint256)"          --rpc-url $RPC
cast call $CUSTODIAN "realHoldings()(uint256)"            --rpc-url $RPC
```

**本次实测：**

```text
tBILL balance : 1000000000000000000000   [1e21]    # 1000 份
tBILL supply  : 1000000000000000000000   [1e21]
NAV per share : 100000000               [1e8]     # 1.00
claim value   : 1000000000              [1e9]     # 1000 USDC
vault reserves: 1000000000              [1e9]     # 1000 USDC
custodian     : 0                                  # 托管人：0
```

停下来看一眼：**你持有 1000 份，vault 里有 1000 USDC，但托管人报告 0 份 T-Bill。** `subscribe` 从头到尾没有跟 custodian 说过话。

### 步骤 7 · 改 NAV：attest 到 1.25

```bash
make attest NAV=125000000
```

**预期**：`status 1`。reporter 把 `1.25e8` 写进 `MockPriceFeed`。

### 步骤 8 · 再读一遍 ← **本阶段核心对比**

```bash
cast call $VAULT     "navPerShare()(uint256)"              --rpc-url $RPC
cast call $TBILL     "balanceOf(address)(uint256)" $ADMIN  --rpc-url $RPC
cast call $VAULT     "totalClaimValue()(uint256)"          --rpc-url $RPC
cast call $VAULT     "reserveBalance()(uint256)"           --rpc-url $RPC
cast call $CUSTODIAN "realHoldings()(uint256)"             --rpc-url $RPC
cast call $VAULT     "assetsForShares(uint256)(uint256)" 1000000000000000000000 --rpc-url $RPC
```

**本次实测：**

```text
NAV per share : 125000000                [1.25e8]
tBILL balance : 1000000000000000000000   [1e21]    # 没变
claim value   : 1250000000               [1.25e9]  # 变了：1000 → 1250
vault reserves: 1000000000               [1e9]     # 现金没变
custodian     : 0                                   # 托管人还是 0
assetsForShares(1000e18) : 1250000000    [1.25e9]
```

**这就是 P1 要看的全部：**

| 指标 | subscribe 后 | attest(1.25) 后 |
|---|---|---|
| 份额数量 | `1000e18` | `1000e18`（**不变**） |
| NAV | `1.00e8` | `1.25e8` |
| 索取权价值 | `1000e6` | `1250e6`（**变了**） |
| vault 现金 | `1000e6` | `1000e6`（**没变**） |
| 托管人报告 | `0` | `0` |

账面上瞬间多了 `250e6` 的索取权价值，但 vault 的 USDC 没有多一分，托管人还是报告 0。这 `250e6` 完全是 `attest` 那个数字写出来的——真实世界里它应该对应 T-Bill 的利息/增值，但链上无法验证。

### 步骤 9 · 尝试 redeem（预期 revert）

```bash
make redeem AMOUNT=1000000000000000000   # 1 share
```

**预期**：

1. 第一步 `tBill.approve(queue, 1e18)` **成功**（`status 1`）；
2. 第二步 `queue.enqueue(1e18)` **失败**：

```text
Error: Failed to estimate gas: server returned an error response:
error code 3: execution reverted: TODO Ex5.2: enqueue
```

3. 失败后核对：

```bash
cast call $TBILL "balanceOf(address)(uint256)" $ADMIN  --rpc-url $RPC   # 仍是 1000e18
cast call $TBILL "balanceOf(address)(uint256)" $QUEUE  --rpc-url $RPC   # 0
cast call $QUEUE "pendingAssets()(uint256)"             --rpc-url $RPC   # 0
cast call $QUEUE "queueLength()(uint256)"               --rpc-url $RPC   # 0
```

**这说明：** `approve` 只是授权，份额还在你手里；`enqueue` 整笔回滚，队列没有拿到任何东西。赎回不是 `transfer`，而是一条还没实现的队列。

> 如果你已经完成 Ex5，这一步会成功，`queueLength()` 变成 1，`pendingAssets()` 变成 `1000e6`。P5 之后再回补 `settle` / `claim`，把卖出侧走完。

### 步骤 10 · 停链

终端 A 里 `Ctrl-C`。重启 Anvil 后状态全部清空，需要重新部署。

---

## 6. 出口实验：三个数字，两个世界

> 这个实验把「链能验证 claim，不能验证 asset」变成看得见的事实。**建议必做**，它直接决定 Ex6 的第三条关系你能不能答对。

在步骤 8 之后，读三个数字：

```bash
cast call $VAULT     "totalClaimValue()(uint256)" --rpc-url $RPC   # 1250000000  (1250e6)
cast call $VAULT     "reserveBalance()(uint256)"  --rpc-url $RPC   # 1000000000  (1000e6)
cast call $CUSTODIAN "realHoldings()(uint256)"    --rpc-url $RPC   # 0
```

**三个数字：**

| 数字 | 值 | 在哪 |
|---|---|---|
| 账面索取权 `totalClaimValue` | `1250e6` | 链上账本，由 `supply × nav` 算出 |
| 链上现金 `reserveBalance` | `1000e6` | vault 的 USDC 余额，链上可数 |
| 托管人报告 `realHoldings` | `0` | custodian 的 `treasury`，一个 `CUSTODIAN_ROLE` 能改的数字 |

**差额：`1250e6 − 1000e6 − 0 = 250e6`。** 这 250e6 既不在 vault 的现金里，也不在托管人的报告里；它只存在于 `navPerShare` 这个数字里。

> **这就是本阶段最重要的结论**：链能验证 `totalClaimValue = supply × nav / 1e20` 这条算术，不能验证「nav 背后的 T-Bill 真的存在」。`totalClaimValue` 和 `reserveBalance` 都是链上数字；`realHoldings` 只是一个报告。三者之间的缺口，就是 P7 讨论题 B1/B2 和 Ex7 的入口。

**可选加一步：把现金投出去。** 调用 `vault.invest(1000e6)`（admin 有 `OPERATOR_ROLE`）：

```bash
cast send $VAULT "invest(uint256)" 1000000000 \
  --rpc-url $RPC \
  --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80

cast call $VAULT     "reserveBalance()(uint256)" --rpc-url $RPC   # 0
cast call $CUSTODIAN "realHoldings()(uint256)"   --rpc-url $RPC   # 1000000000  (1000e6)
```

现在 vault 的现金是 0，托管人报告 1000e6；账面索取权仍是 1250e6。差额还是 250e6——只不过这次它对应「托管人报告 1000e6 T-Bill + 账面增值 250e6」。**现金被投出去了，赎回要等 SPV 把现金汇回来**，这就是 Ex5 的 T+1 故事。

---

## 7. 出口核对清单

P1 的出口**不是**「命令跑通了」，而是「你能说清楚发生了什么」。以下买入侧项目本次实测已勾选；卖出侧待 P5 回补。

- [x] 起链 + 部署：Anvil chain id 31337，`Deploy.s.sol` 打印 admin + 七个地址
- [x] `faucet` → `subscribe(1000e6)`：admin 拿到 1,000,000 USDC，付出 1000 USDC
- [x] 读到 `tBill.balanceOf(admin)` = `1000e18`、`totalClaimValue` = `1000e6`、`realHoldings` = **0**
- [x] `attest(1.25e8)` 后：份额仍 `1000e18`，`totalClaimValue` = `1250e6`，`realHoldings` 仍 0
- [x] `make redeem` 按预期 revert（`TODO Ex5.2: enqueue`），队列保持空
- [x] 完成 §6 实验，能说清 `1250e6 / 1000e6 / 0` 三个数字的差额
- [ ] （P5 回补）`enqueue` → `settle` → `claim`，把 1 share 换成 USDC
- [ ] 五道自测题（§8）全部答得上来

---

## 8. 自测题

> 答不上来就说明命令只是「跑过了」，还没「看懂」。答案都能在 §4 找到。

1. `subscribe` 的过程中，vault 有没有和 custodian 说过话？如果没有，份额的「背书」从哪来？
2. 为什么 `attest(1.25e8)` 之后 `balanceOf` 不变，而 `totalClaimValue` 变了？这两个数分别是什么单位？
3. `make redeem` 为什么先 `approve`，再 `enqueue`？为什么它不能像 Lab 1 的 `redeem` 一样一步完成？
4. `1000e18` 份在 NAV `1.25e8` 下值多少 USDC？写出算式，并说明为什么除的是 `1e20`，不是 `1e12`。
5. attest 后，`totalClaimValue` = 1250e6，vault 现金 = 1000e6，custodian 报告 = 0。这 250e6 的差额在链上哪里？它说明链能验证什么、不能验证什么？

<details>
<summary>参考答案（先自己想，卡住再展开）</summary>

1. **没有。** `subscribe` 只做三件事：`usdc.safeTransferFrom` 把 USDC 拉进 vault、按 NAV 算份额、`tBill.mint` 给你。它从不调用 `custodian`。份额的「背书」是一个链下的承诺：T-Bill 在托管人/SPV 那里，链上只有一个 `realHoldings()` 数字可以看，而这个数字由 `CUSTODIAN_ROLE` 通过 `recordPurchase`/`recordSale` 改写，链无法核对它背后的真实资产。
2. `balanceOf` 的单位是**份额**（18 位小数），NAV 变化不改变份额数量；`totalClaimValue` 的单位是 **USDC**（6 位小数），它等于 `totalSupply × nav / 1e20`，所以 NAV 一变它就变。份额是「数量」，NAV 是「单价」，索取权价值是两者的乘积。
3. 因为 `enqueue` 会用 `tBill.transferFrom(你 → queue, shares)` **主动拉走**你的份额，所以你必须先 `approve` 队列。它不能一步完成，因为 RWA 的赎回是 T+1：份额先进队列锁定 NAV，等 SPV 把 T-Bill 卖掉、现金汇回 vault，`settle` 才按 FIFO 放款，`claim` 才把 USDC 给你。Lab 1 的 `redeem` 是原子的，因为抵押物就在链上。
4. `1000e18 × 1.25e8 / 1e20 = 1250e6`（1250 USDC）。乘积有 `18 + 8 = 26` 位小数，USDC 要 6 位，所以除以 `10^(26−6) = 10^20`。如果只按 `18 − 6 = 12` 去除以 `1e12`，就漏掉了 NAV 的 8 位小数；如果只除以 NAV 的 `1e8`，结果会大 `10^12` 倍。无论哪种都不会 revert，只是赔付出错。
5. 这 250e6 **不在链上任何资产里**：vault 的 USDC 仍是 1000e6，custodian 的报告是 0。它只存在于 `navPerShare` 这个数字里。链能验证 `totalClaimValue = supply × nav / 1e20` 这条算术，不能验证「nav 背后的 T-Bill 真的存在」。这就是 P7 B1/B2 和 Ex7 的入口：报告人可以凭空写出价值，而链只能相信。

</details>

---

## 9. 常见故障

| 症状 | 原因 | 处理 |
|---|---|---|
| `connection refused` | Anvil 没起，或终端 A 被关了 | 回步骤 1 重新 `make anvil`（**合约会全部消失，需重新部署**） |
| `NotWhitelisted(...)` on `subscribe` | 接收方不在名单 | `compliance.setWhitelisted(user, true)`；用 `make deploy-anvil` 时 admin 已被 whitelist |
| `AccessControlUnauthorizedAccount(...)` on `attest` | 调用者没有 `REPORTER_ROLE` | 用 admin（Anvil 账户 0）调用；`make attest` 默认就是它 |
| `ERC20InsufficientBalance(...)` | USDC 不够 | 回步骤 4 领水 |
| `ERC20InsufficientAllowance(...)` | 忘了 `approve`，或额度不够 | `make subscribe` 已包含 approve；手工调用时先 approve |
| `make redeem` 报 `TODO Ex5.2: enqueue` | Ex5 还没做，队列是 stub | **预期行为**；P5 完成后再回补卖出侧 |
| `realHoldings()` 一直是 0 | `subscribe` 不会投资；现金还在 vault 的 buffer 里 | 这是刻意的观察点；想搬走现金就调用 `vault.invest(assets)` |
| 金额差 10^12 / 10^6 | 三套小数混用 | `shares * nav / 1e20`，不是 `/1e12`；USDC 是 6 位，tBILL 是 18 位，NAV 是 8 位 |
| 重启 Anvil 后地址变了 | Anvil 每次从干净状态启动 | 重新 `make deploy-anvil` 并更新 `$USDC` / `$TBILL` / `$VAULT` / `$QUEUE` / `$CUSTODIAN` |
| `call` 返回空 | 用了旧地址 | 确认导出的是本次部署打印的地址 |

---

## 10. 本阶段**不**做什么

划清边界，避免越界浪费时间：

- ❌ **不写任何测试** —— 那是 P2 的事
- ❌ **不实现 `RedemptionQueue`** —— 那是 P5 的事；P1 只看它 revert
- ❌ **不改任何 `src/` 合约** —— 给定合约是 P1 的观察对象
- ❌ **不打开 `test/TBill.t.sol`** —— 它含 P2–P6 的参考答案
- ❌ **不追查 `MockPriceFeed.setPrice` 为什么公开** —— 它是 mock 的测试接口；生产设计是 P7/Tier 3 的话题
- ❌ **不修 `realHoldings() == 0`** —— 这不是 bug；`subscribe` 本来就不投资

---

## 11. 变更记录

| 版本 | 日期 | 说明 |
|---|---|---|
| v1.0 | 2026-10-20 | 首版：P1 阶段的操作规范，含心智模型、可照抄的 runbook、本次实测数字、三个数字的出口实验、自测题与故障排查；P1 买入侧已通过，卖出侧待 P5 回补 |
