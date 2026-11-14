// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {console} from "forge-std/Script.sol";

import "./BaseScript.s.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {TokenBank} from "../src/TokenBank.sol";

/// @notice 部署 TokenBank，并绑定已部署的 ERC20 代币（例如 CalledToken）。
///         代币地址优先读环境变量 TOKEN_ADDRESS；没有的话读取
///         deployments/CalledToken_<chainId>.json 里保存的地址。
///         若使用 CalledToken，approve + deposit 和 transferAndCall 两种存款方式都支持。
/// 用法（需要环境变量 PRIVATE_KEY）:
///   TOKEN_ADDRESS=$TOKEN_ADDRESS PRIVATE_KEY=$PRIVATE_KEY \
///     forge script script/TokenBank.s.sol:TokenBankScript \
///     --rpc-url $RPC_URL --broadcast
// contract TokenBankScript is BaseScript {
//     TokenBank public bank;

//     function run() public broadcaster {
//         address tokenAddress = vm.envOr("TOKEN_ADDRESS", address(0));

//         // 没显式指定时，复用 NFTMarket 脚本保存的 CalledToken 地址。
//         if (tokenAddress == address(0)) {
//             string memory path = string.concat(
//                 "deployments/CalledToken_",
//                 vm.toString(block.chainid),
//                 ".json"
//             );
//             tokenAddress = vm.parseJsonAddress(vm.readFile(path), ".address");
//         }

//         require(tokenAddress != address(0), "TOKEN_ADDRESS is zero");
//         require(tokenAddress.code.length > 0, "TOKEN_ADDRESS has no contract code");

//         bank = new TokenBank(IERC20(tokenAddress));
//         console.log("TokenBank deployed on %s", address(bank));
//         console.log("bound token       : %s", tokenAddress);
//         console.log("");
//         console.log("Next: put this into default_workspace/back_scripts/.env:");
//         console.log("BANK_ADDRESS=%s", address(bank));

//         saveContract("TokenBank", address(bank));
//     }
// }
