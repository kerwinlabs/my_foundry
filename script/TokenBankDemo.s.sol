// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {console} from "forge-std/Script.sol";

import "./BaseScript.s.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {CalledToken} from "../src/CalledToken.sol";
import {TokenBank} from "../src/TokenBank.sol";

/// @notice TokenBank 独立 demo 的部署脚本：只部署 CalledToken + TokenBank，
///         不依赖 NFTMarket / MyERC721。
///         部署者（PRIVATE_KEY 对应地址）会获得 1,000,000 MTK 初始供应量，
///         可以直接用于 approve + deposit，或通过 transferAndCall 存款。
/// 用法（需要环境变量 PRIVATE_KEY）:
///   PRIVATE_KEY=$PRIVATE_KEY \
///     forge script script/TokenBankDemo.s.sol:TokenBankDemoScript \
///     --rpc-url http://127.0.0.1:8545 --broadcast
contract TokenBankDemoScript is BaseScript {
    CalledToken public token;
    TokenBank public bank;

    function run() public broadcaster {
        // 1. 部署 CalledToken：1,000,000 MTK 全部铸造给部署者。
        token = new CalledToken("Bank Token", "MTK", 1_000_000 * 10 ** 18);
        console.log("CalledToken deployed on %s", address(token));

        // 2. 部署 TokenBank，绑定上面的代币。
        bank = new TokenBank(IERC20(address(token)));
        console.log("TokenBank deployed on %s", address(bank));
        console.log("");
        console.log("Next: put these into default_workspace/back_scripts/.env:");
        console.log("TOKEN_ADDRESS=%s", address(token));
        console.log("BANK_ADDRESS=%s", address(bank));
        console.log("INDEX_FROM_BLOCK=0");

        // 3. 保存地址，供脚本 / 前端 / 索引服务复用。
        saveContract("CalledToken", address(token));
        saveContract("TokenBank", address(bank));
    }
}
