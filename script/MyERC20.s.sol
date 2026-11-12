// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {console} from "forge-std/Script.sol";

import "./BaseScript.s.sol";
import {MyERC20} from "../src/MyERC20.sol";

contract MyERC20Script is BaseScript {
    MyERC20 public token;

    function run() public broadcaster {
        token = new MyERC20("MyToken", "MTK");
        console.log("MyERC20 deployed on %s", address(token));

        // 保存合约地址到本地
        saveContract("MyERC20", address(token));

        // 给指定地址初始化 1000 个代币（全部供应量由构造函数铸给部署者）
        address to = 0x70997970C51812dc3A010C7d01b50e0d17dc79C8;
        // 1 个代币 = 10^decimals 个最小单位（MTK 的 decimals 为 18，即 unit = 10^18）
        uint256 unit = 10 ** uint256(token.decimals());
        // 实际转账数量 = 1000 * 10^18（以最小单位计），即 1000 个 MTK
        uint256 initAmount = 1000 * unit;
        token.transfer(to, initAmount);
        // 日志打印的是人类可读数量（1000），链上实际值是 initAmount = 1000 * 10^18
        console.log("Transferred %s MTK to %s", initAmount / unit, to);
    }
}
