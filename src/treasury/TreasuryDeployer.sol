// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.7;

import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {SafeMath} from "@openzeppelin/contracts/utils/math/SafeMath.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {ERC165Checker} from "@openzeppelin/contracts/utils/introspection/ERC165Checker.sol";
import {ERC165} from "@openzeppelin/contracts/utils/introspection/ERC165.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IContractDeployerInterface} from "@unleashed/opendapps-cloud-interfaces/deployer/IContractDeployerInterface.sol";
import {ServiceDeployableInterface} from "@unleashed/opendapps-cloud-interfaces/deployer/ServiceDeployableInterface.sol";
import {SecondaryServiceDeployableInterface} from "@unleashed/opendapps-cloud-interfaces/deployer/SecondaryServiceDeployableInterface.sol";
import {TreasuryDeployerInterface} from "@unleashed/opendapps-cloud-interfaces/treasury/TreasuryDeployerInterface.sol";
import {TreasuryPocketInterface} from "@unleashed/opendapps-cloud-interfaces/treasury/TreasuryPocketInterface.sol";
import {TreasuryInterface} from "@unleashed/opendapps-cloud-interfaces/treasury/TreasuryInterface.sol";

import {ReferralsEngineInterface_v2} from "@unleashed/opendapps-cloud-interfaces/deployer/ReferralsEngineInterface_v2.sol";

    error TokenAlreadyHasStaking();
    error TokenHasNoStakingDeployed();
    error PermittedForOwnerOnly();
    error ProvidedAddressNotCompatibleWithRequiredInterfaces(address target, bytes4 interfaceId);
    error OnlyOwnerPermittedOperation(address sender);

contract TreasuryDeployer is TreasuryDeployerInterface, Initializable, ERC165, AccessControlUpgradeable {
    uint256[150] private __gap;

    event TreasuryDeployed(address indexed creator, address contractAddress);

    bytes32 public constant LOCAL_MANAGER_ROLE = keccak256("LOCAL_MANAGER_ROLE");

    bytes32 public constant GROUP_POCKET = keccak256("GROUP_POCKET");
    bytes32 public constant GROUP_TREASURY = keccak256("GROUP_TREASURY");

    uint256 public constant PERCENT_SCALING = 10 ** 3;

    address public contractDeployer;
    EnumerableSet.AddressSet private _operations;

    uint256 public serviceTax;

    using EnumerableSet for EnumerableSet.AddressSet;

    function initialize(
        address _contractDeployer, address treasuryLibrary,
        address pocketTemplate, uint256 _tax
    ) public initializer {
        if (!ERC165Checker.supportsInterface(_contractDeployer, type(IContractDeployerInterface).interfaceId)) {
            revert ProvidedAddressNotCompatibleWithRequiredInterfaces(_contractDeployer, type(IContractDeployerInterface).interfaceId);
        }

        super.__Context_init_unchained();
        super.__AccessControl_init_unchained();

        super._grantRole(DEFAULT_ADMIN_ROLE, msg.sender);

        contractDeployer = _contractDeployer;

        bytes4[] memory pocketInterfaces = new bytes4[](1);
        pocketInterfaces[0] = type(TreasuryPocketInterface).interfaceId;
        bytes4[] memory treasuryInterfaces = new bytes4[](1);
        treasuryInterfaces[0] = type(TreasuryInterface).interfaceId;

        IContractDeployerInterface(contractDeployer).registerTemplate(
            GROUP_POCKET, 0,
            pocketInterfaces, pocketTemplate, 0
        );
        IContractDeployerInterface(contractDeployer).registerTemplate(
            GROUP_TREASURY, 0,
            treasuryInterfaces, treasuryLibrary, _tax
        );
    }

    function supportsInterface(bytes4 interfaceId) public override(AccessControlUpgradeable, ERC165) view returns (bool) {
        return interfaceId == type(TreasuryDeployerInterface).interfaceId
        || AccessControlUpgradeable.supportsInterface(interfaceId)
            || ERC165.supportsInterface(interfaceId);
    }

    function operations() external view returns (address[] memory) {
        return _operations.values();
    }

    function isValidOperation(address operation) external view returns (bool) {
        return _operations.contains(operation);
    }

    // METHODS - MANAGER
    function enableOperation(address operation) external {
        _operations.add(operation);
    }

    function disableOperation(address operation) external {
        _operations.remove(operation);
    }

    function setPocketLibraryAddress(address _libraryAddress) external onlyRole(LOCAL_MANAGER_ROLE) {
        IContractDeployerInterface(contractDeployer).upgradeTemplate(
            GROUP_POCKET,
            0,
            _libraryAddress
        );
    }

    function refreshPocketLibraryInterfaces() external onlyRole(LOCAL_MANAGER_ROLE) {
        bytes4[] memory pocketInterfaces = new bytes4[](1);
        pocketInterfaces[0] = type(TreasuryPocketInterface).interfaceId;

        IContractDeployerInterface(contractDeployer).upgradeTemplateInterfaceList(GROUP_POCKET, 0, pocketInterfaces);
    }

    function setTreasuryLibraryAddress(address _libraryAddress) external onlyRole(LOCAL_MANAGER_ROLE) {
        IContractDeployerInterface(contractDeployer).upgradeTemplate(
            GROUP_TREASURY,
            0,
            _libraryAddress
        );
    }

    function refreshTreasuryLibraryInterfaces() external onlyRole(LOCAL_MANAGER_ROLE) {
        bytes4[] memory treasuryInterfaces = new bytes4[](1);
        treasuryInterfaces[0] = type(TreasuryInterface).interfaceId;

        IContractDeployerInterface(contractDeployer).upgradeTemplateInterfaceList(GROUP_TREASURY, 0, treasuryInterfaces);
    }


    function setServiceTax(uint256 tax) external onlyRole(LOCAL_MANAGER_ROLE) {
        serviceTax = tax;
    }

    function setDeployTax(uint256 taxSize) external onlyRole(LOCAL_MANAGER_ROLE) {
        IContractDeployerInterface(contractDeployer).upgradeDeployTax(
            GROUP_TREASURY,
            0,
            taxSize
        );
    }

    // METHODS - PUBLIC
    function deploy(bytes32 refCode) payable external returns (address) {
        address treasury = IContractDeployerInterface(contractDeployer)
            .deployTemplateWithProxy{value: msg.value}(
            msg.sender, GROUP_TREASURY, 0,
            bytes(""),
            refCode
        );

        (address[] memory receiverList, uint256[] memory receiverPercentList) = _buildServiceTaxationReceivers(refCode);

        Address.functionCall(
            treasury,
            abi.encodeWithSignature(
                "initialize(address,address,address,uint256,address[],uint256[])",
                address(this),
                IContractDeployerInterface(contractDeployer).currentTemplate(GROUP_POCKET, 0),
                msg.sender,
                PERCENT_SCALING,
                receiverList,
                receiverPercentList
            )
        );

        Ownable(treasury).transferOwnership(msg.sender);

        emit TreasuryDeployed(msg.sender, treasury);

        return treasury;
    }

    function upgrade(address treasury) payable external returns (address) {
        if (Ownable(treasury).owner() != msg.sender) {
            revert PermittedForOwnerOnly();
        }

        IContractDeployerInterface(contractDeployer).upgradeContractWithProxy(
            GROUP_TREASURY,
            treasury
        );

        return IContractDeployerInterface(contractDeployer).currentTemplate(GROUP_TREASURY, 0);
    }

    function _buildServiceTaxationReceivers(bytes32 refCode) internal view returns (address[] memory, uint256[] memory) {
        if (serviceTax <= 0) {
            return (new address[](0), new uint256[](0));
        }

        address referralEngine = IContractDeployerInterface(contractDeployer).referralsEngine();

        (uint256[] memory percents, address[] memory referrals) = ReferralsEngineInterface_v2(referralEngine).getTaxationReceivers(refCode, msg.sender);

        address[] memory receiverList = new address[](referrals.length);
        uint256[] memory receiverPercentList = new uint256[](referrals.length);

        uint256 total = 0;
        for (uint256 i = 0; i < referrals.length; i++) {
            receiverList[i] = referrals[i];
            receiverPercentList[i] = serviceTax * percents[i] / 100;
            total += receiverPercentList[i];

            if (total > serviceTax) {
                receiverPercentList[i] -= total - serviceTax;
            }
        }

        return (receiverList, receiverPercentList);
    }
}