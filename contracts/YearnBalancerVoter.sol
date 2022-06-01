// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.6.12;
pragma experimental ABIEncoderV2;

import {
    SafeERC20,
    SafeMath,
    IERC20,
    Address
} from "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/math/Math.sol";

import {IVoteEscrow} from "../interfaces/Balancer/IVoteEscrow.sol";
import {
    IBalancerPool,
    IBalancerVault
} from "../interfaces/Balancer/BalancerV2.sol";

/**
 * @dev Where Yearn stores veBAL and boosted BPTs (balancer's LP tokens).
 */
contract YearnBalancerVoter {
    using SafeERC20 for IERC20;
    using Address for address;
    using SafeMath for uint256;

    IERC20 internal constant WETH =
        IERC20(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
    IERC20 internal constant BAL =
        IERC20(0xba100000625a3754423978a60c9317c58a424e3D);
    IERC20 internal constant balWethLP =
        IERC20(0x5c6Ee304399DBdB9C8Ef030aB642B10820DB8F56);
    IVoteEscrow internal constant veBAL =
        IVoteEscrow(0xC128a9954e6c874eA3d62ce62B468bA073093F25);

    address public governance;
    address public pendingGovernance;
    address public proxy;
    IBalancerVault internal constant balancerVault =
        IBalancerVault(0xBA12222222228d8Ba445958a75a0704d566BF2C8);
    IBalancerPool internal constant stakeLp =
        IBalancerPool(0xcdE5a11a4ACB4eE4c805352Cec57E236bdBC3837);
    address[] internal assets;

    modifier onlyProxyOrGovernance() {
        require(msg.sender == proxy || msg.sender == governance, "!authorized");
        _;
    }

    constructor() public {
        governance = msg.sender;
        assets = [address(BAL), address(WETH)];
    }

    function execute(
        address to,
        uint256 value,
        bytes calldata data
    ) external onlyProxyOrGovernance returns (bool, bytes memory) {
        (bool success, bytes memory result) = to.call{value: value}(data);

        return (success, result);
    }

    function getName() external pure returns (string memory) {
        return "YearnBalancerVoter";
    }

    function setProxy(address _proxy) external {
        require(msg.sender == governance, "!governance");
        proxy = _proxy;
    }

    function setGovernance(address _governance) external {
        require(msg.sender == governance, "!governance");
        pendingGovernance = _governance;
    }

    function acceptGovernance() external {
        require(msg.sender == pendingGovernance, "!pending_governance");
        governance = msg.sender;
        pendingGovernance = address(0);
    }

    // Controller only function for creating additional rewards from dust
    function withdraw(IERC20 _asset) external returns (uint256 balance) {
        require(msg.sender == proxy, "!controller");
        _asset.safeTransfer(proxy, _asset.balanceOf(address(this)));
    }

    function createLock(uint256 _value, uint256 _unlockTime)
        external
        onlyProxyOrGovernance
    {
        _checkAllowance(address(veBAL), balWethLP, _value);
        veBAL.create_lock(_value, _unlockTime);
    }

    function increaseAmountMax() external onlyProxyOrGovernance {
        uint256 _balanceOfBPT = balWethLP.balanceOf(address(this));
        _checkAllowance(address(veBAL), balWethLP, _balanceOfBPT);
        veBAL.increase_amount(_balanceOfBPT);
    }

    function increaseAmountExact(uint256 _amount)
        external
        onlyProxyOrGovernance
    {
        uint256 _balanceOfBPT = balWethLP.balanceOf(address(this));
        require(_amount <= _balanceOfBPT, "!too_much");
        _checkAllowance(address(veBAL), balWethLP, _amount);
        veBAL.increase_amount(_amount);
    }

    function release() external onlyProxyOrGovernance {
        veBAL.withdraw();
    }

    function convertBALIntoBPT(uint256 _amount) external onlyProxyOrGovernance {
        _convertBALIntoBPT(_amount);
    }

    function convertLooseBALIntoBPT() external onlyProxyOrGovernance {
        uint256 _balanceOfBal = BAL.balanceOf(address(this));
        if (_balanceOfBal > 0) {
            _convertBALIntoBPT(_balanceOfBal);
        }
    }

    function convertBPTIntoBAL(uint256 _amount) external onlyProxyOrGovernance {
        _convertBPTIntoBAL(_amount);
    }

    function convertLooseBPTIntoBAL() external onlyProxyOrGovernance {
        uint256 _balanceOfBpt = balWethLP.balanceOf(address(this));
        if (_balanceOfBpt > 0) {
            _convertBPTIntoBAL(_balanceOfBpt);
        }
    }

    // Converts BAL into the BAL/WETH BPT used for veBAL
    function _convertBALIntoBPT(uint256 _amount) internal {
        _checkAllowance(address(balancerVault), BAL, _amount);
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = _amount; // BAL
        bytes memory userData =
            abi.encode(
                IBalancerVault.JoinKind.EXACT_TOKENS_IN_FOR_BPT_OUT,
                amounts,
                0
            );
        IBalancerVault.JoinPoolRequest memory request =
            IBalancerVault.JoinPoolRequest(assets, amounts, userData, false);
        balancerVault.joinPool(
            IBalancerPool(address(balWethLP)).getPoolId(),
            address(this),
            address(this),
            request
        );
    }

    function _convertBPTIntoBAL(uint256 _amount) internal {
        _checkAllowance(address(balancerVault), balWethLP, _amount);
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = _amount;
        bytes memory userData =
            abi.encode(
                IBalancerVault.ExitKind.EXACT_BPT_IN_FOR_ONE_TOKEN_OUT,
                _amount,
                0
            );
        IBalancerVault.ExitPoolRequest memory request =
            IBalancerVault.ExitPoolRequest(assets, amounts, userData, false);
        balancerVault.exitPool(
            IBalancerPool(address(balWethLP)).getPoolId(),
            address(this),
            payable(address(this)),
            request
        );
    }

    // _checkAllowance adapted from https://github.com/therealmonoloco/liquity-stability-pool-strategy/blob/1fb0b00d24e0f5621f1e57def98c26900d551089/contracts/Strategy.sol#L316

    function _checkAllowance(
        address _spender,
        IERC20 _token,
        uint256 _amount
    ) internal {
        uint256 _currentAllowance = _token.allowance(address(this), _spender);
        if (_currentAllowance < _amount) {
            _token.safeIncreaseAllowance(_spender, _amount - _currentAllowance);
        }
    }
}
