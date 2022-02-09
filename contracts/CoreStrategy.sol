// SPDX-License-Identifier: AGPL-3.0
// Feel free to change the license, but this is what we use

// Feel free to change this version of Solidity. We support >=0.6.0 <0.7.0;
pragma solidity ^0.6.12;
pragma experimental ABIEncoderV2;

// These are the core Yearn libraries
import {
    BaseStrategy,
    StrategyParams
} from "@yearnvaults/contracts/BaseStrategy.sol";
import {
    SafeERC20,
    SafeMath,
    IERC20,
    Address
} from "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/math/Math.sol";
import "./interfaces/tarot.sol";
import "./interfaces/uniswap.sol";

import "./interfaces/ctoken.sol";
import "./interfaces/farm.sol";
import "./interfaces/uniswap.sol";
import "./interfaces/ipriceoracle.sol";
import {IStrategyInsurance} from "./StrategyInsurance.sol";

struct CoreStrategyConfig {
    // A portion of want token is depoisited into a lending platform to be used as
    // collateral. Short token is borrowed and compined with the remaining want token
    // and deposited into LP and farmed.
    address want;
    address shortA;
    address shortB;
    /*****************************/
    /*             Farm           */
    /*****************************/
    // Liquidity pool address for base <-> short tokens
    address wantShortALP;
    address shortAshortBLP;
    // Address for farming reward token - eg Spirit/BOO
    address farmToken;
    // Liquidity pool address for farmToken <-> wFTM
    address farmTokenLP;
    // Farm address for reward farming
    address farmMasterChef;
    // farm PID for base <-> short LP farm
    uint256 farmPid;
    /*****************************/
    /*        Money Market       */
    /*****************************/
    // Base token cToken @ MM
    address cTokenLend;
    // Short token cToken @ MM
    address cTokenBorrowA;
    address cTokenBorrowB;
    // Lend/Borrow rewards
    address compToken;
    address compTokenLP;
    // address compLpAddress = 0x613BF4E46b4817015c01c6Bb31C7ae9edAadc26e;
    address comptroller;
    /*****************************/
    /*            AMM            */
    /*****************************/
    // Liquidity pool address for base <-> short tokens @ the AMM.
    // @note: the AMM router address does not need to be the same
    // AMM as the farm, in fact the most liquid AMM is prefered to
    // minimise slippage.
    address router;
    uint256 minDeploy;
}

interface IERC20Extended is IERC20 {
    function decimals() external view returns (uint8);
}

abstract contract CoreStrategy is BaseStrategy {
    using SafeERC20 for IERC20;
    using Address for address;
    using SafeMath for uint256;

    event DebtRebalance(
        uint256 debtRatio,
        uint256 swapAmount,
        uint256 slippage
    );
    event CollatRebalance(uint256 collatRatio, uint256 adjAmount);

    // uint256 public stratLendAllocation;
    // uint256 public stratDebtAllocation;
    uint256 public collatUpper = 5500;
    uint256 public collatTarget = 5000;
    uint256 public collatLower = 4500;
    uint256 public debtUpper = 10200;
    uint256 public debtLower = 9800;
    uint256 public rebalancePercent = 10000; // 100% (how far does rebalance of debt move towards 100% from threshold)

    // protocal limits & upper, target and lower thresholds for ratio of debt to collateral
    uint256 public collatLimit = 7500;

    // ERC20 Tokens;
    IERC20 public shortA;
    IERC20 public shortB;

    IUniswapV2Pair wantShortALP; // This is public because it helps with unit testing
    IUniswapV2Pair wantShortBLP; // This is public because it helps with unit testing
    IUniswapV2Pair shortAshortBLP; // This is public because it helps with unit testing

    IERC20 farmTokenLP;
    IERC20 farmToken;
    IERC20 compToken;

    // Contract Interfaces
    ICTokenErc20 cTokenLend;
    ICTokenErc20 cTokenBorrowA;
    ICTokenErc20 cTokenBorrowB;

    IFarmMasterChef farm;
    IUniswapV2Router01 router;
    IComptroller comptroller;
    IPriceOracle oracleA;
    IPriceOracle oracleB;

    uint256 public slippageAdj = 9000; // 90%
    uint256 public slippageAdjHigh = 10100; // 101%
    /// HACK for harvest logic
    uint256 public pendingFarmRewards = 10000;

    uint256 constant BASIS_PRECISION = 10000;
    uint256 constant STD_PRECISION = 1e18;
    uint256 farmPid;
    address weth;
    uint256 public minDeploy;

    constructor(address _vault, CoreStrategyConfig memory _config)
        public
        BaseStrategy(_vault)
    {
        // config = _config;
        farmPid = _config.farmPid;

        router = IUniswapV2Router01(_config.router);
        weth = router.WETH();

        // initialise token interfaces
        shortA = IERC20(_config.shortA);
        shortB = IERC20(_config.shortB);

        // we make sure shortA is WFTM as this makes pricing simpler
        // require(address(shortA) == weth);

        wantShortALP = IUniswapV2Pair(_config.wantShortALP);
        shortAshortBLP = IUniswapV2Pair(_config.shortAshortBLP);

        farmTokenLP = IERC20(_config.farmTokenLP);
        farmToken = IERC20(_config.farmToken);
        compToken = IERC20(_config.compToken);

        // initialise other interfaces
        cTokenLend = ICTokenErc20(_config.cTokenLend);
        cTokenBorrowA = ICTokenErc20(_config.cTokenBorrowA);
        cTokenBorrowB = ICTokenErc20(_config.cTokenBorrowB);

        farm = IFarmMasterChef(_config.farmMasterChef);
        comptroller = IComptroller(_config.comptroller);

        enterMarket();
        // _updateLendAndDebtAllocation();

        maxReportDelay = 7200;
        minReportDelay = 3600;
        profitFactor = 1500;
        debtThreshold = 1_000_000 * 1e18;
        minDeploy = _config.minDeploy;
    }

    // function _updateLendAndDebtAllocation() internal {
    //     stratLendAllocation = BASIS_PRECISION.mul(BASIS_PRECISION).div(
    //         BASIS_PRECISION.add(collatTarget)
    //     );
    //     stratDebtAllocation = BASIS_PRECISION.sub(stratLendAllocation);
    // }

    function name() external view override returns (string memory) {
        return "StrategyHedgedFarming";
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
        if (canHarvest()) {
            _harvestInternal();
        }

        uint256 totalAssets = estimatedTotalAssets();
        uint256 totalDebt = _getTotalDebt();
        if (totalAssets > totalDebt) {
            _profit = totalAssets.sub(totalDebt);
            (uint256 amountFreed, ) = _withdraw(_debtOutstanding.add(_profit));
            if (_debtOutstanding > amountFreed) {
                _debtPayment = amountFreed;
                _profit = 0;
            } else {
                _debtPayment = _debtOutstanding;
                _profit = amountFreed.sub(_debtOutstanding);
            }
            _loss = 0;
        } else {
            _withdraw(_debtOutstanding);
            _debtPayment = balanceOfWant();
            _loss = totalDebt.sub(totalAssets);
        }
    }

    function returnDebtOutstanding(uint256 _debtOutstanding)
        public
        returns (uint256 _debtPayment, uint256 _loss)
    {
        // We might need to return want to the vault
        if (_debtOutstanding > 0) {
            uint256 _amountFreed = 0;
            (_amountFreed, _loss) = liquidatePosition(_debtOutstanding);
            _debtPayment = Math.min(_amountFreed, _debtOutstanding);
        }
    }

    function adjustPosition(uint256 _debtOutstanding) internal override {
        uint256 _wantAvailable = balanceOfWant();
        if (_debtOutstanding >= _wantAvailable) {
            return;
        }
        uint256 toInvest = _wantAvailable.sub(_debtOutstanding);
        if (toInvest > 0) {
            _deploy(toInvest);
        }
    }

    function prepareMigration(address _newStrategy) internal override {
        liquidateAllPositionsInternal();
    }

    function ethToWant(uint256 _amtInWei)
        public
        view
        virtual
        override
        returns (uint256)
    {
        // This is not currently used by the strategies and is
        // being removed to reduce the size of the contract
        return 0;
    }

    function getTokenOutPath(address _token_in, address _token_out)
        internal
        view
        returns (address[] memory _path)
    {
        bool is_weth =
            _token_in == address(weth) || _token_out == address(weth);
        _path = new address[](is_weth ? 2 : 3);
        _path[0] = _token_in;
        if (is_weth) {
            _path[1] = _token_out;
        } else {
            _path[1] = address(weth);
            _path[2] = _token_out;
        }
    }

    function approveContracts() external virtual onlyGovernance {
        want.safeApprove(address(cTokenLend), uint256(-1));
        shortA.safeApprove(address(cTokenBorrowA), uint256(-1));
        shortB.safeApprove(address(cTokenBorrowB), uint256(-1));

        //want.safeApprove(address(router), uint256(-1));
        shortA.safeApprove(address(router), uint256(-1));
        shortB.safeApprove(address(router), uint256(-1));

        farmToken.safeApprove(address(router), uint256(-1));
        compToken.safeApprove(address(router), uint256(-1));
        IERC20(address(shortAshortBLP)).safeApprove(
            address(router),
            uint256(-1)
        );
        IERC20(address(shortAshortBLP)).safeApprove(address(farm), uint256(-1));
    }

    function resetApprovals() external virtual onlyGovernance {
        want.safeApprove(address(cTokenLend), uint256(0));
        shortA.safeApprove(address(cTokenBorrowA), uint256(0));
        shortB.safeApprove(address(cTokenBorrowB), uint256(0));

        //want.safeApprove(address(router), uint256(-1));
        shortA.safeApprove(address(router), uint256(0));
        shortB.safeApprove(address(router), uint256(0));

        farmToken.safeApprove(address(router), uint256(0));
        compToken.safeApprove(address(router), uint256(0));
        IERC20(address(shortAshortBLP)).safeApprove(
            address(router),
            uint256(0)
        );
        IERC20(address(shortAshortBLP)).safeApprove(address(farm), uint256(0));
    }

    function setSlippageAdj(uint256 _lower, uint256 _upper)
        external
        onlyAuthorized
    {
        slippageAdj = _lower;
        slippageAdjHigh = _upper;
    }

    /*
    function migrateInsurance(address _newInsurance) external onlyGovernance {
        require(address(_newInsurance) == address(0));
        insurance.migrateInsurance(_newInsurance);
        insurance = IStrategyInsurance(_newInsurance);
    }
    */

    function setDebtThresholds(
        uint256 _lower,
        uint256 _upper,
        uint256 _rebalancePercent
    ) external onlyAuthorized {
        require(_lower <= BASIS_PRECISION);
        require(_rebalancePercent <= BASIS_PRECISION);
        require(_upper >= BASIS_PRECISION);
        rebalancePercent = _rebalancePercent;
        debtUpper = _upper;
        debtLower = _lower;
    }

    function setCollateralThresholds(
        uint256 _lower,
        uint256 _target,
        uint256 _upper,
        uint256 _limit
    ) external onlyAuthorized {
        require(_limit <= BASIS_PRECISION);
        collatLimit = _limit;
        require(collatLimit > _upper);
        require(_upper >= _target);
        require(_target >= _lower);
        collatUpper = _upper;
        collatTarget = _target;
        collatLower = _lower;
        // _updateLendAndDebtAllocation();
    }

    function liquidatePositionAuth(uint256 _amount) external onlyAuthorized {
        liquidatePosition(_amount);
    }

    function liquidateAllToLend() internal {
        _withdrawAllPooled();
        _removeAllLp();
        _repayDebtA();
        _repayDebtB();
    }

    function liquidateAllPositions()
        internal
        override
        returns (uint256 _amountFreed)
    {
        (_amountFreed, ) = liquidateAllPositionsInternal();
    }

    function liquidateAllPositionsInternal()
        internal
        returns (uint256 _amountFreed, uint256 _loss)
    {
        _withdrawAllPooled();
        _removeAllLp();
        _repayDebtA();
        _repayDebtB();

        uint256 debtInShortA = balanceDebtInShortACurrent();
        uint256 debtInShortB = balanceDebtInShortBCurrent();

        uint256 balShortA = balanceShortA();
        uint256 balShortB = balanceShortB();

        // TO DO ADD LOGIC TO REPAY REMAINING DEBTS + CONVERT EXCESS SHORT A & SHORT B to WANT

        _redeemWant(balanceLend());
        _amountFreed = balanceOfWant();
    }

    /// rebalances RoboVault strat position to within target collateral range
    function rebalanceCollateral() external onlyKeepers {
        // ratio of amount borrowed to collateral
        require(
            calcCollateral() <= collatLower || calcCollateral() >= collatUpper
        );
        _rebalanceCollateralInternal();
    }

    /// rebalances RoboVault holding of short token vs LP to within target collateral range
    function rebalanceDebt() external onlyKeepers {
        require(calcDebtRatioA() > debtUpper || calcDebtRatioB() > debtUpper);
        _rebalanceDebtInternal();
    }

    function claimHarvest() internal virtual {
        farm.withdraw(farmPid, 0); /// for spooky swap call withdraw with amt = 0
    }

    // TO DO SET SOME RULES ON WHEN TO CALL _harvestInternal
    function canHarvest() internal view returns (bool) {
        return (estimatedTotalAssets() > _getTotalDebt() ||
            _farmPendingRewards(farmPid, address(this)).add(
                farmToken.balanceOf(address(this))
            ) >
            pendingFarmRewards);
    }

    /// called by keeper to harvest rewards and either repay debt
    function _harvestInternal() internal returns (uint256 _wantHarvested) {
        uint256 wantBefore = balanceOfWant();
        /// harvest from farm & wantd on amt borrowed vs LP value either -> repay some debt or add to collateral
        claimHarvest();
        comptroller.claimComp(address(this));
        uint256 maxDebt = Math.max(calcDebtRatioA(), calcDebtRatioB());

        // decide which token to sell rewards to
        address sellToken = address(want);
        if (maxDebt > BASIS_PRECISION) {
            if (calcDebtRatioA() > calcDebtRatioB()) {
                sellToken = address(shortA);
            } else {
                sellToken = address(shortB);
            }
        }
        _sellHarvest(sellToken);
        _sellComp(sellToken);
        _repayDebtA();
        _repayDebtB();
        _wantHarvested = balanceOfWant().sub(wantBefore);
    }

    // if debt ratio debtLower for both short A & short B convert some of the trading fees to want to get closer to hedged position
    function sellTradingFees() external onlyKeepers {
        uint256 debtA = calcDebtRatioA();
        uint256 debtB = calcDebtRatioB();

        if (debtA < debtLower && debtB < debtLower) {
            uint256 lpPercentRemove =
                BASIS_PRECISION.sub(Math.max(debtA, debtB));
            _removeLpPercent(lpPercentRemove);
            _swapExactShortRebalance(
                address(shortA),
                address(want),
                balanceShortA()
            );
            _swapExactShortRebalance(
                address(shortB),
                address(want),
                balanceShortB()
            );
        }
    }

    /**
     * Checks if collateral cap is reached or if deploying `_amount` will make it reach the cap
     * returns true if the cap is reached
     */

    function collateralCapReached(uint256 _amount)
        public
        view
        virtual
        returns (bool)
    {
        return
            cTokenLend.totalCollateralTokens().add(_amount) <
            cTokenLend.collateralCap();
    }

    function _rebalanceCollateralInternal() internal {
        uint256 collatRatio = calcCollateral();
        uint256 shortPos = balanceDebt();
        uint256 lendPos = balanceLend();

        if (collatRatio > collatTarget) {
            uint256 percentRemoved =
                (collatRatio.sub(collatTarget)).mul(BASIS_PRECISION).div(
                    collatRatio
                );
            _removeLpPercent(percentRemoved);
            _repayDebtA();
            _repayDebtB();
            //emit CollatRebalance(collatRatio, percentRemoved);
        } else if (collatRatio < collatTarget) {
            uint256 percentAdded =
                (collatTarget.sub(collatRatio)).mul(BASIS_PRECISION).div(
                    collatRatio
                );
            _borrowA(
                balanceShortAinLP().mul(percentAdded).div(BASIS_PRECISION)
            );
            _borrowB(
                balanceShortBinLP().mul(percentAdded).div(BASIS_PRECISION)
            );
            _addToLP();
            _depoistLp();
            //emit CollatRebalance(collatRatio, adjAmount);
        }
    }

    // deploy assets according to vault strategy
    function _deploy(uint256 _amount) internal {
        /*
        TO DO ADJUST COLLATERAL CAP REACHED LOGIC
        if (_amount < minDeploy || collateralCapReached(_amount)) {
            return;
        }
        */
        uint256 borrowAmtA =
            _amount
                .mul(collatTarget)
                .div(BASIS_PRECISION)
                .mul(1e18)
                .div(oracleA.getPrice())
                .div(2);
        uint256 borrowAmtB =
            borrowAmtA.mul(shortB.balanceOf(address(shortAshortBLP))).div(
                shortA.balanceOf(address(shortAshortBLP))
            );
        _lendWant(_amount);
        _borrowA(borrowAmtA);
        _borrowB(borrowAmtB);

        _addToLP();
        _depoistLp();
        // we repay in case any minor slippage due to decimal dif in borrow calcs
        /*
        _repayDebtA();
        _repayDebtB();
        */
    }

    function _deployFromLend(uint256 _amount) internal {
        uint256 collatAdj = collatTarget.sub(calcCollateral());

        uint256 borrowAmtA =
            _amount
                .mul(collatAdj)
                .div(BASIS_PRECISION)
                .mul(1e18)
                .div(oracleA.getPrice())
                .div(2);
        uint256 borrowAmtB =
            borrowAmtA.mul(shortB.balanceOf(address(shortAshortBLP))).div(
                shortA.balanceOf(address(shortAshortBLP))
            );

        _borrowA(borrowAmtA);
        _borrowB(borrowAmtB);
        _addToLP();
        _depoistLp();
    }

    function _rebalanceDebtInternal() internal {
        uint256 swapPercent;
        uint256 swapAmt;
        uint256 debtRatioA = calcDebtRatioA();
        uint256 debtRatioB = calcDebtRatioB();

        // Liquidate all the lend, leaving some in debt or as short
        liquidateAllToLend();

        uint256 debtInShortA = balanceDebtInShortA();
        uint256 balShortA = balanceShortA();

        uint256 debtInShortB = balanceDebtInShortB();
        uint256 balShortB = balanceShortB();

        /* 
        Technically it's possible for both debtratioA & debtratioB to > debtUpper 
        i.e. if borrow debt from borrowing exceeded trading fees + adjustments in debt ratio from IL 
        however to avoid this potential issue on harvests if both debt Ratios are > 100% convert farming rewards 
        to token with highest debt Ratio 
        */

        if (debtRatioA > debtUpper) {
            // If there's excess debt in shortA, we swap some of ShortB to repay a portion of the debt

            swapPercent = rebalancePercent;
            swapAmt = balShortB.mul(swapPercent).div(BASIS_PRECISION);
            _swapExactShortRebalance(address(shortB), address(shortA), swapAmt);
            _repayDebtA();
        } else {
            swapPercent = rebalancePercent;
            swapAmt = balShortA.mul(swapPercent).div(BASIS_PRECISION);
            _swapExactShortRebalance(address(shortA), address(shortB), swapAmt);
            _repayDebtB();
        }

        _deployFromLend(balanceLend());
        //emit DebtRebalance(debtRatioA, debtRatioB, swapPercent);
    }

    /**
     * Withdraws and removes `_deployedPercent` percentage if LP from farming and pool respectively
     *
     * @param _deployedPercent percentage multiplied by BASIS_PRECISION of LP to remove.
     */
    function _removeLpPercent(uint256 _deployedPercent) internal {
        uint256 lpPooled = countLpPooled();
        uint256 lpUnpooled = shortAshortBLP.balanceOf(address(this));
        uint256 lpCount = lpUnpooled.add(lpPooled);
        uint256 lpReq = lpCount.mul(_deployedPercent).div(BASIS_PRECISION);
        uint256 lpWithdraw;
        /*
        if (lpReq - lpUnpooled < lpPooled) {
            lpWithdraw = lpReq.sub(lpUnpooled);
        } else {
            lpWithdraw = lpPooled;
        }
        */
        lpWithdraw = lpReq.sub(lpUnpooled);

        // Finnally withdraw the LP from farms and remove from pool
        _withdrawSomeLp(lpWithdraw);
        _removeAllLp();
    }

    function _getTotalDebt() internal view returns (uint256) {
        return vault.strategies(address(this)).totalDebt;
    }

    function liquidatePosition(uint256 _amountNeeded)
        internal
        override
        returns (uint256 _liquidatedAmount, uint256 _loss)
    {
        // NOTE: Maintain invariant `want.balanceOf(this) >= _liquidatedAmount`
        // NOTE: Maintain invariant `_liquidatedAmount + _loss <= _amountNeeded`
        uint256 balanceWant = balanceOfWant();
        uint256 totalAssets = estimatedTotalAssets();

        // if estimatedTotalAssets is less than params.debtRatio it means there's
        // been a loss (ignores pending harvests). This type of loss is calculated
        // proportionally
        // This stops a run-on-the-bank if there's IL between harvests.
        uint256 totalDebt = _getTotalDebt();
        if (totalDebt > totalAssets) {
            uint256 ratio = totalAssets.mul(STD_PRECISION).div(totalDebt);
            uint256 newAmount = _amountNeeded.mul(ratio).div(STD_PRECISION);
            _loss = _amountNeeded.sub(newAmount);
        }

        (, _loss) = _withdraw(_amountNeeded);

        // Since we might free more than needed, let's send back the min
        _liquidatedAmount = Math.min(balanceOfWant(), _amountNeeded).sub(_loss);
    }

    /**
     * function to remove funds from strategy when users withdraws funds in excess of reserves
     *
     * withdraw takes the following steps:
     * 1. Removes _amountNeeded worth of LP from the farms and pool
     * 2. Uses the short removed to repay debt (Swaps short or base for large withdrawals)
     * 3. Redeems the
     * @param _amountNeeded `want` amount to liquidate
     */
    function _withdraw(uint256 _amountNeeded)
        internal
        returns (uint256 _liquidatedAmount, uint256 _loss)
    {
        uint256 balanceBefore = estimatedTotalAssets();
        uint256 balanceWant = balanceOfWant();
        if (_amountNeeded <= balanceWant) {
            return (0, 0);
        }

        uint256 balanceDeployed = balanceDeployed();

        // stratPercent: Percentage of the deployed capital we want to liquidate.
        uint256 stratPercent =
            _amountNeeded.sub(balanceWant).mul(BASIS_PRECISION).div(
                balanceDeployed
            );

        _removeLpPercent(stratPercent);
        _repayDebtA();
        _repayDebtB();
        _redeemWant(_amountNeeded);
        _loss = balanceBefore.sub(estimatedTotalAssets());
        _liquidatedAmount = balanceOfWant().sub(balanceWant);
    }

    function enterMarket() internal onlyAuthorized {
        address[] memory cTokens = new address[](1);
        cTokens[0] = address(cTokenLend);
        comptroller.enterMarkets(cTokens);
    }

    // function exitMarket() internal onlyAuthorized {
    //     comptroller.exitMarket(address(cTokenLend));
    // }

    /**
     * This method is often farm specific so it needs to be declared elsewhere.
     */
    function _farmPendingRewards(uint256 _pid, address _user)
        internal
        view
        virtual
        returns (uint256);

    // calculate total value of vault assets
    function estimatedTotalAssets() public view override returns (uint256) {
        return balanceOfWant().add(balanceDeployed());
    }

    // calculate total value of vault assets
    function balanceDeployed() public view returns (uint256) {
        return balanceLend().add(balanceLp()).sub(balanceDebtLP());
    }

    // debt ratio - used to trigger rebalancing of debt
    function calcDebtRatioA() public view returns (uint256) {
        return (
            balanceDebtInShortA().mul(BASIS_PRECISION).div(balanceShortAinLP())
        );
    }

    function calcDebtRatioB() public view returns (uint256) {
        return (
            balanceDebtInShortB().mul(BASIS_PRECISION).div(balanceShortBinLP())
        );
    }

    // calculate debt / collateral - used to trigger rebalancing of debt & collateral
    function calcCollateral() public view returns (uint256) {
        return (balanceDebt()).mul(BASIS_PRECISION).div(balanceLend());
    }

    function getLpReserves()
        public
        view
        returns (uint256 _shortAInLP, uint256 _shortBInLP)
    {
        (uint112 reserves0, uint112 reserves1, ) = shortAshortBLP.getReserves();
        if (shortAshortBLP.token0() == address(shortA)) {
            _shortAInLP = uint256(reserves0);
            _shortBInLP = uint256(reserves1);
        } else {
            _shortAInLP = uint256(reserves1);
            _shortBInLP = uint256(reserves0);
        }
    }

    function convertShortAToWantLP(uint256 _amountShort)
        internal
        view
        returns (uint256)
    {
        (uint256 wantInLp, uint256 shortInLp, ) = wantShortALP.getReserves();
        return (_amountShort.mul(wantInLp).div(shortInLp));
    }

    function convertShortBToWantLP(uint256 _amountShort)
        internal
        view
        returns (uint256)
    {
        convertShortAToWantLP(
            _amountShort.mul(shortA.balanceOf(address(shortAshortBLP))).div(
                shortB.balanceOf(address(shortAshortBLP))
            )
        );
    }

    function convertShortAToWantOracle(uint256 _amountShort)
        internal
        view
        returns (uint256)
    {
        return _amountShort.mul(oracleA.getPrice()).div(1e18);
    }

    function convertShortBToWantOracle(uint256 _amountShort)
        internal
        view
        returns (uint256)
    {
        return _amountShort.mul(oracleB.getPrice()).div(1e18);
    }

    /// get value of all LP in want currency
    function balanceLp() public view returns (uint256) {
        uint256 balA = convertShortAToWantLP(balanceShortAinLP());
        // as we are using UNI V2 can assume that short B will convert to want @ same value i.e. multiply by 2
        return (balA.mul(2));
    }

    function balanceLpOracle() public view returns (uint256) {
        uint256 balA = balanceShortAinLP().mul(oracleA.getPrice()).div(1e18);
        uint256 balB = balanceShortBinLP().mul(oracleB.getPrice()).div(1e18);
        return (balA.add(balB));
    }

    function balanceShortAinLP() public view returns (uint256) {
        (uint256 _shortAInLP, uint256 _shortBInLP) = getLpReserves();
        uint256 lpBalance =
            countLpPooled().add(shortAshortBLP.balanceOf(address(this)));
        return (_shortAInLP.mul(lpBalance).div(shortAshortBLP.totalSupply()));
    }

    function balanceShortBinLP() public view returns (uint256) {
        (uint256 _shortAInLP, uint256 _shortBInLP) = getLpReserves();
        uint256 lpBalance =
            countLpPooled().add(shortAshortBLP.balanceOf(address(this)));
        return (_shortBInLP.mul(lpBalance).div(shortAshortBLP.totalSupply()));
    }

    function balanceDebtLP() public view returns (uint256) {
        uint256 debtA = convertShortAToWantLP(balanceDebtInShortA());
        uint256 debtBInA =
            balanceDebtInShortB()
                .mul(shortA.balanceOf(address(shortAshortBLP)))
                .div(shortB.balanceOf(address(shortAshortBLP)));
        return (debtA.add(convertShortAToWantLP(debtBInA)));
    }

    function balanceDebt() public view returns (uint256) {
        return (
            convertShortAToWantOracle(balanceDebtInShortA()).add(
                convertShortBToWantOracle(balanceDebtInShortB())
            )
        );
    }

    // value of borrowed tokens in value of want tokens
    function balanceDebtInShortA() public view returns (uint256) {
        return cTokenBorrowA.borrowBalanceStored(address(this));
    }

    function balanceDebtInShortB() public view returns (uint256) {
        return cTokenBorrowB.borrowBalanceStored(address(this));
    }

    // value of borrowed tokens in value of want tokens
    // Uses current exchange price, not stored
    function balanceDebtInShortACurrent() public returns (uint256) {
        return cTokenBorrowA.borrowBalanceCurrent(address(this));
    }

    function balanceDebtInShortBCurrent() public returns (uint256) {
        return cTokenBorrowB.borrowBalanceCurrent(address(this));
    }

    // reserves
    function balanceOfWant() public view returns (uint256) {
        return (want.balanceOf(address(this)));
    }

    function balanceShortA() public view returns (uint256) {
        return (shortA.balanceOf(address(this)));
    }

    function balanceShortB() public view returns (uint256) {
        return (shortB.balanceOf(address(this)));
    }

    function balanceLend() public view returns (uint256) {
        return (
            cTokenLend
                .balanceOf(address(this))
                .mul(cTokenLend.exchangeRateStored())
                .div(1e18)
        );
    }

    function getWantInLending() internal view returns (uint256) {
        return want.balanceOf(address(cTokenLend));
    }

    function countLpPooled() public view virtual returns (uint256) {
        return farm.userInfo(farmPid, address(this)).amount;
    }

    // lend want tokens to lending platform
    function _lendWant(uint256 amount) internal {
        cTokenLend.mint(amount);
    }

    function _borrowA(uint256 borrowAmount) internal {
        cTokenBorrowA.borrow(borrowAmount);
    }

    function _borrowB(uint256 borrowAmount) internal {
        cTokenBorrowB.borrow(borrowAmount);
    }

    // automatically repays debt using any short tokens held in wallet up to total debt value
    function _repayDebtA() internal {
        uint256 _bal = shortA.balanceOf(address(this));
        if (_bal == 0) return;

        uint256 _debt = balanceDebtInShortA();
        if (_bal < _debt) {
            cTokenBorrowA.repayBorrow(_bal);
        } else {
            cTokenBorrowA.repayBorrow(_debt);
        }
    }

    function _repayDebtB() internal {
        uint256 _bal = shortB.balanceOf(address(this));
        if (_bal == 0) return;

        uint256 _debt = balanceDebtInShortB();
        if (_bal < _debt) {
            cTokenBorrowB.repayBorrow(_bal);
        } else {
            cTokenBorrowB.repayBorrow(_debt);
        }
    }

    function _getHarvestInHarvestLp() internal view returns (uint256) {
        uint256 harvest_lp = farmToken.balanceOf(address(farmTokenLP));
        return harvest_lp;
    }

    function _redeemWant(uint256 _redeem_amount) internal {
        cTokenLend.redeemUnderlying(_redeem_amount);
    }

    function _addToLP() internal {
        uint256 balShortA = shortA.balanceOf(address(this));
        uint256 balShortB = shortB.balanceOf(address(this));

        router.addLiquidity(
            address(shortA),
            address(shortB),
            balShortA,
            balShortB,
            balShortA.mul(slippageAdj).div(BASIS_PRECISION),
            balShortB.mul(slippageAdj).div(BASIS_PRECISION),
            address(this),
            now
        );
    }

    function _depoistLp() internal virtual {
        uint256 lpBalance = shortAshortBLP.balanceOf(address(this)); /// get number of LP tokens
        farm.deposit(farmPid, lpBalance); /// deposit LP tokens to farm
    }

    function _withdrawFarm(uint256 _amount) internal virtual {
        farm.withdraw(farmPid, _amount);
    }

    function _withdrawSomeLp(uint256 _amount) internal {
        require(_amount <= countLpPooled());
        _withdrawFarm(_amount);
    }

    function _withdrawAllPooled() internal {
        uint256 lpPooled = countLpPooled();
        _withdrawFarm(lpPooled);
    }

    // all LP currently not in Farm is removed.
    function _removeAllLp() internal {
        uint256 _amount = shortAshortBLP.balanceOf(address(this));
        /*
        (uint256 wantLP, uint256 shortLP) = getLpReserves();
        uint256 lpIssued = shortAshortBLP.totalSupply();

        uint256 amountAMin =
            _amount.mul(shortLP).mul(slippageAdj).div(BASIS_PRECISION).div(
                lpIssued
            );
        uint256 amountBMin =
            _amount.mul(wantLP).mul(slippageAdj).div(BASIS_PRECISION).div(
                lpIssued
            );
        */

        uint256 amountAMin = 0;
        uint256 amountBMin = 0;

        router.removeLiquidity(
            address(shortA),
            address(shortB),
            _amount,
            amountAMin,
            amountBMin,
            address(this),
            now
        );
    }

    function _sellHarvest(address _target) internal virtual {
        uint256 harvestBalance = farmToken.balanceOf(address(this));
        if (harvestBalance == 0) return;
        router.swapExactTokensForTokens(
            harvestBalance,
            0,
            getTokenOutPath(address(farmToken), address(_target)),
            address(this),
            now
        );
    }

    /**
     * Harvest comp token from the lending platform and swap for the want token
     */
    function _sellComp(address _target) internal virtual {
        uint256 compBalance = compToken.balanceOf(address(this));
        if (compBalance == 0) return;
        router.swapExactTokensForTokens(
            compBalance,
            0,
            getTokenOutPath(address(compToken), address(_target)),
            address(this),
            now
        );
    }

    function _swapExactShortRebalance(
        address _swapFrom,
        address _swapTo,
        uint256 _amountShort
    ) internal {
        uint256 minOut = 0;
        router.swapExactTokensForTokens(
            _amountShort,
            minOut,
            getTokenOutPath(address(_swapFrom), address(_swapTo)),
            address(this),
            now
        );
    }

    /*
    function _swapExactShortWant(uint256 _amountShort, address _short)
        internal
        returns (uint256 _amountWant, uint256 _slippageWant)
    {
        if (_short == address(shortA)){
            _amountWant = convertShortAToWantLP(_amountShort);
        } else {
            _amountWant = convertShortBToWantLP(_amountShort);
        }
        

        uint256[] memory amounts =
            router.swapExactTokensForTokens(
                _amountShort,
                _amountWant.mul(slippageAdj).div(BASIS_PRECISION),
                getTokenOutPath(_short, address(want)),
                address(this),
                now
            );
        _slippageWant = _amountWant.sub(amounts[amounts.length - 1]);
    }
    */

    function protectedTokens()
        internal
        view
        override
        returns (address[] memory)
    {
        // TODO - Fit this into the contract somehow
        address[] memory protected = new address[](6);
        protected[0] = address(shortA);
        protected[1] = address(shortAshortBLP);
        protected[2] = address(farmToken);
        protected[3] = address(compToken);
        protected[4] = address(cTokenLend);
        protected[5] = address(shortB);

        return protected;
    }
}
