// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeBankToken} from "../src/SafeBankToken.sol";
import {AdminTokenBank} from "../src/AdminTokenBank.sol";

/// @title AdminTokenBankSepoliaScript
/// @notice 多签实战部署脚本：
///         1. 部署一个全新的 SafeBankToken（与之前的 MyERC20 完全独立）；
///         2. 部署时直接把初始 Token 铸造给两个测试账户；
///         3. 部署 AdminTokenBank，并把 admin 设置为 Safe 多签地址。
///
/// @dev 不修改 src/TokenBank.sol；AdminTokenBank 是独立的带管理员版本。
///      本脚本只负责部署。withdraw() 由用户在 app.safe.global 上手动发起，
///      此时 Safe 合约调用 Bank，msg.sender 就是 Safe，满足 onlyAdmin。
///
/// 用法（支持 --private-key 或 --keystore / --account）：
///   forge script script/AdminTokenBankSepolia.s.sol:AdminTokenBankSepoliaScript \
///     --rpc-url sepolia --broadcast --verify
///
/// 可选环境变量：
///   SAFE_ADDRESS       覆盖默认多签地址
contract AdminTokenBankSepoliaScript is Script {
    /// @notice 本次实战使用的 Safe 多签地址（Sepolia）。
    address internal constant DEFAULT_SAFE = 0xF057f12404818356cBa3a53c246099aD99547bE9;

    /// @notice 接收初始 Token 的两个测试账户。
    address internal constant ACCOUNT_1 = 0xb88De52E7A06a1bbEBb365d3E275E442F57A33cC;
    address internal constant ACCOUNT_2 = 0xedF10093516Bf8E15a130701668386ab4EBEf0D5;

    /// @notice 每个测试账户铸造 10,000 枚 Token（18 位精度）。
    uint256 internal constant MINT_PER_ACCOUNT = 10_000 * 10 ** 18;

    uint256 internal constant SEPOLIA_CHAIN_ID = 11155111;

    IERC20 public token;
    AdminTokenBank public bank;

    function run() public returns (IERC20 deployedToken, AdminTokenBank deployedBank) {
        require(block.chainid == SEPOLIA_CHAIN_ID, "this script must run on Sepolia");

        address safe = vm.envOr("SAFE_ADDRESS", DEFAULT_SAFE);
        require(safe.code.length > 0, "SAFE_ADDRESS is not a contract on this chain");

        address[] memory recipients = new address[](2);
        uint256[] memory amounts = new uint256[](2);
        recipients[0] = ACCOUNT_1;
        recipients[1] = ACCOUNT_2;
        amounts[0] = MINT_PER_ACCOUNT;
        amounts[1] = MINT_PER_ACCOUNT;

        vm.startBroadcast();

        // 全新 Token，不复用之前的 MyERC20 地址。
        SafeBankToken newToken = new SafeBankToken("SafeBankToken", "SBT", recipients, amounts);
        token = IERC20(address(newToken));

        bank = new AdminTokenBank(token, safe);

        vm.stopBroadcast();

        require(bank.admin() == safe, "bank admin is not Safe");
        require(token.balanceOf(ACCOUNT_1) == MINT_PER_ACCOUNT, "account 1 mint failed");
        require(token.balanceOf(ACCOUNT_2) == MINT_PER_ACCOUNT, "account 2 mint failed");

        console.log("");
        console.log("=== SafeBankToken + AdminTokenBank deployed ===");
        console.log("chainId       : %s", block.chainid);
        console.log("Safe multisig : %s", safe);
        console.log("SafeBankToken : %s", address(newToken));
        console.log("AdminTokenBank: %s", address(bank));
        console.log("bank.admin()  : %s", bank.admin());
        console.log("");
        console.log("Minted 10,000 SBT to each account:");
        console.log("  account 1   : %s", ACCOUNT_1);
        console.log("  account 2   : %s", ACCOUNT_2);

        // 使用新的文件名保存，不覆盖之前实战的部署记录。
        _saveContract("SafeBankToken", address(newToken));
        _saveContract("AdminTokenBank_SafeExercise", address(bank));

        console.log("");
        console.log("=== Safe withdraw (manual) ===");
        console.log("Open https://app.safe.global for Safe %s", safe);
        console.log("New transaction -> Contract interaction");
        console.log("To    : %s", address(bank));
        console.log("Value : 0");
        console.log("Data  : 0x3ccfd60b (withdraw())");

        deployedToken = token;
        deployedBank = bank;
    }

    /// @dev 把合约地址写入 deployments/<name>_<chainId>.json。
    function _saveContract(string memory name, address addr) internal {
        string memory finalJson = vm.serializeAddress("key", "address", addr);
        vm.writeJson(
            finalJson,
            string.concat("deployments/", name, "_", vm.toString(block.chainid), ".json")
        );
    }
}
