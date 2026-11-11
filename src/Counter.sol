// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;
import {console} from "forge-std/Console.sol";

contract Counter {
    uint256 public number1;
    function setNumber(uint256 newNumber) public {
        number1 = newNumber;
        console.log("[Counter setNumber] number1:", number1);
    }
    function increment() public {
        number1++;
        console.log("[Counter increment] number1:", number1);
    }
    function addNumber(uint256 number) public {
        number1 = number1 + number;
        console.log("[Counter addNumber] number1:", number1, "number:", number);
    }
}
