# RWA 代币化实验 —— 作业规范

**RWA Tokenization Lab — Assignment Specification**

| 项目 | 内容 |
|---|---|
| 规范英文名 | RWA Tokenization Lab — Assignment Specification |
| 规范编号 | SPEC-2026-10-19-RWA-LAB |
| 版本 | v1.3 |
| 发布日期 | 2026-10-19 |
| 适用课程 | COMP7810A · Assignment Three「RWA Tokenization Lab」 |
| 仓库 | `rwa-lab-2026` |
| 上游材料 | `README.md`、`EXERCISES.md`、`STUDENT-QUESTIONS.md`、`Makefile`、`FOUNDRY-101.md` |
| 作业截止 | 2026-10-16 23:55（作业原文；以课程实际通知为准） |
| 状态 | 生效（本文档为作业要求的唯一权威汇总） |

> 本文档汇总当前作业的背景、要求、任务清单、**阶段出口**、提交物与验收标准。当本文档与仓库内其他说明文件冲突时，以本文档为准，并以 `make` 目标的实际行为作为最终裁决。
>
> 阅读顺序建议：§1–§4 建立背景 → **§5 看怎么做、做到什么程度算过** → §6 查每个任务的具体要求 → §9 核对评分权重 → §10 提交前逐项自查。

---

## 1. 背景

### 1.1 问题从哪来

Lab 1 的抵押物本身就是链上代币，所以 `totalCollateral() == totalSupply()` 是一条链自己能验证的等式。

Lab 2 把「抵押物是代币」这个假设拿掉。资产变成一张短期美国国债（T-Bill），放在托管人（custodian）那里，由 SPV 持有。链上的 tBILL **不是那张国债**，而是**对那张国债的索取权（claim）**。

于是本实验的主题变成连接两者的机械装置：

> **桥（the bridge）**：托管（custody）、资产申报（attestation）、实物赎回（redemption）、准入（admission）。四块木板，缺一块，桥就断。

### 1.2 核心命题

```
链能验证 claim，不能验证 asset。
```

具体到代码：

- `TBillVault.totalClaimValue()` = `tBill.totalSupply() * navPerShare() / 1e20`，其中 `navPerShare()` 是一个 8 位小数的**报告数字**；
- `MockTBillCustodian.realHoldings()` 是一个有权限的地址**敲进去的数字**；
- 两者都没有任何链上机制去核对「T-Bill 真的在托管人那里」。

所以本实验要反复追问的不是「NAV 是多少」，而是：**这个数字是谁说的？他说错了会怎样？谁能改它？改完以后谁受损？**

### 1.3 现实参照

| 事件 | 现象 | 与本实验的对应 |
|---|---|---|
| 2008 货币市场基金「跌破面值」 | 赎回被冻结，投资者排队 | 讨论题 C2：关闭赎回通道意味着什么 |
| 2023 USDC 脱锚至 $0.87 | 储备银行倒闭，但赎回通道保持开放 | 讨论题 C2：冻结 vs 开放 |
| 代币化国债产品（BUIDL / BENJI 等） | SPV + 托管人 + 每日 NAV 报告 + 合格投资者准入 | 四块木板在真实产品中的对应物 |
| T+1 结算 | 卖出 T-Bill 到现金入账有时滞 | Ex5 的赎回队列：份额先托管，现金后到 |

### 1.4 与 Lab 1 的关系

| | Lab 1（稳定币） | Lab 2（RWA） |
|---|---|---|
| 抵押物 | 链上代币（mUSDC） | 链下 T-Bill（托管人） |
| 链上持有什么 | 资产本身 | 对资产的索取权 |
| 关键数字 | `totalCollateral()`（链上可数） | `navPerShare()` / `realHoldings()`（人报的） |
| 不变量 | 链自己能验证 | 只能验证账本内部一致，不能验证资产存在 |
| 典型失败 | 凭空铸币 / 脱锚 | 假 NAV / 冻结赎回 / 未 KYC 转账 |

本实验的四个 plank 把 Lab 1 的「一个不变量」拆成了四条互相牵制的信任边界。Ex2–Ex6 各自打其中一块木板。

---

## 2. 实验目标

完成本实验后，应当能够：

1. 说清**代币不是资产，而是对资产的索取权**，并指出链上链下的信任缺口在哪里；
2. 用测试证明四块木板各自的性质：托管数字可被权限地址改写、一次 attestation 重估全部份额、准入检查覆盖交易两端、赎回队列按 T+1 FIFO 结算；
3. 处理 **18 / 8 / 6 三套小数**并正确完成 `18 + 8 − 6 = 20` 的换算；
4. 实现一个**先托管份额、锁定 NAV、再按 FIFO 用现金结算**的赎回队列；
5. 用**不变量测试**让机器搜索反例，并读懂 Foundry 打印的反例调用序列；
6. 对**单一可信报告人、过期 NAV、冻结与没收的冲突**做威胁建模；
7. 把七份合约部署到 Sepolia 并在 Etherscan 上验证，写出可公开核对的地址表。

---

## 3. 系统组成

### 3.1 七份合约

| 文件 | 角色 | 木板 | 关键设计 |
|---|---|---|---|
| `src/MockUSDC.sol` | **现金**。6 位小数，开放 faucet | — | 过桥的现金；测试网/本地都靠它 |
| `src/ComplianceRegistry.sol` | **guest list**。`setWhitelisted()` / `isWhitelisted()`，`COMPLIANCE_ROLE` 控制 | (d) admission | 链上只存名单，谁进名单由链下 KYC 决定 |
| `src/TBillToken.sol` | **索取权**。ERC-20，**18 位小数**，mint/burn 受角色控制 | (d) admission | `_update` 对**每一笔**余额变动检查两端白名单；`pause()` 是全局冻结 |
| `src/TBillVault.sol` | **上桥口 + 账本**。`subscribe()` 按 NAV 定价；`attest()` 是合约层面的报告人入口 | (b) attestation | 持有 USDC buffer；`navPerShare()` 是链上唯一「资产窗口」；注意 `MockPriceFeed.setPrice` 本身是公开的 mock 测试接口 |
| `src/exercises/MockPriceFeed.sol` | **NAV oracle**。8 位小数，`1.00e8` 为 par | (b) attestation | 只存一个数；`latestRoundData()` 把 `updatedAt` 填成 `block.timestamp`，因此永远看起来很新 |
| `src/exercises/MockTBillCustodian.sol` | **托管人 / SPV**。只回答 `realHoldings()` | (a) custody | `treasury` 是一个 `CUSTODIAN_ROLE` 可以加减的数字 |
| `src/exercises/RedemptionQueue.sol` | **T+1 赎回队列**。份额进、ticket 出、现金后到 | (c) redemption | **Ex5 的四个 TODO**；FIFO、all-or-nothing、CEI |

### 3.2 四块木板与资金/份额流向

```
                    ┌──────────────────── off-chain ────────────────────┐
                    │   US T-Bill  ── held by ──▶  SPV / custodian      │
                    └──────────────────────────┬────────────────────────┘
                                               │ (a) custody
                                               │ realHoldings(): 一个被敲进去的数字
                                               ▼
                                        ┌──────────────┐                  (b) attestation
                                        │  TBillVault  │  ◀────────────  MockPriceFeed
                                        │  NAV pricing │     attest()     (8 decimals)
                                        └──────┬───────┘
                          subscribe: USDC 进，shares 出
                                               │
                                               ▼
                                        ┌──────────────┐
                                        │  TBillToken  │  shares (18 decimals)
                                        └──────┬───────┘
                                               │ enqueue: shares 进队列
                                               ▼
                                        ┌────────────────┐
                                        │ RedemptionQueue│  (c) redemption: T+1, FIFO
                                        └──────┬─────────┘
                                               │ settle: vault 放款
                                               ▼
                                          claim: USDC 出

   (d) admission: ComplianceRegistry 的名单在 TBillToken._update 里检查，
       每一笔 mint / burn / transfer 的 from 和 to 两端都要通过。
```

**两条流，画图时都要有：**

- **现金（USDC，6 位）**：user --subscribe--> vault --invest--> custodian；SPV 卖债回款 --depositReserves--> vault --releaseReserves--> queue --claim--> user。
- **份额（tBILL，18 位）**：vault --mint--> user --enqueue--> queue --burn--> 0（settle 时销毁）。

这张图就是 P9 架构图的最小内容要求：**四块木板都要出现，现金（USDC）与份额（tBILL）的过桥方向都要画出来**。手绘拍照可以，但箭头不能省。

### 3.3 部署接线：最省时间的一节

`script/Deploy.s.sol` 一条命令部署七份合约，并在最后完成五条接线：

| # | 接线 | 漏掉会怎样 |
|---|---|---|
| 1 | `tBill.grantRole(MINTER_ROLE, vault)` | `subscribe` 铸不出份额 |
| 2 | `tBill.grantRole(MINTER_ROLE, queue)` | `settle` 烧不掉队列里的 escrow 份额 |
| 3 | `custodian.grantRole(CUSTODIAN_ROLE, vault)` | `invest` revert `AccessControlUnauthorizedAccount` |
| 4 | `vault.setQueue(queue)` | `settle` 无法从 vault 取现金（`releaseReserves` 只认 queue） |
| 5 | `compliance.setWhitelisted(queue, true)` | 队列烧份额时 `_update` 检查 `from`，直接 `NotWhitelisted(queue)` |

> ⚠️ 第 2、3、5 条是高频翻车点。手工接线时尤其容易漏掉第 5 条：**burn 也是余额变动，也要过白名单**。

### 3.4 角色一览

| 角色 | 合约 | 默认持有者 | 能做什么 |
|---|---|---|---|
| `DEFAULT_ADMIN_ROLE` | 各合约 | admin | 授予/撤销其他角色 |
| `MINTER_ROLE` | `TBillToken` | admin、vault、queue | mint / **burn 任何人的余额** |
| `PAUSER_ROLE` | `TBillToken` | admin | 全局暂停转账、mint、redeem |
| `COMPLIANCE_ROLE` | `ComplianceRegistry` | admin | 改白名单 |
| `REPORTER_ROLE` | `TBillVault` | admin | `attest()` 写 NAV |
| `OPERATOR_ROLE` | `TBillVault` | admin | `invest()` / `depositReserves()` |
| `CUSTODIAN_ROLE` | `MockTBillCustodian` | admin、vault | `recordPurchase()` / `recordSale()` |
| `SETTLER_ROLE` | `RedemptionQueue` | admin | `settle()` 放款 |

> 这张表也是 P7 讨论题 A1/A2/B1/D2 的素材：**同一个 admin 默认持有几乎所有角色**，在演示系统里是方便，在生产系统里是单点。

---

## 4. 技术栈与环境约束

| 项目 | 约定 |
|---|---|
| 工具链 | Foundry（`forge` / `cast` / `anvil`）；本机实测 v1.8.5 |
| Solidity | `0.8.24`（`foundry.toml` 指定） |
| OpenZeppelin | **v5.0.2，固定版本，不得升级**（v5 有破坏性变更，网上 v4 教程会直接报错） |
| 测试库 | `forge-std` |
| 依赖位置 | `lib/` **随仓库分发**，普通 `git clone` 即可编译，无需 `--recursive`，也无需 `make setup` |
| 编译参数 | optimizer 开启，`optimizer_runs = 200` |
| 格式化 | `forge fmt`，`line_length = 100` |
| 本地链 | Anvil，默认 RPC `http://127.0.0.1:8545` |
| 测试网 | Sepolia（仅 Tier 2） |

**环境路线（二选一，之后内容完全相同）**

- **路线 A（macOS / Linux）**：本地安装 Foundry。**不要用 `foundryup`**，使用仓库自带脚本 `bash scripts/install-foundry-cn.sh`（自动走 `gh-proxy.com` 镜像）。
- **路线 B（Windows）**：Foundry 无原生 Windows 版，走 GitHub Codespaces，本地零安装。

**环境自检**

```bash
make doctor    # 约 30 秒，检查工具链、依赖并实际跑一次核心测试；✗ 项自带修复命令
make test      # 应输出 7 passed; 0 failed
```

`make doctor` 全绿、且 `make test` 显示 `7 passed; 0 failed`，才算具备开工条件。若无法修复，把 `make doctor` 的**完整输出**发给助教。

> **两个命令的分工，整个实验都要分清**：
> - `make test` 是「一切正常」的检查点，应始终全绿（7 个核心测试）；
> - `make exercise` 是**你的作业清单**，Ex2–Ex6 完成前是红的——红色不是 bug，是任务。

---

## 5. 阶段路线图：每阶段的出口与意义

§6 给出的是**任务清单**（做什么），本节给出的是**执行顺序**（按什么次序做、做到什么程度算过）。

每个阶段都有一个**出口（Exit）**：一条可执行、有明确通过/不通过判定的命令或交付物。**出口未过，不进入下一阶段。**

### 5.1 阶段总览

| 阶段 | 对应 | 状态 | 出口（判定条件） | 意义（一句话） |
|---|---|---|---|---|
| **P0** 环境就绪 | Ex0 | ✅ 10-19 | `make doctor` 无 ✗，`make test` = 7 passed | 一切命令的前提 |
| **P1** 走一遍桥（不计分） | Ex1 | ✅ 10-20（买入侧） | Anvil 上完成买入侧 + 亲眼看见「余额不变、价值浮动」 | 代币是索取权，不是资产 |
| **P2** 托管 | Ex2 | ⬜ 待做 | 2 个 `test_Ex2_*` 转绿 | 份额存在 ≠ 托管箱里有东西 |
| **P3** Attestation | Ex3 | ⬜ 待做 | 2 个 `test_Ex3_*` 转绿 | 一个数字重估整本账 |
| **P4** 准入 | Ex4 | ⬜ 待做 | 3 个 `test_Ex4_*` 转绿 | 白名单检查两端；冻结也冻结没收 |
| **P5** 赎回队列 | Ex5 | ⬜ 待做 | 4 个 TODO 完成，`02_*` 组全绿 | T+1 不能原子结算；三套小数 |
| **P6** 不变量 | Ex6 | ⬜ 待做 | handler 3 个 TODO + 2 个 `invariant_*` 全绿 | 从「我构造场景」到「机器搜索反例」 |
| **P7** 威胁模型 | A–D + E | ⬜ 待做 | A–D 8 题作答（150–300 词）+ E 表 | 25% 权重；把动手经验兑换成判断力 |
| **P8** 上测试网 | Tier 2 | ⬜ 待做 | Sepolia 七地址 + Etherscan 全部验证 | 真实成本、不可逆性、公开可核对 |
| **P9** 文档与打包 | 风格/架构图/zip | ⬜ 待做 | README 架构图 + `make fmt` + 无 `.env` 的 zip | 15% 权重；让别人能读懂并复现 |
| **P10** 挑战 | Tier 3 | ⬜ 可选 | `make challenge` 转绿，或其余三选一 | 从防守位换到进攻位（不计分） |

状态图例：⬜ 待做 · 🟨 进行中 · ✅ 已通过（通过时补日期与证据）。

> **对应规则：Ex0–Ex6 各自独占一个阶段，不合并、不跳步。** P7–P9 对应作业的三个非代码评分项；P10 是可选挑战。
>
> **维护规则：每通过一个阶段，就回来更新两处** ——
> ① 本表的「状态」列；② 该阶段小节的出口清单（勾选 `- [x]`，并补上通过日期与关键证据）。
>
> **出口状态是这份规范里唯一会随进度变化的部分**，其余内容在阶段开始时即冻结。状态为 ⬜ 的阶段，其小节保持未勾选。

**依赖关系**

```
P0 ──> P1 ──> P2 ──> P3 ──> P4 ──> P5 ──> P6 ──> P7 ──> P9 ──> 提交
                                      │                  ▲
                                      ├──> P8 ───────────┘
                                      └──> P10（可选）
```

- **主线严格按 P0 → P1 → … → P9 顺序推进**，每个阶段只对应一个练习或一个评分项，不合并、不跳步。
- **P6 依赖 P5**：handler 调用 `enqueue` / `settle` / `claim`，队列还是 stub 时 fuzzer 只会看到 revert。
- **P8 至少依赖 P5**：队列没实现时部署出来的系统无法完成赎回；推荐在 P6 之后部署，这样链上跑的是完整闭环。
- **P7 依赖 P1–P6 的亲身经验**——这些题靠查资料答不好。
- **P9 依赖 P7 与 P8**：README 里要同时有架构图、讨论题答案和部署地址表。
- **P10 若选 Ex7，则依赖 P5**（赎回路径需要队列可用）；其余三个选项（staleness / ERC-3643 / Chainlink）不依赖 P5，可在任意时点插入。

---

### 5.2 P0 · 环境就绪（Ex0）

**出口** — ✅ **已通过 · 2026-10-19**
证据：`make doctor` **6 passed / 0 failed**（`forge` / `cast` / `anvil` 均在 `/Users/william/.foundry/bin`；`lib/forge-std`、`lib/openzeppelin-contracts` 就位；核心测试 7 passed）；`forge --version` = **v1.8.5**（commit `51a52c5`）。

- [x] `make doctor` 输出 `6 passed, 0 failed`，没有任何一行 `✗`
- [x] `make test` 输出 `7 passed; 0 failed`
- [x] `forge --version` 有输出（证明 PATH 已生效）

**意义**

这是唯一一个「不做完就什么都做不了」的阶段：后续每一条命令都依赖 `forge` / `cast` / `anvil`。

`make doctor` 的结构值得注意：它把「工具链在不在」「依赖目录是否完整」「能否编译并跑通测试」拆成三段分别报告，所以任何一个 `✗` 都直接指向一个具体的修复动作。**先自检、再动手**——这个习惯会一直用到 P8 的部署失败排查。

**技术细节见 §6.1。**

---

### 5.3 P1 · 走一遍桥（Ex1，不计分）

**出口** — ✅ **已通过（买入侧）· 2026-10-20**
证据（Anvil chain id 31337，`Deploy.s.sol` 部署 7 个合约后）：

- `subscribe(1_000e6)` 后：`tBill.balanceOf(admin)` = `1_000e18`，`navPerShare()` = `1.00e8`，`totalClaimValue()` = `1_000e6`，`vault.reserveBalance()` = `1_000e6`，`custodian.realHoldings()` = **0**。
- `attest(1.25e8)` 后：份额仍为 `1_000e18`（**不变**），`totalClaimValue()` = `1_250e6`（**变了**），`assetsForShares(1_000e18)` = `1_250e6`；vault 的 USDC 储备仍是 `1_000e6`，custodian 仍是 **0**。
- `make redeem AMOUNT=1000000000000000000`（1 share）：`approve` 成功，`enqueue` 以 `TODO Ex5.2: enqueue` revert；`tBill.balanceOf(queue)` = `0`，`pendingAssets()` = `0`，`queueLength()` = `0`。

- [x] 在 Anvil 上完成买入侧：`faucet` → `approve` → `subscribe`
- [x] 读到三个数字：`tBill.balanceOf(you)`、`vault.navPerShare()`、`vault.totalClaimValue()`
- [x] 用 `make attest NAV=...` 改一次 NAV，确认**份额数量不变、索取权价值变化**
- [x] 执行一次 `make redeem`，确认它 revert——因为 `RedemptionQueue.enqueue` 还是 TODO（这是设计，不是 bug）
- [ ] （P5 完成后回补）用 `cast` 或测试完成卖出侧：`enqueue` → `settle` → `claim`，拿到 USDC

**意义**

这是唯一一个**不写代码**的阶段，却是后面所有阶段的认知地基。

在 Lab 1 里，`subscribe` 存 1000 USDC 就得到 1000 个币，币价永远是 1 美元。这里不是：你付 1000 USDC 买到的是**份额**；NAV 涨到 1.25，你的份额数量还是 1000，但 `assetsForShares` 算出来的价值变成 1250 USDC。**余额是固定的，价值是浮动的**——这就是「pegged token」和「claim」的全部区别。

`make redeem` 在 P5 之前必然 revert，正好让你亲眼看见：赎回不是一次 `transfer`，而是一条**队列**。这条队列就是 P5 要写的合约。

**技术细节见 §6.1（Ex1 行）与 `EXERCISES.md` Ex1。**

📄 **完整操作规范**：`2026-10-20-p1-bridge-walkthrough.md`
—— 含心智模型（`subscribe` / `attest` / `enqueue` 每一步发生了什么）、可照抄的 runbook、本次实测数字、三个数字的出口实验、五道自测题与故障排查。

---

### 5.4 P2 · 托管：份额存在，箱子可能空着（Ex2）

**出口** — ⬜ **待通过**

- [ ] `test_Ex2_SharesExistWhileTheCustodianHoldsNothing` 转绿
- [ ] `test_Ex2_RealHoldingsIsJustANumber` 转绿
- [ ] `make test` 核心 7 个仍全绿（未改动 `src/`）
- [ ] 能回答：`subscribe` 的过程中，**哪一个合约跟 custodian 说过话？**（答案：没有）

**意义**

这是四块木板里的第一块：**托管（custody）**。

`subscribe()` 只做三件事：收 USDC、按 NAV 算份额、mint 给用户。它**从头到尾没有调用过 custodian**。所以份额在你付钱的那一刻就存在了，跟托管箱里有没有 T-Bill 完全无关。

第二个测试更直接：`recordPurchase` 是 `onlyRole(CUSTODIAN_ROLE)`，admin 持有这个角色。调用它，`realHoldings()` 会跳起来，但 `usdc.balanceOf(address(custodian))` 仍然是 0。**链上相信的「背书」不是到账的现金，而是一个被敲进去的整数。**

这就是 Lab 1 与 Lab 2 的分水岭：`totalCollateral()` 是链上余额，链自己能数；`realHoldings()` 是一个报告值，链只能相信。P7 的 A1/A2 就建立在这个观察上。

> 自测：如果 `realHoldings()` 和 `usdc.balanceOf(custodian)` 可以不一致，那么「100% 足额抵押」这句话在链上还剩多少可验证性？

**技术细节见 §6.2。**

---

### 5.5 P3 · Attestation：一个数字重估整本账（Ex3）

**出口** — ⬜ **待通过**

- [ ] `test_Ex3_TheClaimFloats_TheShareCountDoesNot` 转绿
- [ ] `test_Ex3_OneCallMovesTheWholeBook` 转绿
- [ ] `make test` 核心 7 个仍全绿
- [ ] 能回答：`attest` 写进 feed 的那个数字，**链上有没有任何东西可以拿它去核对？**（答案：没有）

**意义**

第二块木板：**资产申报（attestation）**。

`vault.attest(nav)` 只做一件事：把 `nav` 写进 `MockPriceFeed`。它由 `REPORTER_ROLE` 保护，但**它写的是一个裸数字**。下游的 `subscribe` 定价、`assetsForShares`、`totalClaimValue`、赎回队列的 `assetsAtNav`，全都读这一个数。

> ⚠️ **mock 说明**：`MockPriceFeed.setPrice` 是公开的测试接口，没有权限控制；`vault.attest` 才是本实验讨论的报告人入口。生产环境应换成不可公开写入的 feed（如 Chainlink），否则「报告人角色」在链上形同虚设。这个 mock 层面的额外写入面可以写进 B1，但不要把它和 `attest` 的角色门混为一谈。

一个持有人 1000 份额，NAV 从 1.00 改到 1.25，份额数不动，索取权从 1000 USDC 变成 1250 USDC。两个持有人、一次 `attest`，两本账同时变。这就是「one call moves the whole book」。

这一阶段不给答案，只给问题：**链上没有任何东西能验证这个数字**。P7 的 B1（单一报告人的失败模式）和 B2（过期 NAV）都从这里长出来；P10 的 Ex7 就是把这个数字武器化。

> 自测：如果报告人连续 30 天不更新 NAV，而真实利率已经变了，谁能从这个「诚实的过期数字」里获利？

**技术细节见 §6.2。**

---

### 5.6 P4 · 准入：守卫在哪里，钥匙有多强（Ex4）

**出口** — ⬜ **待通过**

- [ ] `test_Ex4_NoKyc_NoShares_EvenIfYouPay` 转绿
- [ ] `test_Ex4_TransferChecksBothEndpoints` 转绿
- [ ] `test_Ex4_FreezeBeatsConfiscation` 转绿
- [ ] `make test` 核心 7 个仍全绿
- [ ] 能说清：为什么三个测试都必须用 `abi.encodeWithSelector` **钉死错误选择器**，而不能只写「它 revert 了」

**意义**

第四块木板：**准入（admission）**。

`TBillToken._update` 是每一笔余额变动的必经之路——mint、burn、transfer 都走它。它做两件事：`whenNotPaused` 全局暂停，以及**检查 `from` 和 `to` 两端**的白名单。所以：

1. 没 KYC 的地址，即使付了 USDC，也收不到份额（`subscribe` 里的 `mint` 会 revert）；
2. 白名单持有人也不能把份额转给不在名单上的地址（检查的是 `to`，错误里出现的也是 `to`）；
3. 把 alice 移出名单后，她转不出去——**而且 admin 也 burn 不掉她的份额**，因为 `burn(from, amount)` 走的是同一个 `_update`，`from = alice` 过不了白名单。

第三条是本阶段最反直觉的地方：**同一个守卫，既保护持有人不被发行人没收，也让发行人无法执行「强制转移」**。这就是 P7 的 D2——监管要求的两把钥匙（freeze 与 burn）在这里互相打架。

`pause()` 是另一把更钝的刀：它冻结转账、mint、redeem **全部**。P7 的 C2 会问：流动性紧张时，这是不是正确的工具？

> 自测：如果监管要求「冻结某个地址，但允许发行人没收其份额」，当前代码能不能做到？要改哪一处？

**技术细节见 §6.2。**

---

### 5.7 P5 · 赎回队列：T+1 不能原子结算（Ex5）

**出口** — ⬜ **待通过**

- [ ] `RedemptionQueue.assetsAtNav` 实现完毕
- [ ] `enqueue` 实现完毕（托管份额、锁定 NAV、生成 ticket）
- [ ] `settle` 实现完毕（严格 FIFO、all-or-nothing、放款、烧份额）
- [ ] `claim` 实现完毕（CEI，先清零再转账）
- [ ] `make exercise` 中 `02_QueueTasks.t.sol` 组 **11 个测试全绿**
- [ ] `make test` 核心 7 个仍全绿
- [ ] 能独立复述 `18 + 8 − 6 = 20`，并解释「除错 10 的幂为什么不会 revert」

**意义**

第三块木板：**赎回（redemption）**。

在 Lab 1 里，`redeem()` 是原子的：烧币、转账，一笔交易完成。在 RWA 里做不到——卖出 T-Bill、等现金到账需要时间（T+1）。所以赎回被拆成三步：

```
enqueue  ──▶  份额进队列，NAV 锁定，拿到 ticket
settle   ──▶  现金到账，按 ticket 顺序放款
claim    ──▶  用户把属于自己的现金提走
```

四个 TODO 各自对应一个坑：

| TODO | 要做的事 | 难点 |
|---|---|---|
| Ex5.1 `assetsAtNav` | 份额 → USDC | `18 + 8 − 6 = 20`，除以 `1e20` |
| Ex5.2 `enqueue` | 托管份额、锁定今天的 NAV | 先记账还是先转账？份额用 `transferFrom` 拉进来 |
| Ex5.3 `settle` | 严格 FIFO、all-or-nothing | 以本次传入的 `assets` 为预算；钱不够付下一张 ticket 就停，不能跳过去付后面的 |
| Ex5.4 `claim` | 提走已结算的现金 | CEI：先把 `claimable` 清零，再 `transfer` |

**三套小数**（Ex2 的续集，也是整个实验最经典的静默 bug）：

```
shares   tBILL   18 decimals
NAV      feed     8 decimals
assets   USDC     6 decimals     18 + 8 - 6 = 20  ->  divide by 10^20
```

除错 10 的幂**不会 revert，不变量也照样成立**，只是每一笔赔付都差 10^12 倍。这正是 Lab 1 Ex2 的「不变量只约束关系，不约束量级」在 RWA 里的重演。

> 自测：`settle(1500e6)` 面对两张各 1000e6 的 ticket，应该付几张？`head` 走到哪里？如果「平均分」给两张，会破坏哪条性质？

**技术细节见 §6.3。**

---

### 5.8 P6 · 不变量：让机器搜索反例（Ex6）

**出口** — ⬜ **待通过**

- [ ] Ex6.1 handler 的 `enqueue` 实现完毕
- [ ] Ex6.2 handler 的 `settle` 实现完毕
- [ ] Ex6.3 handler 的 `claim` 实现完毕
- [ ] `invariant_EscrowConservation` 改成真正要捍卫的性质并通过
- [ ] `invariant_SettlementSolvency` 改成真正要捍卫的性质并通过
- [ ] `make exercise` 中 `03_InvariantTasks.t.sol` 组全绿
- [ ] `make exercise` **总体全绿**（`01_*` / `02_*` / `03_*` 三组，共 20 个测试函数）
- [ ] `make test` 核心 7 个仍全绿
- [ ] 能回答：为什么 `vault.reserveBalance() >= queue.pendingAssets()` **不是**一条可以写出来的不变量？

**意义**

这是**方法论的跃升**。到 P5 为止，所有测试都是「我构造一个场景，然后检查结果」——它只能覆盖你想得到的攻击。不变量测试把方向反过来：**让机器随机、连续地调用操作，然后问「无论怎么折腾，这条性质还在不在」**。

`BridgeHandler` 是一个中间层：它把 `subscribe` / `attest` / `fundVault` / `enqueue` / `settle` / `claim` 包装成 fuzzer 可以随机调用的动作，并把角色授予 handler。没有 handler，fuzzer 要么调不到受权限保护的函数，要么在 `setUp` 之外乱撞。

两条要捍卫的性质：

```
escrow conservation   tBill.balanceOf(queue) == queue.pendingShares()
settlement solvency   usdc.balanceOf(queue) >= queue.totalClaimable()
```

第一条：队列持有的份额，正好等于它还欠着的份额。不丢一张，也不凭空多一张。
第二条：队列持有的现金，至少覆盖已结算待提取的金额。它不能欠已结算的钱。

> **注意 `assertGe` 而不是 `assertEq`**：有人可能直接给队列转 USDC（捐赠），所以「至少」才是正确的方向。

第三条关系看起来像不变量，但并不成立：

```
vault.reserveBalance() >= queue.pendingAssets()     // ❌ 不是不变量
```

待赎回的现金可能已经被投资到 T-Bill 里；vault 的 USDC buffer 只覆盖未投资的现金，不覆盖账面上的增值。NAV 上涨时，额外价值在**托管人那里的 T-Bill** 里，不在 vault 的 USDC buffer 里。这个问题的答案就是 P7 的 C1。

当断言失败时，Foundry 会打印**反例调用序列**——照着这个序列手工走一遍，你就能看到不变量到底在哪一步、被哪组参数打破。这是本实验中最接近真实安全审计的环节。

> **提示**：Foundry 会缓存反例到 `cache/invariant/`。如果结果诡异或反复失败，先 `rm -rf cache/invariant` 再跑。

**技术细节见 §6.4。**

---

### 5.9 P7 · 威胁模型作答（A–D + E，25%）

**出口** — ⬜ **待通过**

- [ ] `STUDENT-QUESTIONS.md` 中 A1/A2/B1/B2/C1/C2/D1/D2 **共 8 题**全部作答
- [ ] 每题 **150–300 词**（以英文作答，与题目语言一致）
- [ ] E 组的表：**7 个 Ex2–Ex4 行为**对应的测试函数名全部填写
- [ ] E 组额外补一个「你认为最可能被利用的场景」，并说明它破坏了哪块木板
- [ ] 每个论断都能指回 P1–P6 中亲眼看过的某个现象或某次测试

**意义**

**权重 25%，是全表第二高的单项，且不需要写一行代码。**

它是把前六个阶段的动手经验**兑换成判断力**的地方。题目按四块木板分组：

| 分组 | 题号 | 主题 | 可引用的实验证据 |
|---|---|---|---|
| A. 托管 | A1 / A2 | 写出这个系统的「等价不变量」，并说明它还证明了什么；SPV 的法律结构与破产隔离 | Ex2.1 / Ex2.2；`realHoldings()` vs `usdc.balanceOf(custodian)` |
| B. Attestation | B1 / B2 | 单一报告人的失败模式与缓解；**过期但诚实**的 NAV 如何被利用 | Ex3.1 / Ex3.2；`attest` 只写一个裸数字；`MockPriceFeed` 把 `updatedAt` 填成 `block.timestamp`，永远看起来很新 |
| C. 赎回 | C1 / C2 | enqueue 时锁 NAV，NAV 上涨时谁赚谁亏；2008 vs 2023，`pause()` 为何是错的工具 | Ex5.2 `LocksTheRate`；Ex6 的「第三条关系」；`TBillToken.pause()` |
| D. 准入 | D1 / D2 | 两端白名单的边界由谁定；freeze 与 confiscation 的冲突，两边的理由与保障 | Ex4.1 / Ex4.2 / Ex4.3；`_update` 同时管 transfer 和 burn |
| E. 测试 | E 表 | 七个行为的测试函数名 + 一个最可能被攻击的场景 | 直接回填 P2–P4 的测试 |

> 这些题目**没有标准答案**，它们才是本实验真正的重点。B2 和 C2 已经越出代码，进入机制设计与法律结构；D2 要求你同时论证监管权力的两面。

**写作纪律**

1. **先做后写**：每道题都要能指回一个你亲眼看过的数字或一次测试。没有实验证据的答案，读起来就是百科词条。
2. **不要复述代码**：题目问的是「为什么」和「谁承担后果」，不是「这个函数做了什么」。
3. **控制词数**：150–300 词，写完自己数一遍。低于 150 通常是漏了论证层；高于 300 通常是背景铺垫太多。
4. **区分相邻概念**：B2 的「stale NAV」不是「wrong NAV」；D2 的「freeze」不是「pause」；C1 的「锁定 NAV」不是「结算 NAV」。
5. **E 表先填函数名，再写场景**：函数名是客观的，场景要说明它破坏哪块木板（a/b/c/d）。

**技术细节见 §7。**

---

### 5.10 P8 · 上测试网（Tier 2，20%）

**出口** — ⬜ **待通过**

- [ ] `cp .env.example .env`，填入**一次性钱包**的私钥、Sepolia RPC、Etherscan API Key
- [ ] `forge script script/Deploy.s.sol:Deploy --rpc-url $SEPOLIA_RPC_URL --broadcast --verify --private-key $PRIVATE_KEY` 广播成功
- [ ] 拿到 **7 个合约地址**（MockUSDC / ComplianceRegistry / MockPriceFeed / TBillToken / MockTBillCustodian / TBillVault / RedemptionQueue）
- [ ] 7 个合约在 Etherscan 上**全部验证通过**
- [ ] `README.md` 的 `## Deployment (Sepolia)` 下有 7 行地址 + Etherscan 链接
- [ ] 部署后核验接线（见下）
- [ ] 私钥只存在于 `.env`（已在 `.gitignore`，且**不在提交 zip 里**）

**部署后核验**

```
hasRole(MINTER_ROLE,            vault)  = true
hasRole(MINTER_ROLE,            queue)  = true
hasRole(CUSTODIAN_ROLE,         vault)  = true   (在 custodian 上)
vault.queue()                           = queue
compliance.isWhitelisted(queue)         = true
compliance.isWhitelisted(admin)         = true
totalSupply = 0    reserveBalance = 0
```

**部署命令**

```bash
cp .env.example .env
# 编辑 .env：PRIVATE_KEY / SEPOLIA_RPC_URL / ETHERSCAN_API_KEY
set -a; source .env; set +a

forge script script/Deploy.s.sol:Deploy \
  --rpc-url "$SEPOLIA_RPC_URL" \
  --broadcast --verify \
  --private-key "$PRIVATE_KEY"
```

- `--verify` 需要 `ETHERSCAN_API_KEY`（<https://etherscan.io/myapikey> 免费申请）。
- **API Key 留空不影响部署**：合约照样上链，只有验证这一步报错。**不要因此重新部署**；事后单独验证即可：

```bash
# 例：MockUSDC 没有构造函数参数
forge verify-contract <MockUSDC地址> src/MockUSDC.sol:MockUSDC \
  --chain sepolia --etherscan-api-key "$ETHERSCAN_API_KEY"

# 其余合约按部署脚本的实际参数补 --constructor-args
# 例如 TBillToken(address admin, address compliance)
```

**Lab 1 部署时踩过的两个坑（可能复现）**

| 现象 | 根因 | 解法 |
|---|---|---|
| `in-flight transaction limit reached for delegated accounts` / `gapped-nonce tx` | 部署账户被升级为 EIP-7702 委托账户，RPC 限制在途交易数，而脚本一次连发多笔 | 加 `--slow`，每笔确认后再发下一笔 |
| 合约创建 `status 0`，`gasUsed == gasLimit` | 该 RPC 的 `eth_estimateGas` 严重偏低 | 加 `-g 1000`（gas 估算放大 10 倍） |

> `forge script` **没有** `--gas-limit` 选项；要调整 gas 只能用 `-g/--gas-estimate-multiplier`。

**意义**

本地链与真实网络之间隔着的不是技术，而是**成本与不可逆性**。Anvil 上重启一次就干净了；Sepolia 上每一笔交易都留下永久记录、都无法撤回。

Etherscan 验证带来的**公开可读性**是 RWA 的核心诉求：一个代币化国债产品，托管人、NAV 报告人、白名单管理员分别是谁，外部能不能独立核对——这正是这个行业信任的落点。

> ⚠️ **Tier 2 部署的是 mock 系统**：`MockPriceFeed.setPrice` 没有权限控制，任何地址都能改 NAV；`MockUSDC.faucet` 也向所有人开放。它们只用于演示，不要当作生产系统。部署后在 README 里写清这一点，反而能说明你理解 mock 与真实 oracle 的差别。

⚠️ **提交私钥本项计零分。**

---

### 5.11 P9 · 文档、架构图与打包（15%）

**出口** — ⬜ **待通过**

- [ ] `README.md` 中有**架构图**，画清四块木板（a 托管 / b attestation / c 赎回 / d 准入）
- [ ] 图中画清**现金与份额的过桥方向**（USDC 如何进/出，tBILL 如何铸造/托管/销毁）
- [ ] 手绘拍照可以，但四块木板和箭头缺一不可
- [ ] 代码命名清晰；注释解释**为什么**，而不是复述代码在做什么
- [ ] `make fmt` 已执行，`forge fmt --check` 无输出（`line_length = 100`）
- [ ] `README.md` 有 `## Deployment (Sepolia)` 地址表（P8 产出）
- [ ] `STUDENT-QUESTIONS.md` 已作答（P7 产出）
- [ ] 从项目根目录打包，`lib/` 在 zip 内
- [ ] zip 中**没有 `.env`**，也没有任何私钥
- [ ] 解压后能直接 `make test` / `make exercise`（不依赖网络）

**打包命令**

```bash
rm -f .env
zip -r submission.zip . \
  -x '.git/*' 'out/*' 'cache/*' 'broadcast/*' '.env' '.DS_Store'
```

> **保留 `lib/`**：这是 vendored 依赖，评分者靠它离线运行测试。删掉它，对方就得联网拉 GitHub。

**提交前自查**

```bash
# 1. zip 里没有 .env
unzip -l submission.zip | grep -E '\.env$' && echo "STOP: .env in zip" || echo "ok: no .env"

# 2. 源码/文档里没有 64 位十六进制私钥
rg -n "0x[0-9a-fA-F]{64}" --glob '!lib/**' --glob '!submission.zip' || echo "ok: no 64-hex key"

# 3. 三个命令的实际结果
make doctor
make test
make exercise
```

> `rg` 不是标配；没有的话用 `grep -rnE "0x[0-9a-fA-F]{64}" --exclude-dir=lib .`。

**意义**

15% 不是白送的。架构图考的是**你有没有把四块木板和现金流/份额流装进一个脑子**；注释考的是**你能不能解释设计取舍**，而不是把函数名翻译一遍。

RWA 系统的读者通常不是写合约的人：合规、运营、审计、投资人都会看这份 README。图比代码先被读到。

---

### 5.12 P10 · 挑战（Tier 3，可选，不计分）

**出口**（任选其一）

- [ ] `make challenge` 转绿——在 `test_falseNav()` 中让自己最终持有的 USDC 多于开始时，并让基金资不抵债
- [ ] 或：给 NAV feed 加 **staleness check**（读取 `updatedAt`，超过心跳就 revert），并补测试
- [ ] 或：实现 **ERC-3643** 权限层（身份/claims 替代简单的白名单）
- [ ] 或：用**真实 Chainlink feed** 替换 `MockPriceFeed`（先读 `decimals()`，不要硬编码 8）

**意义**

前面所有阶段你都在**防守**：写测试、建不变量、推演威胁模型。这一阶段换到**进攻位**。

Ex7 的设定是：你是一个 KYC 通过的客户，同时持有 `REPORTER_ROLE` 和 `SETTLER_ROLE`（泄露的签名密钥，或被收买的运营台）。Alice 是一个什么都没做的诚实持有人。目标是**在基金受损的前提下，让自己最终持有的 USDC 多于初始的 1000e6**。

提示只有一句：**vault 同时用 `navPerShare()` 给申购定价和给赎回放款。你能改这个数字。从「我能写 NAV」到「我持有的 USDC 变多」，最短的路径是什么？**

这道题依赖 P5：队列没实现，`enqueue` 一步就 revert。另外三个选项不依赖 P5。

另外三个选项是把 P7 的答案写成代码：B2 的 staleness check、D1/D2 的 ERC-3643 权限层、B1 的真实 oracle。它们不计分，但能让你的报告从「我做过实验」变成「我改进了系统」。

**技术细节见 §6.6。**

---

## 6. 作业要求

### 6.1 Tier 1（必做）— Ex0 至 Ex6

| # | 任务 | 验收命令 / 交付物 | 卡住时看哪里 |
|---|---|---|---|
| **Ex0** | 环境搭建，核心测试全绿 | `make doctor` 全绿 → `make test`（7 绿） | `README.md` §1 Setup |
| **Ex1** | 在命令行上走一遍桥：faucet → subscribe → 读 NAV / holdings → 观察 redeem revert | `make subscribe AMOUNT=1000000000` 后 `make nav` / `make holdings`；P5 后回补赎回侧 | `EXERCISES.md` Ex1、`README.md` §2 |
| **Ex2** | 写两个测试证明托管木板 | `01_BridgeTasks.t.sol` 中两个 `test_Ex2_*` 转绿 | Ex2 提示、`MockTBillCustodian.sol` |
| **Ex3** | 写两个测试证明 attestation 木板 | 同文件两个 `test_Ex3_*` 转绿 | Ex3 提示、`TBillVault.attest` |
| **Ex4** | 写三个测试证明准入木板 | 同文件三个 `test_Ex4_*` 转绿 | Ex4 提示、`TBillToken._update` |
| **Ex5** | 实现赎回队列的四个 TODO | `02_QueueTasks.t.sol` 全绿（11 个测试） | `RedemptionQueue.sol` |
| **Ex6** | 实现 handler 三个动作 + 两个不变量 | `03_InvariantTasks.t.sol` 全绿 | `03_InvariantTasks.t.sol` 注释 |
| **Ex7（Tier 3）** | 利用 reporter key 获利 | `make challenge` 转绿 | `test/challenges/FalseNav.t.sol` |

**Tier 1 不要求部署到测试网**，本地 Anvil 足够。所有练习的统一验收命令是：

```bash
make exercise    # 未完成时是红的——红色就是你的任务清单，不是 bug
```

> 再强调一次：`make test` 应始终全绿（7 个核心测试）；`make exercise` 完成后全绿（20 个测试函数）。两个命令的分工不要混淆。

### 6.2 Ex2 / Ex3 / Ex4 详细要求（`01_BridgeTasks.t.sol`）

**Ex2 · 托管（plank a）**

| 函数 | 要证明的事 | 关键断言 |
|---|---|---|
| `test_Ex2_SharesExistWhileTheCustodianHoldsNothing` | 你持有 1000e18 份额，而托管人报告 0 | `tBill.balanceOf(alice) == 1_000e18`；`custodian.realHoldings() == 0` |
| `test_Ex2_RealHoldingsIsJustANumber` | 「背书」是一个权限地址敲进去的整数 | `recordPurchase(1_000_000e6)` 后 `realHoldings()` 跳变，而 `usdc.balanceOf(custodian) == 0` |

**Ex3 · Attestation（plank b）**

| 函数 | 要证明的事 | 关键断言 |
|---|---|---|
| `test_Ex3_TheClaimFloats_TheShareCountDoesNot` | NAV 上涨：份额数量不变，**价值**变了 | `attest(1.25e8)` 后 `balanceOf` 仍 `1_000e18`，`totalClaimValue` 从 `1_000e6` → `1_250e6` |
| `test_Ex3_OneCallMovesTheWholeBook` | 一次 `attest` 同时重估所有持有人 | alice 和 bob 的 `assetsForShares(balanceOf(who))` 一起变 |

**Ex4 · 准入（plank d）**

| 函数 | 要证明的事 | 关键断言 |
|---|---|---|
| `test_Ex4_NoKyc_NoShares_EvenIfYouPay` | 不在白名单，付了钱也收不到份额 | `vm.expectRevert(abi.encodeWithSelector(TBillToken.NotWhitelisted.selector, attacker))` |
| `test_Ex4_TransferChecksBothEndpoints` | 转账检查**接收方**，不只是发送方 | alice → attacker 的 `transfer` 以 `NotWhitelisted(attacker)` revert |
| `test_Ex4_FreezeBeatsConfiscation` | 移出名单后冻结持有人，**而且** `burn` 也 revert | alice 的 transfer revert；admin 调 `tBill.burn(alice, 1_000e18)` 同样 `NotWhitelisted(alice)` |

> **三个测试都必须钉死错误选择器。** 只写「它 revert 了」的测试，在守卫被删掉后依然可能是绿的——它没有证明任何东西。

### 6.3 Ex5 · 赎回队列（四个 TODO）

> 实现见 `src/exercises/RedemptionQueue.sol`；验收见 `test/exercises/02_QueueTasks.t.sol`（11 个测试）。**不要改测试文件。**

| TODO | 要做的事 | 难点 / 检查点 |
|---|---|---|
| Ex5.1 `assetsAtNav` | `shares * nav / 1e20` | 18 + 8 − 6；除以 `10^20`，不是 `10^12` |
| Ex5.2 `enqueue` | 拒绝 0；`transferFrom` 把份额拉进队列；读 `vault.navPerShare()` 锁定 `assetsLocked`；`requests.push`；更新 `pendingShares` / `pendingAssets`；返回 `id` | 先拉份额再记账，还是先记账再拉？`transferFrom` 需要用户先 `approve(queue)` |
| Ex5.3 `settle` | 用传入的 `assets` 作为预算（`remaining`），从 `head` 开始逐张检查 `assetsLocked <= remaining`；满足则先更新队列状态（标记 `settled`、`head++`、减 `pendingShares` / `pendingAssets`、加 `claimable[owner]` / `totalClaimable`），再 `vault.releaseReserves(address(this), assetsLocked)` 放款、`tBill.burn(address(this), shares)` 烧 escrow，最后 `remaining -= assetsLocked`；返回实际付出 | **严格 FIFO**；一张 ticket 全付或全不付；钱不够付下一张就停，不能跳过去付后面的；burn 需要队列持有 `MINTER_ROLE` 且在名单上；优先按 CEI 先改状态再做外部调用 |
| Ex5.4 `claim` | 读 `claimable[msg.sender]`；为 0 则 `NothingToClaim`；**先清零** `claimable` 和 `totalClaimable`；再 `safeTransfer` | CEI：先清零再转账，否则可重入/重复提取 |

**三套小数**：

```
shares   tBILL   18 decimals
NAV      feed     8 decimals
assets   USDC     6 decimals     18 + 8 - 6 = 20  ->  divide by 10^20
```

反向换算（给定 USDC 求份额）：`assets * 1e20 / nav`。

**两个必须理解的接线**：

1. 队列必须持有 `MINTER_ROLE`，因为 `settle` 要 `burn` 自己托管的份额；
2. 队列必须在白名单上，因为 `burn` 是余额变动，`_update` 会检查 `from = queue`。

### 6.4 Ex6 · 不变量（五个 TODO）

> 实现见 `test/exercises/03_InvariantTasks.t.sol`。**Ex6 依赖 Ex5**：队列还是 stub 时，handler 只会看到 revert。

| TODO | 要做的事 | 检查点 |
|---|---|---|
| Ex6.1 handler `enqueue` | 给两个参数命名；随机选用户；余额为 0 则 return；`bound(shares, 1, balance)`；`approve(queue)`；`queue.enqueue(shares)`；递增 `ghost_enqueues` | 不 `approve` 会 revert；余额为 0 的用户必须提前返回 |
| Ex6.2 handler `settle` | `vault.reserveBalance()` 为 0 则 return；`bound(assets, 1, reserveBalance)`；`queue.settle(assets)`；递增 `ghost_settles` | 用 `bound` 而不是 `%`，保证区间合法 |
| Ex6.3 handler `claim` | 随机选用户；`claimable(user) == 0` 则 return；`vm.prank(user); queue.claim()`；递增 `ghost_claims` | 没有可领取金额时提前返回，避免 fuzzer 一直撞 `NothingToClaim` |
| Ex6.4 `invariant_EscrowConservation` | `assertEq(tBill.balanceOf(address(queue)), queue.pendingShares())` | 队列不丢份额、不造份额 |
| Ex6.5 `invariant_SettlementSolvency` | `assertGe(usdc.balanceOf(address(queue)), queue.totalClaimable())` | 队列不欠已结算的现金；用 `>=` 而不是 `==` |

**为什么用 `assertGe`**：有人可能直接向队列转 USDC（捐赠），所以队列持有的现金可以多于待领取总额；「至少覆盖」才是正确的方向。

**为什么第三条关系不是不变量**：

```
vault.reserveBalance() >= queue.pendingAssets()     // ❌
```

待赎回的现金可能已经被投资到 T-Bill 里；vault 的 USDC buffer 只覆盖未投资的现金，不覆盖账面上的增值。NAV 上涨时，额外价值在托管人那里的 T-Bill 里，不在 vault 的 USDC buffer 里。这个问题的答案写进 P7 的 C1。

**读反例**：断言失败时，Foundry 打印的调用序列就是一份可复现的审计报告。照着序列手工走一遍，找出是哪一步、哪组参数打破了性质。先 `rm -rf cache/invariant` 再重跑，可以避免缓存干扰。

### 6.5 Tier 2（20%）— 测试网部署与源码验证

把七份合约部署到 **Sepolia** 并在 Etherscan 上验证源码，提交地址表。

```bash
cp .env.example .env
# 填 PRIVATE_KEY / SEPOLIA_RPC_URL / ETHERSCAN_API_KEY
set -a; source .env; set +a

forge script script/Deploy.s.sol:Deploy \
  --rpc-url "$SEPOLIA_RPC_URL" --broadcast --verify --private-key "$PRIVATE_KEY"
```

- 七个地址按部署顺序打印：`MockUSDC`、`ComplianceRegistry`、`MockPriceFeed`、`TBillToken`、`MockTBillCustodian`、`TBillVault`、`RedemptionQueue`。
- 结果写进 `README.md` 的 `## Deployment (Sepolia)`，每行一个合约 + 地址 + Etherscan 链接。
- **API Key 留空不影响部署**；验证失败不要重新部署，用 `forge verify-contract` 事后补。
- ⚠️ **必须使用全新的、只放测试币的丢弃式钱包**。私钥只能留在 `.env`（已在 `.gitignore` 中）——**提交私钥本项计零分**。
- Sepolia 测试 ETH 水龙头：<https://cloud.google.com/application/web3/faucet/ethereum/sepolia>

### 6.6 Tier 3（可选，不计分）— 任选其一

| 选项 | 内容 |
|---|---|
| **Ex7 · 假 NAV 套利** | `make challenge` → `test/challenges/FalseNav.t.sol`。你是 KYC 客户，同时持有 reporter 和 settler 的钥匙；目标是最终 USDC 多于初始 1000e6，且基金资不抵债。只改 `test_falseNav()`。依赖 P5。 |
| **NAV staleness check** | 在 `TBillVault.navPerShare()` 中读取 `latestRoundData().updatedAt`，超过心跳就 revert；补测试。这是 P7 B2 的代码版本。 |
| **ERC-3643 权限层** | 用 ERC-3643（T-REX）的 identity / claims 机制替代 `ComplianceRegistry` 的简单白名单；至少实现「只有通过 claim 校验的地址才能接收」。 |
| **真实 Chainlink feed** | 用 Sepolia 的 `AggregatorV3Interface` 替换 `MockPriceFeed`。**先读 `decimals()`，不要硬编码 8**；同时处理 `updatedAt` 过期。 |

---

## 7. 讨论题要求（`STUDENT-QUESTIONS.md`）

在每道题下方直接作答，**每题 150–300 词，重推理而非篇幅**。题目语言是英文，答案也用英文。

| 分组 | 题号 | 主题 | 作答时必须引用的实验证据 |
|---|---|---|---|
| A. 托管 | A1 | 写出这个系统的「等价不变量」；它实际断言了什么，又不再证明什么 | Ex2.1 / Ex2.2；`realHoldings()` 与 `usdc.balanceOf(custodian)` 的差异 |
| A. 托管 | A2 | 为什么法律结构（SPV、破产隔离）是技术设计的一部分；托管人破产时链上代币赋予持有人什么 | Ex2.2；custodian 只是一个报告数字 |
| B. Attestation | B1 | 单一报告人的失败模式，以及每一种的缓解机制 | Ex3.1 / Ex3.2；`attest` 只写一个裸数字 |
| B. Attestation | B2 | **过期但诚实**的 NAV 如何被利用；`updatedAt` 检查为什么重要 | `MockPriceFeed.latestRoundData()` 返回 `block.timestamp`；无 staleness check |
| C. 赎回 | C1 | enqueue 时锁 NAV：NAV 上涨时谁赚谁亏；这是否是正确的风险分配；如何改 | Ex5.2 `LocksTheRate`；Ex6 的「第三条关系」 |
| C. 赎回 | C2 | 2008 MMF vs 2023 USDC；「关闭赎回通道」对代币化基金意味着什么；`pause()` 为什么是错的工具 | `TBillToken.pause()`；Ex4 的 freeze；队列的 FIFO |
| D. 准入 | D1 | 两端白名单的边界应该画在哪里；谁有权移动它 | Ex4.1 / Ex4.2；`ComplianceRegistry` 的角色 |
| D. 准入 | D2 | freeze 与 confiscation 的冲突：论证两边，给出保障措施与钥匙持有人 | Ex4.3；`_update` 同时管 transfer 和 burn |
| E. 测试 | E 表 | 7 个 Ex2–Ex4 行为的测试函数名 + 1 个最可能被利用的场景 | 回填 P2–P4 的测试 |

**E 表的 7 行**（从 `STUDENT-QUESTIONS.md` 抄下来，逐行填函数名）：

| Plank | 场景 | 你的测试函数名 |
|---|---|---|
| a | Shares exist while the custodian holds nothing | |
| a | `realHoldings()` moves with no cash moving | |
| b | The claim value floats while the share count stays | |
| b | One `attest` re-prices every holder at once | |
| d | A non-whitelisted address cannot receive shares, even by paying | |
| d | A whitelisted holder cannot send shares to a non-whitelisted address | |
| d | Removing an address freezes that holder — and blocks a burn | |

> E 组最后那个「最可能被利用的场景」没有标准答案，但必须说明它破坏的是哪块木板（a/b/c/d），并尽量指回你在 P2–P6 看到的某个现象。

---

## 8. 提交物清单

从**项目根目录**构建一个 zip，提交到 Moodle。zip 必须包含 `lib/`。

```bash
rm -f .env
zip -r submission.zip . \
  -x '.git/*' 'out/*' 'cache/*' 'broadcast/*' '.env' '.DS_Store'
```

| # | 提交物 | 位置 | 对应评分项 |
|---|---|---|---|
| 1 | 代码，`make exercise` 全绿 | `src/`、`test/` | 40% |
| 2 | 讨论题作答 | `STUDENT-QUESTIONS.md` | 25% |
| 3 | 架构图（四块木板 + 现金/份额流向） | `README.md` | 15% |
| 4 | Sepolia 七地址 + Etherscan 链接 | `README.md` 的 `## Deployment (Sepolia)` | 20% |
| 5 | （可选）Tier 3 | 代码 / README 说明 | 不计分 |

**提交前最后三件事**

1. `rm -f .env`——私钥在 zip 里任何位置，本项**计零分**；
2. 确认 `lib/` 在 zip 内——否则评分者无法离线运行；
3. 解压到干净目录，跑一遍 `make doctor` / `make test` / `make exercise`。

---

## 9. 评分标准

| 评分项 | 权重 | 对应阶段 |
|---|---|---|
| 合约正确性 + 测试覆盖率（Ex0–Ex6） | **40%** | P0–P6 |
| 测试网部署与 Etherscan 源码验证（Tier 2） | **20%** | P8 |
| 威胁模型分析（A–D + E） | **25%** | P7 |
| 代码风格与文档（含架构图） | **15%** | P9 |
| Tier 3（可选） | 不计分 | P10 |

**40% 的细分**（按作业原文）：

| 子项 | 内容 |
|---|---|
| (i) | Ex0 — `make doctor`、`make test` 全绿 |
| (ii) | Ex2 — `01_BridgeTasks.t.sol` 中两个 `test_Ex2_*` |
| (iii) | Ex3 — 同文件两个 `test_Ex3_*` |
| (iv) | Ex4 — 同文件三个 `test_Ex4_*` |
| (v) | Ex5 — `RedemptionQueue.sol` 的四个 TODO |
| (vi) | Ex6 — handler 的 `enqueue` / `settle` / `claim` + 两个 `invariant_*` |

> Ex1 是 warm-up，不计分。Tier 1 只用本地 Anvil 即可。

---

## 10. 验收标准与红线

### 10.1 完成定义（Definition of Done）

> 本清单是 §5 各阶段出口的**并集**：每通过一个阶段出口，勾掉对应的几项。

- [x] `make doctor` 全绿
- [x] `make test` 全绿（`7 passed; 0 failed`）
- [ ] `make exercise` 全绿（`01_*` / `02_*` / `03_*` 三组，共 20 个测试函数）
- [x] Ex1 的买入侧已走通（faucet → subscribe → 读 NAV / holdings → 观察 redeem revert）
- [ ] P5 完成后回补 Ex1 卖出侧（enqueue → settle → claim）
- [ ] `STUDENT-QUESTIONS.md` 的 A1–D2 共 8 题全部作答（每题 150–300 词）
- [ ] E 表 7 行填写完整，并补一个最可能被利用的场景
- [ ] `README.md` 中有架构图，四块木板与现金/份额流向齐全
- [ ] `README.md` 中有 `## Deployment (Sepolia)`，7 个地址 + Etherscan 链接
- [ ] `forge fmt` 已执行，格式符合 `line_length = 100`
- [ ] 从项目根目录打包，`lib/` 在 zip 内，`.env` 不在 zip 内
- [ ] （Tier 3 选做）`make challenge` 转绿，或完成 staleness / ERC-3643 / Chainlink 之一

### 10.2 红线（违反即扣分或计零）

1. **不得提交私钥**——`.env` 已在 `.gitignore` 中；私钥出现在 zip 的任何位置，本项**计零分**。Tier 2 只能用全新的、仅含测试币的丢弃式钱包。
2. **不得修改 `lib/`**——依赖随仓库分发，改坏了用 `git checkout -- lib` 还原。
3. **不得升级 OpenZeppelin**——本仓库锁定 `v5.0.2`。
4. **不得为了变绿而弱化断言**——尤其不要删掉 `abi.encodeWithSelector` 改用模糊的 `expectRevert()`。
5. **不得改给定的验收测试**——`02_QueueTasks.t.sol` 明确说「Do not edit this file」；`01_*` 和 `03_*` 只在 TODO 处填写；`test/TBill.t.sol` 是答案，先自己写，卡住再看。
6. **不得改 Tier 1 的给定合约**——Tier 1 唯一要改的源文件是 `RedemptionQueue.sol` 的四个 TODO；其他 `src/` 合约是给定条件。Tier 3 的改动另计，并在 README 说明。
7. **Ex7 只改 `test_falseNav()`**——不要改 `setUp()`、`_isSolved()` 或初始状态检查。

### 10.3 高频问题速查

| 症状 | 原因与处理 |
|---|---|
| `subscribe` revert `NotWhitelisted` | 接收方不在名单；先 `compliance.setWhitelisted(user, true)` |
| `settle` revert `NotWhitelisted` | **队列本身**不在名单；burn 也是余额变动，`from = queue` 要过白名单 |
| `invest` revert `AccessControlUnauthorizedAccount` | custodian 不认 vault；补 `custodian.grantRole(CUSTODIAN_ROLE, vault)` |
| `settle` revert `NotQueue` / `InsufficientReserves` | `vault.setQueue(queue)` 没做，或 vault buffer 没钱（先 `depositReserves`） |
| `make redeem` revert | P5 没完成，`enqueue` 还是 stub——这是设计 |
| 金额差 10^12 / 10^6 | 三套小数混用；`shares * nav / 1e20`，不是 `/1e12` |
| `make exercise` 全红 | 预期行为——`test/exercises/` 就是任务清单 |
| 不变量失败 / 结果诡异 | Foundry 缓存了反例；`rm -rf cache/invariant` 再跑 |
| 重启 Anvil 后地址变了 | Anvil 每次从干净状态启动，必须重新部署 |
| `Ownable` / 角色相关报错 | OZ v5 破坏性变更，网上 v4 教程会失败；本仓库固定 v5.0.2 |
| 测试通过但你认为它应该失败 | 断言太宽；`expectRevert` 必须钉死 selector |
| `lib/` 为空 / `ds-test/test.sol` 找不到 | `git checkout -- lib` |
| Sepolia 报 `in-flight transaction limit` | 加 `--slow`（EIP-7702 委托账户） |
| Sepolia 合约创建 `status 0`、`gasUsed == gasLimit` | gas 估算偏低，加 `-g 1000` |
| `forge fmt --check` 有输出 | 跑 `make fmt` |
| zip 里混进 `.env` | `rm -f .env` 后重新打包；私钥在 zip 里计零分 |

---

## 11. 常用命令速查

```bash
# 环境与检查
make doctor            # 环境自检（约 30 秒）
make test              # 核心测试，应始终全绿（7 passed）
make exercise          # 作业清单，完成后全绿（20 个测试函数）
make challenge         # Ex7 挑战，解开前一直是红的
make fmt               # 格式化合约

# 本地链
make anvil             # 终端 A：启动本地链
make deploy-anvil      # 终端 B：部署（打印 admin + 7 个地址）

# 手工走桥（先 export USDC=... TBILL=... VAULT=... QUEUE=... CUSTODIAN=... ALICE=...）
make subscribe AMOUNT=1000000000
make nav
make holdings
make attest NAV=125000000
make redeem AMOUNT=1000000000000000000
make queue

# 单组测试
forge test --match-path 'test/exercises/01_BridgeTasks.t.sol' -vv
forge test --match-test 'Ex2' -vv
forge test --match-path 'test/exercises/02_QueueTasks.t.sol' -vv
forge test --match-path 'test/exercises/03_InvariantTasks.t.sol' -vv

# 链上读取
cast call $VAULT "totalClaimValue()(uint256)" --rpc-url http://127.0.0.1:8545
cast call $TBILL "balanceOf(address)(uint256)" $ALICE --rpc-url http://127.0.0.1:8545
cast call $CUSTODIAN "realHoldings()(uint256)" --rpc-url http://127.0.0.1:8545

# 快照（需要保留演示状态时）
make snapshot          # Ctrl-C 时存盘
make restore           # 从 demo-state.json 恢复
```

---

## 12. 关键概念与精度对照

| 概念 | 含义 |
|---|---|
| **claim（索取权）** | 链上代币不是资产本身，而是对链下资产的权利；链能验证代币账本，不能验证资产存在 |
| **四块木板** | 托管（a）、attestation（b）、赎回（c）、准入（d）；每块都是一个信任边界 |
| **NAV** | 每份份额的价值，8 位小数；`1.00e8` 为 par |
| **attestation** | 报告人把 NAV 写进 feed 的动作；这是链上唯一的「资产窗口」 |
| **stale NAV** | 数字是诚实的，但已经过期；与「错误的 NAV」是两种不同攻击 |
| **T+1** | 卖出 T-Bill 到现金入账的时滞；赎回因此不能原子完成 |
| **FIFO / all-or-nothing** | 赎回队列严格按 ticket 顺序结算；一张 ticket 要么全付，要么留到下次 |
| **escrow conservation** | `tBill.balanceOf(queue) == queue.pendingShares()` |
| **settlement solvency** | `usdc.balanceOf(queue) >= queue.totalClaimable()` |
| **第三条关系** | `vault.reserveBalance() >= queue.pendingAssets()` 看起来像不变量，实际不是——增值在托管人那里 |
| **SPV / 破产隔离** | 持有资产的法律实体；资产不因发行人破产而被追索 |
| **permissioned token** | 每个余额变动都要检查白名单的代币；证券型代币的常见要求 |
| **ERC-3643** | 基于身份/claims 的许可型代币标准（T-REX）；Tier 3 选项 |
| **CEI** | Checks-Effects-Interactions：先改状态，再做外部调用 |

**小数位对照表**

| 对象 | 小数位 | 备注 |
|---|---|---|
| `MockUSDC` (mUSDC) | 6 | 法币稳定币惯例 |
| `TBillToken` (tBILL) | 18 | 基金份额，故意与 USDC 形成反差 |
| `MockPriceFeed` | 8 | 模拟 Chainlink NAV/价格源 |
| Ex5 / Vault 换算 | — | `18 + 8 − 6 = 20`，即除以 `1e20` |
| 反向换算 | — | `assets * 1e20 / nav` |

---

## 13. 变更记录

| 版本 | 日期 | 说明 |
|---|---|---|
| v1.3 | 2026-10-20 | 新增下游规范 `2026-10-20-p1-bridge-walkthrough.md`（P1 操作规范）；§5.3 加入链接；§13 已发布清单更新 |
| v1.2 | 2026-10-20 | **P1 出口已通过（买入侧）**：Anvil 上完成 faucet → subscribe → attest；份额 `1_000e18` 不变、claim value `1_000e6 → 1_250e6`；custodian 仍为 0；`make redeem` 按预期以 `TODO Ex5.2` revert；§5.1 状态列、§5.3 出口清单与 §10.1 完成定义已回写 |
| v1.1 | 2026-10-19 | **P0 出口已通过**：`make doctor` 6 passed / 0 failed，`make test` 7 passed，`forge --version` v1.8.5；§5.1 状态列、§5.2 出口清单与 §10.1 完成定义已回写 |
| v1.0 | 2026-10-19 | 首版：汇总作业要求与仓库内 `README.md` / `EXERCISES.md` / `STUDENT-QUESTIONS.md` / `Makefile`，按 Ex 分阶段（P0–P6），并加入 P7 威胁模型、P8 Tier 2、P9 文档打包、P10 Tier 3 |

**已发布的下游规范**

- `2026-10-20-p1-bridge-walkthrough.md` —— P1 阶段操作规范（买入侧 + P5 回补卖出侧）

**后续规范文件计划**（占位，待撰）

- `2026-10-19-p2-ex2-custody-spec.md` —— P2 · Ex2 托管
- `2026-10-19-p3-ex3-attestation-spec.md` —— P3 · Ex3 Attestation
- `2026-10-19-p4-ex4-admission-spec.md` —— P4 · Ex4 准入
- `2026-10-19-p5-ex5-redemption-queue-spec.md` —— P5 · Ex5 赎回队列
- `2026-10-19-p6-ex6-invariant-testing-spec.md` —— P6 · Ex6 不变量测试
- `2026-10-19-p7-threat-model-spec.md` —— P7 威胁模型作答规范
- `2026-10-19-p8-tier2-deployment-spec.md` —— P8 Tier 2 部署与验证
