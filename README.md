## Foundry

**Foundry is a blazing fast, portable and modular toolkit for Ethereum application development written in Rust.**

Foundry consists of:

- **Forge**: Ethereum testing framework (like Truffle, Hardhat and DappTools).
- **Cast**: Swiss army knife for interacting with EVM smart contracts, sending transactions and getting chain data.
- **Anvil**: Local Ethereum node, akin to Ganache, Hardhat Network.
- **Chisel**: Fast, utilitarian, and verbose solidity REPL.

## Documentation

https://book.getfoundry.sh/

## Usage

### Build

```shell
$ forge build
```

### Test

```shell
$ forge test
```

### Format

```shell
$ forge fmt
```

### Gas Snapshots

```shell
$ forge snapshot
```

### Anvil

```shell
$ anvil
```

### Deploy

```shell
$ forge script script/Counter.s.sol:CounterScript --rpc-url <your_rpc_url> --private-key <your_private_key>
```

### Cast

```shell
$ cast <subcommand>
```

### Help

```shell
$ forge --help
$ anvil --help
$ cast --help
```

## AdminTokenBank + Safe 多签实战

本实战与之前的 MyERC20 实战完全独立，使用全新的 Token：

- `src/SafeBankToken.sol`：本次专用的 ERC20，部署时把初始 Token 直接铸造给
  `0xb88De52E7A06a1bbEBb365d3E275E442F57A33cC` 和
  `0xedF10093516Bf8E15a130701668386ab4EBEf0D5`，每人 10,000 枚；
- `src/AdminTokenBank.sol`：独立的带管理员 ERC20 Bank，**不修改** `src/TokenBank.sol`：
  - 管理员在构造时直接设置为 Safe 多签地址；
  - 用户通过 `approve` + `deposit` 存入 SafeBankToken；
  - 只有管理员可以调用 `withdraw()`，把 Bank 中的全部 Token 转给管理员（Safe）；
  - Safe 执行交易时，`msg.sender` 就是 Safe 合约，因此 `onlyAdmin` 会通过。

部署脚本：`script/AdminTokenBankSepolia.s.sol`。

```bash
cd forge_project

PRIVATE_KEY=<部署私钥> \
  forge script script/AdminTokenBankSepolia.s.sol:AdminTokenBankSepoliaScript \
  --rpc-url sepolia --broadcast --verify

# 使用 keystore / account 时也可以（脚本内部使用 startBroadcast()）：
forge script script/AdminTokenBankSepolia.s.sol:AdminTokenBankSepoliaScript \
  --keystore keystore/sepolia-test --rpc-url sepolia --broadcast
```

可选环境变量：

| 变量 | 说明 |
| --- | --- |
| `SAFE_ADDRESS` | 覆盖默认多签地址 `0xF057f12404818356cBa3a53c246099aD99547bE9` |

脚本只负责部署，每次都会部署新的 SafeBankToken，完成后会：

1. 输出 SafeBankToken / AdminTokenBank 地址，并确认 `bank.admin()` 是多签地址；
2. 写入 `deployments/SafeBankToken_11155111.json` 和
   `deployments/AdminTokenBank_SafeExercise_11155111.json`，不覆盖之前实战的
   `MyERC20_11155111.json` / `AdminTokenBank_11155111.json`；
3. 打印手动发起 withdraw 所需的参数。

### 先存入 Token（approve + deposit）

Bank 里没有 Token 时 `withdraw()` 会 revert `NoFunds()`，所以先执行：

```bash
cd forge_project

DEPOSIT_AMOUNT=1000 \
  forge script script/DepositToAdminTokenBank.s.sol:DepositToAdminTokenBankScript \
  --keystore keystore/<持币账户> --rpc-url sepolia --broadcast
```

- Bank 地址已写死在脚本中：
  `0x4a7baB7BCd787b1FD528855215AA060aaB7fA603`；
- Token 地址从 `bank.token()` 读取，不需要单独配置；
- 执行账户必须是持有 SafeBankToken 的地址（即部署时收到 10,000 SBT 的两个账户之一）；
- 该账户还需要少量 Sepolia ETH 付 gas；
- `DEPOSIT_AMOUNT` 单位是“枚”，默认 1000；
- 脚本内部依次执行 `token.forceApprove(bank, amount)` 和 `bank.deposit(amount)`，
  并打印存入前后的余额、`bank.getDeposit()` 和 Bank 的 Token 余额。

### 从 Safe 发起 withdraw

1. 先完成上面的 `approve` + `deposit`，否则 Bank 余额为 0，
   `withdraw()` 会 revert `NoFunds()`；
2. 打开 https://app.safe.global/ ，用管理员 owner 连接并进入该 Safe（Sepolia）；
3. New transaction → Contract interaction，填写：
   - To：部署输出的 `AdminTokenBank` 地址；
   - Value：`0`；
   - Data：`0x3ccfd60b`（`withdraw()` 的 selector，以脚本输出为准）；
4. 提交交易，收集达到阈值的签名并执行；
5. Safe 执行时调用 Bank 的 `withdraw()`，Token 会转入 Safe 地址。
