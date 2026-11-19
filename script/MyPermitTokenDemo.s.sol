// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {console} from "forge-std/Script.sol";

import "./BaseScript.s.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MyPermitToken} from "../src/MyPermitToken.sol";
import {TokenBank} from "../src/TokenBank.sol";

/// @notice EIP-2612 demo 的部署脚本：部署 MyPermitToken（CalledToken + ERC20Permit）
///         和绑定它的 TokenBank，不依赖 NFTMarket / MyERC721。
///         部署者（PRIVATE_KEY 对应地址）获得 1,000,000 PBT 初始供应量。
///
///         部署完成后可以用三种方式存款：
///         1. 传统方式：token.approve(bank, amount) + bank.deposit(amount)；
///         2. transferAndCall：token.transferAndCall(bank, amount, "")；
///         3. 离线授权：owner 签名 Permit（spender = bank 地址），
///            任意地址调用 bank.permitDeposit(owner, amount, deadline, v, r, s)。
///
/// 用法（需要环境变量 PRIVATE_KEY）:
///   PRIVATE_KEY=$PRIVATE_KEY \
///     forge script script/MyPermitTokenDemo.s.sol:MyPermitTokenDemoScript \
///     --rpc-url http://127.0.0.1:8545 --broadcast
contract MyPermitTokenDemoScript is BaseScript {
    string internal constant TOKEN_NAME = "Permit Bank Token";
    string internal constant TOKEN_SYMBOL = "PBT";
    uint256 internal constant INITIAL_SUPPLY = 1_000_000 * 10 ** 18;

    MyPermitToken public token;
    TokenBank public bank;

    function run() public broadcaster {
        // 1. 部署 MyPermitToken：1,000,000 PBT 全部铸造给部署者，
        //    EIP-712 domain 的 name 使用同一个 TOKEN_NAME、version 为 "1"。
        token = new MyPermitToken(TOKEN_NAME, TOKEN_SYMBOL, INITIAL_SUPPLY);
        console.log("MyPermitToken deployed on %s", address(token));

        // 2. 部署 TokenBank，绑定上面的代币。
        bank = new TokenBank(IERC20(address(token)));
        console.log("TokenBank deployed on %s", address(bank));
        console.log("");
        console.log("Next: put these into default_workspace/back_scripts/.env:");
        console.log("TOKEN_ADDRESS=%s", address(token));
        console.log("BANK_ADDRESS=%s", address(bank));
        console.log("INDEX_FROM_BLOCK=0");
        console.log("");
        console.log("Permit signing domain:");
        console.log("  name              : %s", TOKEN_NAME);
        console.log("  version           : 1");
        console.log("  chainId           : %s", block.chainid);
        console.log("  verifyingContract : %s", address(token));
        console.log("Permit struct: Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");
        console.log("spender must be the TokenBank address above.");

        // 3. 保存地址，供脚本 / 前端 / 索引服务复用。
        //    使用不同文件名，避免覆盖之前 TokenBankDemo 保存的 TokenBank 记录。
        saveContract("MyPermitToken", address(token));
        saveContract("TokenBank_PermitDemo", address(bank));
    }
}
