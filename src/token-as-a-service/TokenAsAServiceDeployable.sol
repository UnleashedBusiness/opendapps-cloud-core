// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.7;


import {DeployableTemplateInterface} from "@unleashed/opendapps-cloud-interfaces/deployer/DeployableTemplateInterface.sol";
import {ERC165} from "@openzeppelin/contracts/utils/introspection/ERC165.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {TokenAsAService} from "./TokenAsAService.sol";

contract TokenAsAServiceDeployable is DeployableTemplateInterface, ERC165, Ownable {
    address private template;

    constructor(address taasDeployer) {
        _transferOwnership(taasDeployer);
        template = _deployInternal(true);
    }

    function deploy() public onlyOwner returns (address) {
        return _deployInternal(false);
    }

    function supportsInterface(bytes4 interfaceId) public view virtual override returns (bool) {
        return TokenAsAService(template).supportsInterface(interfaceId)
            || interfaceId == type(DeployableTemplateInterface).interfaceId;
    }

    function _deployInternal(bool isTemplate) internal returns (address) {
        return address(new TokenAsAService(isTemplate));
    }
}
