// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {IERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import {SafeMathUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/math/SafeMathUpgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {AddressUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/AddressUpgradeable.sol";
import {ERC165CheckerUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/introspection/ERC165CheckerUpgradeable.sol";
import {ERC165Upgradeable} from "@openzeppelin/contracts-upgradeable/utils/introspection/ERC165Upgradeable.sol";
import {EnumerableSetUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/structs/EnumerableSetUpgradeable.sol";

import {IContractDeployerInterface} from "@unleashed/opendapps-cloud-interfaces/deployer/IContractDeployerInterface.sol";
import {AssetBackingInterface} from "@unleashed/opendapps-cloud-interfaces/asset-backing/AssetBackingInterface.sol";
import {BaselineInsuranceDeployerInterface} from "@unleashed/opendapps-cloud-interfaces/asset-backing/BaselineInsuranceDeployerInterface.sol";
import {SmartSwapPriceModelInterface} from "@unleashed/opendapps-cloud-interfaces/asset-backing/SmartSwapPriceModelInterface.sol";

    error ProvidedAddressNotCompatibleWithRequiredInterfaces();
    error TokenAlreadyHasBacking();

contract BaselineInsuranceServiceDeployer is Initializable, BaselineInsuranceDeployerInterface, ERC165Upgradeable, AccessControlUpgradeable {
    uint256[150] private __gap;

    event BaselineInsuranceServiceDeployed(address indexed creator, address indexed token, address contractAddress);

    bytes32 public constant LOCAL_MANAGER_ROLE = keccak256("LOCAL_MANAGER_ROLE");
    bytes32 public constant GROUP_ASSET_BACKING = keccak256("AseetBacking");
    bytes32 public constant GROUP_ASSET_BACKING_SWAP_MODEL = keccak256("AseetBackingSwapModel");
    uint256 public constant DEFAULT_SIMPLE_MODEL_MULTIPLIER = 1;

    address public contractDeployer;
    uint256 public defaultThreshold = 0.001 ether;
    uint256 public defaultBlocksDistance = 10;

    using SafeMathUpgradeable for uint256;
    using AddressUpgradeable for address;

    function initialize(
        address _contractDeployer, address assetBackingLibrary,
        address _simpleMultiplierModelLibrary, address _tanXModelLibrary,
        uint256 _tax
    ) public initializer {
        if (!ERC165CheckerUpgradeable.supportsInterface(_contractDeployer, type(IContractDeployerInterface).interfaceId)) {
            revert ProvidedAddressNotCompatibleWithRequiredInterfaces();
        }

        super.__Context_init_unchained();
        super.__ERC165_init_unchained();
        super.__AccessControl_init_unchained();

        super._grantRole(DEFAULT_ADMIN_ROLE, msg.sender);

        contractDeployer = _contractDeployer;

        bytes4[] memory backingInterfaces = new bytes4[](1);
        backingInterfaces[0] = type(AssetBackingInterface).interfaceId;

        IContractDeployerInterface(contractDeployer).registerTemplate(
            GROUP_ASSET_BACKING, 0,
            backingInterfaces, assetBackingLibrary, _tax
        );

        bytes4[] memory modelInterfaces = new bytes4[](1);
        modelInterfaces[0] = type(SmartSwapPriceModelInterface).interfaceId;

        IContractDeployerInterface(contractDeployer).registerTemplate(
            GROUP_ASSET_BACKING_SWAP_MODEL, 0,
            modelInterfaces, _simpleMultiplierModelLibrary, 0
        );
        IContractDeployerInterface(contractDeployer).registerTemplate(
            GROUP_ASSET_BACKING_SWAP_MODEL, 1,
            modelInterfaces, _tanXModelLibrary, 0
        );

    }

    function supportsInterface(bytes4 interfaceId) public override(AccessControlUpgradeable, ERC165Upgradeable) view returns (bool) {
        return interfaceId == type(BaselineInsuranceDeployerInterface).interfaceId
        || AccessControlUpgradeable.supportsInterface(interfaceId)
            || ERC165Upgradeable.supportsInterface(interfaceId);
    }

    // METHODS - MANAGER
    function setBackingLibraryAddress(address _libraryAddress) external onlyRole(LOCAL_MANAGER_ROLE) {
        IContractDeployerInterface(contractDeployer).upgradeTemplate(
            GROUP_ASSET_BACKING,
            0,
            _libraryAddress
        );
    }

    function setDeployTax(uint256 taxSize) external onlyRole(LOCAL_MANAGER_ROLE) {
        IContractDeployerInterface(contractDeployer).upgradeDeployTax(
            GROUP_ASSET_BACKING,
            0,
            taxSize
        );
    }

    // METHODS - PUBLIC
    function deploySimpleModel(address erc20Token, address backingToken, bytes32 refCode) payable external returns (address) {
        if (!ERC165CheckerUpgradeable.supportsInterface(erc20Token, type(IERC20Upgradeable).interfaceId)) {
            revert ProvidedAddressNotCompatibleWithRequiredInterfaces();
        }

        address model = IContractDeployerInterface(contractDeployer).deployTemplate(
            msg.sender, GROUP_ASSET_BACKING_SWAP_MODEL, 0,
            abi.encodeWithSignature(
                "initialize(uint256)",
                DEFAULT_SIMPLE_MODEL_MULTIPLIER
            ),
            refCode
        );

        address backing = IContractDeployerInterface(contractDeployer).deployTemplate{value: msg.value}(
            msg.sender, GROUP_ASSET_BACKING, 0,
            bytes(""),
            refCode
        );
        AddressUpgradeable.functionCall(
            backing,
            abi.encodeWithSignature(
                "initialize(address,address,address,address,uint256,uint256)",
                msg.sender, backingToken, erc20Token,
                model, defaultThreshold, defaultBlocksDistance
            )
        );
        emit BaselineInsuranceServiceDeployed(msg.sender, erc20Token, backing);
        return backing;
    }

    // METHODS - PUBLIC
    function deployTanXModel(address erc20Token, address backingToken, bytes32 refCode) payable external returns (address) {
        if (!ERC165CheckerUpgradeable.supportsInterface(erc20Token, type(IERC20Upgradeable).interfaceId)) {
            revert ProvidedAddressNotCompatibleWithRequiredInterfaces();
        }

        address model = IContractDeployerInterface(contractDeployer).deployTemplate(
            msg.sender, GROUP_ASSET_BACKING_SWAP_MODEL, 1,
            abi.encodeWithSignature(
                "initialize(uint256)",
                DEFAULT_SIMPLE_MODEL_MULTIPLIER
            ),
            refCode
        );

        address backing = IContractDeployerInterface(contractDeployer).deployTemplate{value: msg.value}(
            msg.sender, GROUP_ASSET_BACKING, 0,
            bytes(""),
            refCode
        );
        AddressUpgradeable.functionCall(
            backing,
            abi.encodeWithSignature(
                "initialize(address,address,address,address,uint256,uint256)",
                msg.sender, backingToken, erc20Token,
                model, defaultThreshold, defaultBlocksDistance
            )
        );
        emit BaselineInsuranceServiceDeployed(msg.sender, erc20Token, backing);
        return backing;
    }


}
