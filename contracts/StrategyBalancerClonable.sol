// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.6.12;
pragma experimental ABIEncoderV2;

import "@openzeppelin/contracts/math/Math.sol";
import {
    SafeERC20,
    SafeMath,
    IERC20,
    Address
} from "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import {IERC20Metadata} from "@yearnvaults/contracts/yToken.sol";

import {BaseStrategy} from "@yearnvaults/contracts/BaseStrategy.sol";
import {ITradeFactory} from "../interfaces/Yearn/ITradeFactory.sol";
import {BalancerStrategyVoterProxy} from "./BalancerStrategyVoterProxy.sol";
import {IGauge} from "../interfaces/Balancer/IGauge.sol";
import {
    IBalancerVault,
    IBalancerPool
} from "../interfaces/Balancer/BalancerV2.sol";
import {
    ILiquidityGaugeFactory
} from "../interfaces/Balancer/ILiquidityGaugeFactory.sol";

contract StrategyBalancerClonable is BaseStrategy {
    using SafeERC20 for IERC20;
    using Address for address;
    using SafeMath for uint256;

    BalancerStrategyVoterProxy public voterProxy;
    address public gauge; // Gauge that voter stakes in to recieve BAL rewards

    address public tradeFactory = address(0);

    uint256 public keepBAL; // the percentage of BAL that we re-lock for boost (in bips)
    uint256 public constant BIPS_DENOMINATOR = 10000; // 10k bips in 100%

    IERC20 internal constant BAL =
        IERC20(0xba100000625a3754423978a60c9317c58a424e3D);
    IERC20 internal constant WETH =
        IERC20(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
    ILiquidityGaugeFactory internal constant liquidityGaugeFactory =
        ILiquidityGaugeFactory(0x4E7bBd911cf1EFa442BC1b2e9Ea01ffE785412EC);

    IBalancerVault internal constant balancerVault =
        IBalancerVault(0xBA12222222228d8Ba445958a75a0704d566BF2C8);
    address[] public rewardTokens;

    bool internal forceHarvestTriggerOnce; // only set this to true externally when we want to trigger our keepers to harvest for us

    bool public isOriginal = true;
    event Cloned(address indexed clone);

    constructor(address _vault, address _voterProxy)
        public
        BaseStrategy(_vault)
    {
        _initializeStrategy(_voterProxy);
    }

    function initialize(
        address _vault,
        address _strategist,
        address _rewards,
        address _keeper,
        address _voterProxy
    ) external {
        _initialize(_vault, _strategist, _rewards, _keeper);
        _initializeStrategy(_voterProxy);
    }

    function _initializeStrategy(address _voterProxy) internal {
        voterProxy = BalancerStrategyVoterProxy(_voterProxy);

        want.safeApprove(address(_voterProxy), type(uint256).max);

        gauge = liquidityGaugeFactory.getPoolGauge(address(want));
        keepBAL = 1000;

        uint256 _numOfRewardTokens = IGauge(gauge).reward_count(); // FYI – technically, reward tokens can change dynamically, so we may need to re-clone a strategy
        for (uint256 i = 0; i < _numOfRewardTokens; i++) {
            rewardTokens.push(IGauge(gauge).reward_tokens(i));
        }
        healthCheck = 0xDDCea799fF1699e98EDF118e0629A974Df7DF012; // health.ychad.eth
    }

    function clone(
        address _vault,
        address _strategist,
        address _rewards,
        address _keeper,
        address _voterProxy
    ) external returns (address newStrategy) {
        require(isOriginal, "!clone");
        bytes20 addressBytes = bytes20(address(this));

        assembly {
            // EIP-1167 bytecode
            let clone_code := mload(0x40)
            mstore(
                clone_code,
                0x3d602d80600a3d3981f3363d3d373d3d3d363d73000000000000000000000000
            )
            mstore(add(clone_code, 0x14), addressBytes)
            mstore(
                add(clone_code, 0x28),
                0x5af43d82803e903d91602b57fd5bf30000000000000000000000000000000000
            )
            newStrategy := create(0, clone_code, 0x37)
        }

        StrategyBalancerClonable(newStrategy).initialize(
            _vault,
            _strategist,
            _rewards,
            _keeper,
            _voterProxy
        );

        emit Cloned(newStrategy);
    }

    function name() external view override returns (string memory) {
        return
            string(
                abi.encodePacked(
                    "StrategyBalancer",
                    IERC20Metadata(address(want)).symbol()
                )
            );
    }

    // We don't send rewards to new strategy in prepareMigration in case something is rekt, so migration can also include a manual claimRewards + sweep if needed
    function claimRewards() external onlyKeepers() {
        // Should be a harmless function, so 'onlyKeepers' is appropriate
        _claimRewards();
    }

    function setVoterProxy(address _voterProxy) external onlyGovernance {
        voterProxy = BalancerStrategyVoterProxy(_voterProxy);
    }

    // Set the amount of BAL to be locked in Yearn's veBAL voter from each harvest. Default is 10%.
    function setKeepBAL(uint256 _keepBAL) external onlyAuthorized {
        require(_keepBAL <= 10_000);
        keepBAL = _keepBAL;
    }

    // This allows us to manually harvest with our keeper as needed
    function setForceHarvestTriggerOnce(bool _forceHarvestTriggerOnce)
        external
        onlyAuthorized
    {
        forceHarvestTriggerOnce = _forceHarvestTriggerOnce;
    }

    function setTradeFactory(address _tradeFactory) external onlyGovernance {
        if (tradeFactory != address(0)) {
            _removeTradeFactoryPermissions();
        }

        ITradeFactory tf = ITradeFactory(_tradeFactory);

        BAL.safeApprove(_tradeFactory, type(uint256).max);
        tf.enable(address(BAL), address(want));

        for (uint256 i = 0; i < rewardTokens.length; i++) {
            address rewardToken = rewardTokens[i];
            IERC20(rewardToken).safeApprove(_tradeFactory, type(uint256).max);
            tf.enable(rewardToken, address(want));
        }
        tradeFactory = _tradeFactory;
    }

    function removeTradeFactoryPermissions() external onlyEmergencyAuthorized {
        _removeTradeFactoryPermissions();
    }

    function harvestTrigger(uint256 callCostinEth)
        public
        view
        override
        returns (bool)
    {
        // trigger if we want to manually harvest
        if (forceHarvestTriggerOnce) {
            return true;
        }

        // Should not trigger if strategy is not active (no assets and no debtRatio). This means we don't need to adjust keeper job.
        if (!isActive()) {
            return false;
        }

        return super.harvestTrigger(callCostinEth);
    }

    function _removeTradeFactoryPermissions() internal {
        BAL.safeApprove(tradeFactory, 0);
        for (uint256 i = 0; i < rewardTokens.length; i++) {
            IERC20(rewardTokens[i]).safeApprove(tradeFactory, 0);
        }
        tradeFactory = address(0);
    }

    function stakedBalance() public view returns (uint256) {
        return voterProxy.balanceOf(gauge);
    }

    function balanceOfWant() public view returns (uint256) {
        return want.balanceOf(address(this));
    }

    function estimatedTotalAssets() public view override returns (uint256) {
        return balanceOfWant().add(stakedBalance());
    }

    function ethToWant(uint256 _ethAmount)
        public
        view
        override
        returns (uint256)
    {}

    function adjustPosition(uint256 _debtOutstanding) internal override {
        if (emergencyExit) {
            return;
        }
        // Send all of our LP tokens to the proxy and deposit to the gauge if we have any
        uint256 _toInvest = balanceOfWant();
        if (_toInvest > 0) {
            want.safeTransfer(address(voterProxy), _toInvest);
            voterProxy.deposit(gauge, address(want));
        }

        _claimRewards();
    }

    function _claimRewards() internal {
        // Non-BAL rewards (e.g., LDO)
        if (rewardTokens.length > 0) {
            voterProxy.claimRewards(gauge);
        }

        // BAL rewards
        uint256 _stakedBalance = stakedBalance();
        if (_stakedBalance > 0) {
            uint256 _balanceOfBalBeforeClaim = BAL.balanceOf(address(this));
            voterProxy.claimBal(gauge);
            uint256 _balClaimed =
                BAL.balanceOf(address(this)).sub(_balanceOfBalBeforeClaim);

            if (_balClaimed > 0) {
                uint256 _sendToVoter =
                    _balClaimed.mul(keepBAL).div(BIPS_DENOMINATOR);

                if (_sendToVoter > 0) {
                    BAL.safeTransfer(address(voterProxy), _sendToVoter); // So that strategy doesn't need to know about voter, we send BAL via voter proxy
                    voterProxy.transferBALToVoter();
                }
            }
        }
    }

    function liquidatePosition(uint256 _amountNeeded)
        internal
        override
        returns (uint256 _liquidatedAmount, uint256 _loss)
    {
        uint256 _wantBalance = balanceOfWant();
        if (_amountNeeded > _wantBalance) {
            // check if we have enough free funds to cover the withdrawal
            uint256 _stakedBalance = stakedBalance();
            if (_stakedBalance > 0) {
                voterProxy.withdraw(
                    gauge,
                    address(want),
                    Math.min(_stakedBalance, _amountNeeded.sub(_wantBalance))
                );
            }
            uint256 _withdrawnBalance = balanceOfWant();
            _liquidatedAmount = Math.min(_amountNeeded, _withdrawnBalance);
            _loss = _amountNeeded.sub(_liquidatedAmount);
        } else {
            // we have enough balance to cover the liquidation available
            return (_amountNeeded, 0);
        }
    }

    // fire sale, get rid of it all!
    function liquidateAllPositions() internal override returns (uint256) {
        uint256 _stakedBalance = stakedBalance();
        if (_stakedBalance > 0) {
            // don't bother withdrawing zero
            voterProxy.withdraw(gauge, address(want), _stakedBalance);
        }
        return balanceOfWant();
    }

    function prepareReturn(uint256 _debtOutstanding)
        internal
        override
        returns (
            uint256 _profit,
            uint256 _loss,
            uint256 _debtPayment
        )
    {
        uint256 totalDebt = vault.strategies(address(this)).totalDebt;
        uint256 totalAssetsAfterProfit = estimatedTotalAssets();

        _profit = totalAssetsAfterProfit > totalDebt
            ? totalAssetsAfterProfit.sub(totalDebt)
            : 0;

        uint256 _amountFreed;
        uint256 _toLiquidate = _debtOutstanding.add(_profit);
        if (_toLiquidate > 0) {
            (_amountFreed, _loss) = liquidatePosition(_toLiquidate);
        }

        _debtPayment = Math.min(_debtOutstanding, _amountFreed);

        if (_loss > _profit) {
            // Example:
            // debtOutstanding 100, profit 50, _amountFreed 100, _loss 50
            // loss should be 0, (50-50)
            // profit should endup in 0
            _loss = _loss.sub(_profit);
            _profit = 0;
        } else {
            // Example:
            // debtOutstanding 100, profit 50, _amountFreed 140, _loss 10
            // _profit should be 40, (50 profit - 10 loss)
            // loss should end up in 0
            _profit = _profit.sub(_loss);
            _loss = 0;
        }

        // we're done harvesting, so reset our trigger if we used it
        forceHarvestTriggerOnce = false;
    }

    function prepareMigration(address _newStrategy) internal override {
        uint256 _stakedBalance = stakedBalance();
        if (_stakedBalance > 0) {
            voterProxy.withdraw(gauge, address(want), _stakedBalance);
        }
    }

    function protectedTokens()
        internal
        view
        override
        returns (address[] memory)
    {}
}
