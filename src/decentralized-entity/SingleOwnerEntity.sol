pragma solidity ^0.8.7;

import {ERC165CheckerUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/introspection/ERC165CheckerUpgradeable.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC1155Receiver} from "@openzeppelin/contracts/token/ERC1155/IERC1155Receiver.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

import {DecentralizedEntityInterface} from "@unleashed/opendapps-cloud-interfaces/decentralized-entity/DecentralizedEntityInterface.sol";

import {BaseGovernor_Owner} from "../governance/BaseGovernor_Owner.sol";
import {BaseGovernor} from "../governance/BaseGovernor.sol";
import {OwnershipNFTCollection} from "./../ownership/OwnershipNFTCollection.sol";

    error InterfaceNotSupportedError(address target, bytes4 interfaceId);

contract SingleOwnerEntity is DecentralizedEntityInterface, BaseGovernor_Owner, IERC721Receiver, IERC1155Receiver {
    //IERC721Receiver & IERC1155Receiver are to enable ownership of other entities

    string internal _name;
    address public ownershipCollection;
    uint256 public ownershipTokenId;

    constructor() {
        _disableInitializers(); //IMPORTANT - DO NOT REMOVE! Allows for cloneable pattern without template being initializeable
    }

    //INITIALIZER
    function initialize(string memory __name, address ownershipNftCollection, uint256 _ownershipTokenId) external initializer {
        if (!ERC165CheckerUpgradeable.supportsInterface(ownershipNftCollection, type(IERC721).interfaceId)) {
            revert InterfaceNotSupportedError(ownershipNftCollection, type(IERC721).interfaceId);
        }

        __BaseGovernor_Owner_init();
        _name = __name;
        ownershipCollection = ownershipNftCollection;
        ownershipTokenId = _ownershipTokenId;
    }

    //VIEW - PUBLIC - START
    function name() override external view returns (string memory) {
        return _name;
    }

    function memberOf(address wallet) override external view returns (bool) {
        return isOwner(wallet);
    }

    function owner() public override view returns (address) {
        return OwnershipNFTCollection(ownershipCollection).ownerOf(ownershipTokenId);
    }

    function metadataUrl() external view returns (string memory) {
        return OwnershipNFTCollection(ownershipCollection).tokenURI(ownershipTokenId);
    }

    function isOwner(address wallet) public view returns (bool) {
        return wallet == owner();
    }

    function supportsInterface(bytes4 interfaceId) public view virtual override(BaseGovernor, IERC165) returns (bool) {
        return type(DecentralizedEntityInterface).interfaceId == interfaceId
        || type(IERC165).interfaceId == interfaceId
            || BaseGovernor.supportsInterface(interfaceId);
    }
    //VIEW - PUBLIC - END

    //NFT EVENTS - PUBLIC - START
    /**
     * @dev See {IERC721Receiver-onERC721Received}.
     */
    function onERC721Received(
        address,
        address,
        uint256,
        bytes memory
    ) public virtual override returns (bytes4) {
        return this.onERC721Received.selector;
    }

    /**
     * @dev See {IERC1155Receiver-onERC1155Received}.
     */
    function onERC1155Received(
        address,
        address,
        uint256,
        uint256,
        bytes memory
    ) public virtual override returns (bytes4) {
        return this.onERC1155Received.selector;
    }

    /**
     * @dev See {IERC1155Receiver-onERC1155BatchReceived}.
     */
    function onERC1155BatchReceived(
        address,
        address,
        uint256[] memory,
        uint256[] memory,
        bytes memory
    ) public virtual override returns (bytes4) {
        return this.onERC1155BatchReceived.selector;
    }
    //NFT EVENTS - PUBLIC - END
} 