// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.7;

import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {ERC165CheckerUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/introspection/ERC165CheckerUpgradeable.sol";

import {DecentralizedEntityDeployerInterface} from "@unleashed/opendapps-cloud-interfaces/decentralized-entity/DecentralizedEntityDeployerInterface.sol";
import {DecentralizedEntityInterface} from "@unleashed/opendapps-cloud-interfaces/decentralized-entity/DecentralizedEntityInterface.sol";
import {GovernorInterface} from "@unleashed/opendapps-cloud-interfaces/governance/GovernorInterface.sol";
import {IContractDeployerInterface} from "@unleashed/opendapps-cloud-interfaces/deployer/IContractDeployerInterface.sol";
import {ITokenRewardsTreasury} from "@unleashed/opendapps-cloud-interfaces/treasury/ITokenRewardsTreasury.sol";

import {OwnershipNFTCollection} from "../ownership/OwnershipNFTCollection.sol";
import {OwnershipSharesNFTCollection} from "../ownership/OwnershipSharesNFTCollection.sol";

    error ProvidedAddressNotCompatibleWithRequiredInterfaces(address target, bytes4 interfaceId);

contract DecentralizedEntityDeployer is DecentralizedEntityDeployerInterface, Initializable, AccessControlUpgradeable {
    uint256[150] private __gap;

    enum EntityType {
        SingleOwner,
        MultiSign,
        MultiSignShares
    }

    enum RewardsTreasuryType {
        ShareBasedTreasury
    }

    event DecentralizedEntityDeployed(address indexed creator, uint8 indexed typeId, address contractAddress, address treasury);

    bytes32 public constant LOCAL_MANAGER_ROLE = keccak256("LOCAL_MANAGER_ROLE");

    bytes32 public constant GROUP_DECENTRALIZED_ENTITY = keccak256("GROUP_DECENTRALIZED_ENTITY");
    bytes32 public constant GROUP_REWARDS_TREASURY = keccak256("GROUP_REWARDS_TREASURY");

    bytes4[] private REQUIRED_ENTITY_INTERFACES;
    bytes4[] private REQUIRED_REWARDS_TREASURY_INTERFACES;

    address public contractDeployer;
    address public singleOwnerNFTOwnershipContract;
    address public sharesEntityNftOwnershipContract;

    function initialize(
        address _contractDeployer,
        address singleOwnerLibrary, address multiSignLibrary,
        address multiSignSharesLibrary, address rewardsTreasuryLibrary,
        address _singleOwnerNFTOwnershipContract, address _sharesEntityNftOwnershipContract
    ) public initializer {
        if (!ERC165CheckerUpgradeable.supportsInterface(_contractDeployer, type(IContractDeployerInterface).interfaceId)) {
            revert ProvidedAddressNotCompatibleWithRequiredInterfaces(_contractDeployer, type(IContractDeployerInterface).interfaceId);
        }

        super.__Context_init_unchained();
        super.__ERC165_init_unchained();
        super.__AccessControl_init_unchained();

        super._grantRole(DEFAULT_ADMIN_ROLE, msg.sender);

        REQUIRED_ENTITY_INTERFACES = [type(DecentralizedEntityInterface).interfaceId, type(GovernorInterface).interfaceId];
        REQUIRED_REWARDS_TREASURY_INTERFACES = [type(ITokenRewardsTreasury).interfaceId];

        contractDeployer = _contractDeployer;
        singleOwnerNFTOwnershipContract = _singleOwnerNFTOwnershipContract;
        sharesEntityNftOwnershipContract = _sharesEntityNftOwnershipContract;

        IContractDeployerInterface(contractDeployer).registerTemplate(
            GROUP_DECENTRALIZED_ENTITY, uint8(EntityType.SingleOwner),
            REQUIRED_ENTITY_INTERFACES, singleOwnerLibrary, 0
        );
        IContractDeployerInterface(contractDeployer).registerTemplate(
            GROUP_DECENTRALIZED_ENTITY, uint8(EntityType.MultiSign),
            REQUIRED_ENTITY_INTERFACES, multiSignLibrary, 0
        );
        IContractDeployerInterface(contractDeployer).registerTemplate(
            GROUP_DECENTRALIZED_ENTITY, uint8(EntityType.MultiSignShares),
            REQUIRED_ENTITY_INTERFACES, multiSignSharesLibrary, 0
        );
        IContractDeployerInterface(contractDeployer).registerTemplate(
            GROUP_REWARDS_TREASURY, uint8(RewardsTreasuryType.ShareBasedTreasury),
            REQUIRED_REWARDS_TREASURY_INTERFACES, rewardsTreasuryLibrary, 0
        );
    }

    function setRewardsTreasuryLibraryAddress(address _libraryAddress) external onlyRole(LOCAL_MANAGER_ROLE) {
        IContractDeployerInterface(contractDeployer).upgradeTemplate(
            GROUP_REWARDS_TREASURY,
            uint8(RewardsTreasuryType.ShareBasedTreasury),
            _libraryAddress
        );
    }

    function deploySingleOwnerEntity(string calldata entityName, string calldata metadataUrl) external returns (EntityDeployment memory) {
        uint256 ownerTokenID = OwnershipNFTCollection(singleOwnerNFTOwnershipContract).nextTokenId();
        OwnershipNFTCollection(singleOwnerNFTOwnershipContract).mint(msg.sender, metadataUrl);

        address companyAddr = IContractDeployerInterface(contractDeployer).deployTemplate(
            msg.sender, GROUP_DECENTRALIZED_ENTITY, uint8(EntityType.SingleOwner),
            abi.encodeWithSignature(
                "initialize(string,address,uint256)",
                entityName,
                singleOwnerNFTOwnershipContract,
                ownerTokenID
            ),
            0x0
        );
        address treasuryAddress = _deployTreasury(msg.sender, companyAddr);

        emit DecentralizedEntityDeployed(msg.sender, uint8(EntityType.SingleOwner), companyAddr, treasuryAddress);
        return EntityDeployment(companyAddr, treasuryAddress);
    }

    function deployMultiSignEntity(string calldata entityName, uint256 votingBlocksLength, string calldata metadataUrl) external returns (EntityDeployment memory) {
        address[] memory t = new address[](1);
        t[0] = msg.sender;

        address companyAddr = IContractDeployerInterface(contractDeployer).deployTemplate(
            msg.sender, GROUP_DECENTRALIZED_ENTITY, uint8(EntityType.MultiSign),
            abi.encodeWithSignature(
                "initialize(string,string,uint256,uint256,uint256,address[],address[])",
                entityName,
                metadataUrl,
                100,
                50,
                votingBlocksLength,
                t,
                new address[](0)
            ),
            0x0
        );
        address treasuryAddress = _deployTreasury(msg.sender, companyAddr);
        emit DecentralizedEntityDeployed(msg.sender, uint8(EntityType.MultiSign), companyAddr, treasuryAddress);

        return EntityDeployment(companyAddr, treasuryAddress);
    }

    function deployMultiSignSharesEntity(string calldata entityName, uint256 votingBlocksLength, string calldata metadataUrl) external returns (EntityDeployment memory) {
        uint256 ownerTokenID = OwnershipSharesNFTCollection(sharesEntityNftOwnershipContract).nextTokenId();
        OwnershipSharesNFTCollection(sharesEntityNftOwnershipContract).mint(msg.sender, metadataUrl);

        address companyAddr = IContractDeployerInterface(contractDeployer).deployTemplate(
            msg.sender, GROUP_DECENTRALIZED_ENTITY, uint8(EntityType.MultiSignShares),
            abi.encodeWithSignature(
                "initialize(string,uint256,address,uint256)",
                entityName, votingBlocksLength,
                sharesEntityNftOwnershipContract, ownerTokenID
            ),
            0x0
        );
        address treasuryAddress = _deployTreasury(msg.sender, companyAddr);

        emit DecentralizedEntityDeployed(msg.sender, uint8(EntityType.MultiSignShares), companyAddr, treasuryAddress);
        return EntityDeployment(companyAddr, treasuryAddress);
    }

    function upgradeTreasury(address treasury) payable external {
        IContractDeployerInterface(contractDeployer).upgradeContractWithProxy(
            GROUP_REWARDS_TREASURY,
            treasury
        );
    }

    function _deployTreasury(address owner, address companyAddr) internal returns (address) {
        address rewardsTreasury = IContractDeployerInterface(contractDeployer).deployTemplateWithProxy(
            owner, GROUP_REWARDS_TREASURY, uint8(RewardsTreasuryType.ShareBasedTreasury),
            abi.encodeWithSignature(
                "initialize(address)",
                companyAddr
            ),
            0x0
        );

        OwnableUpgradeable(rewardsTreasury).transferOwnership(companyAddr);

        return rewardsTreasury;
    }
}