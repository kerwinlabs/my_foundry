// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AdminTokenBank} from "../src/AdminTokenBank.sol";

/// @title DepositToAdminTokenBankScript
/// @notice 用持有 SafeBankToken 的账户完成 approve + deposit 两步操作。
///
/// @dev 执行账户必须是持有 Token 的账户（例如脚本部署时收到 10,000 SBT 的两个地址），
///      并且需要少量 Sepolia ETH 支付 gas。
///
/// 用法：
///   DEPOSIT_AMOUNT=1000 \
///   forge script script/DepositToAdminTokenBank.s.sol:DepositToAdminTokenBankScript \
///     --rpc-url sepolia --broadcast --keystore keystore/<持币账户>
///
/// 环境变量：
///   DEPOSIT_AMOUNT  存入数量，单位“枚”，默认 1000，按 Token decimals 换算
contract DepositToAdminTokenBankScript is Script {
    using SafeERC20 for IERC20;

    uint256 internal constant SEPOLIA_CHAIN_ID = 11155111;

    /// @notice 已部署的 AdminTokenBank 地址（Sepolia）。
    address internal constant ADMIN_TOKEN_BANK = 0x4a7baB7BCd787b1FD528855215AA060aaB7fA603;

    function run() external {
        require(block.chainid == SEPOLIA_CHAIN_ID, "this script must run on Sepolia");

        address bankAddress = ADMIN_TOKEN_BANK;
        uint256 depositTokens = vm.envOr("DEPOSIT_AMOUNT", uint256(1000));

        require(bankAddress.code.length > 0, "ADMIN_TOKEN_BANK has no contract code");

        AdminTokenBank bank = AdminTokenBank(bankAddress);

        // Token 地址直接取 Bank 绑定的 immutable token，避免填错。
        address tokenAddress = address(bank.token());
        require(tokenAddress.code.length > 0, "bank.token() has no contract code");

        IERC20 token = IERC20(tokenAddress);

        uint8 decimals = IERC20Metadata(tokenAddress).decimals();
        uint256 amount = depositTokens * (10 ** uint256(decimals));

        // 脚本中的 msg.sender 就是 --keystore / --private-key 对应的执行账户。
        address depositor = msg.sender;
        uint256 balance = token.balanceOf(depositor);
        require(balance >= amount, "insufficient token balance");

        console.log("chainId        : %s", block.chainid);
        console.log("depositor      : %s", depositor);
        console.log("token          : %s", tokenAddress);
        console.log("bank           : %s", bankAddress);
        console.log("decimals       : %s", uint256(decimals));
        console.log("deposit amount : %s (raw units)", amount);
        console.log("token balance  : %s (raw units)", balance);

        vm.startBroadcast();

        // 第 1 步：授权 Bank 拉取 amount 数量的 Token。
        token.forceApprove(bankAddress, amount);

        // 第 2 步：Bank 通过 safeTransferFrom 把 Token 转入自己。
        bank.deposit(amount);

        vm.stopBroadcast();

        console.log("");
        console.log("Deposit finished.");
        console.log("depositor token balance : %s", token.balanceOf(depositor));
        console.log("depositor deposit       : %s", bank.getDeposit(depositor));
        console.log("bank token balance      : %s", token.balanceOf(bankAddress));
    }
}
