pragma solidity ^0.8.7;

import {BaseGovernor} from "./BaseGovernor.sol";

    error OnlyOwnerPermitted(address expected, address actual);

abstract contract BaseGovernor_Owner is BaseGovernor {
    function __BaseGovernor_Owner_init() internal onlyInitializing {
        __BaseGovernor_init();
        __BaseGovernor_Owner_init_unchained();
    }

    function __BaseGovernor_Owner_init_unchained() internal onlyInitializing {
    }

    modifier onlyOwner(address wallet) {
        if (wallet != owner()) {
            revert OnlyOwnerPermitted(owner(), wallet);
        }
        _;
    }

    function requireProposal() external pure returns (bool) {
        return false;
    }

    function owner() public virtual view returns (address);

    function executeMethodCalls(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 descriptionHash
    ) public payable virtual override onlyOwner(msg.sender) returns (bytes[] memory) {
        return super._executeCallInternal(targets, values, calldatas, descriptionHash);
    }
}