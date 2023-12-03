// SPDX-License-Identifier: proprietary
pragma solidity ^0.8.7;

import {TokenRewardsTreasury} from "../../src/treasury/TokenRewardsTreasury.sol";

contract TokenRewardsTreasury_UNSAFE_FOR_TESTING is TokenRewardsTreasury {
    constructor() {}

    receive() payable override external {
        addToAvailable(address(0));
    }

    function send() payable external {
        addToAvailable(address(0));
    }

    function _disableInitializers() internal override {
        //UNSAFE REMOVEL TO ALLOW DIRECT TESTING! DO NOT USE IN PRODUCTION!!!!!!!
    }
}