// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.7;

import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

import {SafeMath} from "@openzeppelin/contracts/utils/math/SafeMath.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC165Checker} from "@openzeppelin/contracts/utils/introspection/ERC165Checker.sol";
import {ERC165} from "@openzeppelin/contracts/utils/introspection/ERC165.sol";

import {IContractDeployerInterface} from "@unleashed/opendapps-cloud-interfaces/deployer/IContractDeployerInterface.sol";
import {PresaleServiceDeployerInterface} from "@unleashed/opendapps-cloud-interfaces/presale/PresaleServiceDeployerInterface.sol";
import {PresaleServiceInterface} from "@unleashed/opendapps-cloud-interfaces/presale/PresaleServiceInterface.sol";
import {ServiceDeployableInterface} from "@unleashed/opendapps-cloud-interfaces/deployer/ServiceDeployableInterface.sol";
import {SecondaryServiceDeployableInterface} from "@unleashed/opendapps-cloud-interfaces/deployer/SecondaryServiceDeployableInterface.sol";

    error ProvidedAddressNotCompatibleWithRequiredInterfaces(address target, bytes4 interfaceId);
    error RouterNotPartOfWhitelist(address router);
    error RouterAlreadyPartOfWhitelist(address router);
    error TotalSupplyBelowAllowedValues(uint256 min, uint256 actual);
    error OwnerShareGreaterThanAllowed(uint256 max, uint256 actual);
    error InitialSupplyExceedsAllowedValues(uint256 min, uint256 max, uint256 actual);
    error SenderDoesNotHaveEnoughFunds(uint256 expected, uint256 actual);
    error TokenAllowanceIsLessThenRequestedTransfer(uint256 expected, uint256 actual);
    error OnlyOwnerPermittedOperation(address actual);
    error ETHLessThanRequiredMinimumLiquidity(uint256 expected, uint256 actual);

contract PresaleServiceDeployer is PresaleServiceDeployerInterface, Initializable, ERC165, AccessControlUpgradeable {
    uint256[50] private __gap;

    enum PresaleType {
        Basic
    }

    event PresaleDeployed(address indexed creator, uint8 indexed typeId, address indexed token, address contractAddress);

    bytes32 public constant LOCAL_MANAGER_ROLE = keccak256("LOCAL_MANAGER_ROLE");

    bytes32 public constant GROUP_PRESALE = keccak256("Presale");

    uint256 public constant DEFAULT_MIN_BLOCKS_TILL_START = 21600; //~24 hours on DMC
    uint256 public constant DEFAULT_MIN_BLOCKS_DURATION = 21600; //~24 hours on DMC

    address public contractDeployer;
    address public rewardsTreasury;

    uint256 public minBlocksForStart;
    uint256 public minBlocksDuration;
    uint256 public presaleControllerDefaultTax;

    using SafeMath for uint256;
    using Address for address;

    receive() external payable {}

    modifier __requireSecondaryServicePermission(address service, address expectedOwner) {
        if (ERC165Checker.supportsInterface(service, type(SecondaryServiceDeployableInterface).interfaceId)) {
            address masterDeployable = SecondaryServiceDeployableInterface(service).masterDeployable();
            if (!ServiceDeployableInterface(masterDeployable).canAccessFromDeployer(msg.sender) || (expectedOwner != address(0) && expectedOwner != msg.sender)) {
                revert OnlyOwnerPermittedOperation(msg.sender);
            }
        }
        _;
    }

    function initialize(
        address _contractDeployer, address _rewardsTreasury, address presaleLibrary,
        uint256 _tax, uint256 _minBlocksForStart, uint256 _minBlocksDuration, uint256 _presaleControllerDefaultTax
    ) public initializer {
        if (!ERC165Checker.supportsInterface(_contractDeployer, type(IContractDeployerInterface).interfaceId)) {
            revert ProvidedAddressNotCompatibleWithRequiredInterfaces(_contractDeployer, type(IContractDeployerInterface).interfaceId);
        }

        super.__Context_init_unchained();
        super.__AccessControl_init_unchained();

        super._grantRole(DEFAULT_ADMIN_ROLE, msg.sender);

        contractDeployer = _contractDeployer;
        rewardsTreasury = _rewardsTreasury;
        minBlocksForStart = _minBlocksForStart;
        minBlocksDuration = _minBlocksDuration;
        presaleControllerDefaultTax = _presaleControllerDefaultTax;

        bytes4[] memory presaleInterfaces = new bytes4[](2);
        presaleInterfaces[0] = type(PresaleServiceInterface).interfaceId;
        presaleInterfaces[1] = type(SecondaryServiceDeployableInterface).interfaceId;

        IContractDeployerInterface(contractDeployer).registerTemplate(GROUP_PRESALE, uint8(PresaleType.Basic), presaleInterfaces, presaleLibrary, _tax);
    }

    function supportsInterface(bytes4 interfaceId) public override(AccessControlUpgradeable, ERC165) view returns (bool) {
        return interfaceId == type(PresaleServiceDeployerInterface).interfaceId
        || AccessControlUpgradeable.supportsInterface(interfaceId)
            || ERC165.supportsInterface(interfaceId);
    }

    // METHODS - MANAGER
    function setPresaleLibrary(address _library) external onlyRole(LOCAL_MANAGER_ROLE) {
        IContractDeployerInterface(contractDeployer).upgradeTemplate(GROUP_PRESALE, uint8(PresaleType.Basic), _library);
    }

    function setPresaleDeployTax(uint256 taxSize) external onlyRole(LOCAL_MANAGER_ROLE) {
        IContractDeployerInterface(contractDeployer).upgradeDeployTax(GROUP_PRESALE, uint8(PresaleType.Basic), taxSize);
    }

    function setMinBlocksForStart(uint256 blocks) external onlyRole(LOCAL_MANAGER_ROLE) {
        minBlocksForStart = blocks;
    }

    function setMinBlocksDuration(uint256 blocks) external onlyRole(LOCAL_MANAGER_ROLE) {
        minBlocksDuration = blocks;
    }

    function setTokenTreasuryAddress(address _treasury) external onlyRole(LOCAL_MANAGER_ROLE) {
        rewardsTreasury = _treasury;
    }

    // METHODS - PUBLIC
    function deploy(address token, address exchangeToken, bytes32 refCode) payable external returns (address)
    {
        address deployment = IContractDeployerInterface(contractDeployer).deployTemplateWithProxy{value: msg.value}(
            msg.sender, GROUP_PRESALE, uint8(PresaleType.Basic), bytes(''), refCode
        );

        Address.functionCall(
            deployment,
            abi.encodeWithSignature(
                "initialize(address,address,uint256,uint256,address,uint256)",
                token, exchangeToken, minBlocksForStart, minBlocksDuration, rewardsTreasury, presaleControllerDefaultTax
            )
        );
        if (!ERC165Checker.supportsInterface(token, type(ServiceDeployableInterface).interfaceId)) {
            Ownable(deployment).transferOwnership(msg.sender);
        }

        emit PresaleDeployed(msg.sender, uint8(PresaleType.Basic), token, deployment);
        return deployment;
    }

    function upgrade(address presale) external __requireSecondaryServicePermission(presale, address(0)) {
        IContractDeployerInterface(contractDeployer).upgradeContractWithProxy(
            GROUP_PRESALE,
            presale
        );
    }
}