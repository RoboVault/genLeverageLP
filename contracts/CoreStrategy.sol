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


import "./interfaces/ctoken.sol";
import "./interfaces/farm.sol";
import "./interfaces/uniswap.sol";
import "./interfaces/ipriceoracle.sol";

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
    uint256 public debtLower = 9900;
    uint256 public rebalancePercent = 10000; // 100% (how far does rebalance of debt move towards 100% from threshold)

    bool public doPriceCheck = true; 
    bool public forceHarvestTriggerOnce;

    // ERC20 Tokens;
    IERC20 public shortA;
    IERC20 public shortB;

    IUniswapV2Pair wantShortALP; // This is public because it helps with unit testing
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

    uint256 public slippageAdj = 9800; // 90%
    uint256 public priceSourceDiff = 1000; // 10% Default
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
        approveContracts();
    }

    // function _updateLendAndDebtAllocation() internal {
    //     stratLendAllocation = BASIS_PRECISION.mul(BASIS_PRECISION).div(
    //         BASIS_PRECISION.add(collatTarget)
    //     );
    //     stratDebtAllocation = BASIS_PRECISION.sub(stratLendAllocation);
    // }

    function name() external view override returns (string memory) {
        return "GeneralLPHedgedFarming";
    }

    function _testPriceSource() internal view returns (bool) {
        if (doPriceCheck){
            uint256 shortARatio = oracleA.getPrice().mul(BASIS_PRECISION).div(convertAtoB(address(shortA), address(want), 1e18));
            uint256 shortBRatio = oracleB.getPrice().mul(BASIS_PRECISION).div(convertAtoB(address(shortB), address(want), 1e18));
            bool shortAWithinRange = (shortARatio > BASIS_PRECISION.sub(priceSourceDiff) &&
                    shortARatio < BASIS_PRECISION.add(priceSourceDiff));
            bool shortBWithinRange = (shortBRatio > BASIS_PRECISION.sub(priceSourceDiff) &&
                    shortBRatio < BASIS_PRECISION.add(priceSourceDiff));

            return (shortAWithinRange && shortBWithinRange);
        }
        return true;
    }

    ///@notice This allows us to manually harvest with our keeper as needed
    function setForceHarvestTriggerOnce(bool _forceHarvestTriggerOnce) external onlyAuthorized {
        forceHarvestTriggerOnce = _forceHarvestTriggerOnce;
    }


    function harvestTrigger(uint256 callCostInWei) public view virtual override returns (bool) {
        StrategyParams memory params = vault.strategies(address(this));

        // trigger if we want to manually harvest
        if (forceHarvestTriggerOnce) {
            return true;
        }

        uint256 totalAssets = estimatedTotalAssets();
        uint256 totalDebt = _getTotalDebt();
        bool isInProfit = totalAssets > totalDebt;

        // harvest no matter what once we reach our maxDelay
        if (block.timestamp.sub(params.lastReport) > maxReportDelay) {
            return isInProfit;
        }

        // if neither of above are met we return false 
        return false;

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

        uint256 _slippage;
        uint256 totalAssets = estimatedTotalAssets();
        uint256 totalDebt = _getTotalDebt();

        if (totalAssets > totalDebt) {
            _profit = totalAssets.sub(totalDebt);
        } else {
            //_debtPayment = balanceOfWant();
            _loss = _loss.add(totalDebt.sub(totalAssets));
        }

        (, _slippage) = _withdraw(_debtOutstanding.add(_profit));
        _debtPayment = Math.min(balanceOfWant(), _debtOutstanding);
        if (_slippage > _profit) {
            _loss = _loss.add(_profit);
            _profit = 0;
        } else {
            _profit = _profit.sub(_slippage);
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

    function approveContracts() internal virtual {
        want.safeApprove(address(cTokenLend), uint256(-1));
        shortA.safeApprove(address(cTokenBorrowA), uint256(-1));
        shortB.safeApprove(address(cTokenBorrowB), uint256(-1));

        //want.safeApprove(address(router), uint256(-1));
        want.safeApprove(address(router), uint256(-1));
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

    function setSlippageConfig(uint256 _slippageAdj, uint256 _priceSourceDif, bool _doPriceCheck)
        external
        onlyAuthorized
    {
        slippageAdj = _slippageAdj;
        priceSourceDiff = _priceSourceDif;
        doPriceCheck = _doPriceCheck;
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
        uint256 _upper
    ) external onlyAuthorized {
        require(_upper <= BASIS_PRECISION);
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
        returns (uint256 _amountFreed, uint256 _slippage)
    {

        uint256 totalDebt = _getTotalDebt();
        _rebalanceDebtInternal();
        liquidateAllToLend();

        uint256 balShortA = balanceShortA();
        uint256 balShortB = balanceShortB();

        // not most efficient solution for slippage but should save on gas 
        // first redeem enough Want to repay debt (if no debt try to swap for Want)
        uint256 redeemAmount = balanceLend().div(3);
        _redeemWant(redeemAmount);

        uint256 debtInShortA = balanceDebtInShortACurrent();

        if (debtInShortA > 0) {
            _slippage.add(swapExactOutFromTo(address(want), address(shortA), debtInShortA));
            _repayDebtA();
        } else {
            _slippage.add(swapExactFromTo(address(shortA), address(want), balShortA));
        }

        uint256 debtInShortB = balanceDebtInShortBCurrent();

        if (debtInShortB > 0) {
            _slippage.add(swapExactOutFromTo(address(want), address(shortB), debtInShortB));
            _repayDebtB();
        } else {
            _slippage.add(swapExactFromTo(address(shortB), address(want), balShortB));
        }

        redeemAmount = balanceLend();
        // check balanceDebt -> due to rounding there may be tiny bit of debt remaining in one of the assets 
        // if this is the case leave some dust as collateral 
        if (balanceDebt() > 0) {
            redeemAmount = balanceLend().sub(balanceDebt().mul(BASIS_PRECISION).div(collatUpper));
        }

        _redeemWant(redeemAmount);
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
        require(_testPriceSource());
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
    function _harvestInternal() internal {

        uint256 debtA = calcDebtRatioA();
        uint256 debtB = calcDebtRatioB();
       
        // decide which token to sell rewards to
        address sellToken;
    
        if (debtA > debtB) {
            sellToken = address(shortA);
        } else {
            sellToken = address(shortB);
        }

        claimHarvest();
        //comptroller.claimComp(address(this));    
        //swapHarvestsTo(address(compToken), sellToken, compToken.balanceOf(address(this)));
        swapHarvestsTo(address(farmToken), sellToken, farmToken.balanceOf(address(this)));
        sellTradingFees();
        _repayDebtA();
        _repayDebtB();
        
    }

    // if debt ratio debtLower for both short A & short B convert some of the trading fees to want to get closer to hedged position
    function sellTradingFees() internal {
        uint256 debtA = calcDebtRatioA();
        uint256 debtB = calcDebtRatioB();

        if (debtA < debtLower && debtB < debtLower) {
            uint256 lpPercentRemove =
                BASIS_PRECISION.sub(Math.max(debtA, debtB));
            _removeLpPercent(lpPercentRemove);
            swapHarvestsTo(
                address(shortA),
                address(want),
                balanceShortA()
            );
            swapHarvestsTo(
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
        require(_testPriceSource());
        uint256 borrowAmtA =
            _amount
                .mul(collatTarget)
                .div(BASIS_PRECISION)
                .mul(1e18)
                .div(oracleA.getPrice())
                .div(2);
        uint256 borrowAmtB = convertAtoB(address(shortA), address(shortB), borrowAmtA);
        _lendWant(_amount);
        _borrowA(borrowAmtA);
        _borrowB(borrowAmtB);

        _addToLP();
        _depoistLp();

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
        uint256 borrowAmtB = convertAtoB(address(shortA), address(shortB), borrowAmtA);

        _borrowA(borrowAmtA);
        _borrowB(borrowAmtB);
        _addToLP();
        _depoistLp();
    }

    function _rebalanceDebtInternal() internal {
        // this will be the % of balance for either short A or short B swapped 
        uint256 swapAmt;
        uint256 lpRemovePercent;
        uint256 debtRatioA = calcDebtRatioA();
        uint256 debtRatioB = calcDebtRatioB();
        (uint256 _shortAInLP, uint256 _shortBInLP) = getLpReserves();


        /* 
        Technically it's possible for both debtratioA & debtratioB to > debtUpper 
        i.e. if borrow debt from borrowing exceeded trading fees + adjustments in debt ratio from IL 
        however to avoid this potential issue on harvests if both debt Ratios are > 100% convert farming rewards 
        to token with highest debt Ratio 
        */

        // note we add some noise to check there is big enough difference between the debt ratios (0.5%) as we also call this during liquidate Position All
        if (debtRatioA > debtRatioB.add(50)) {
            lpRemovePercent = (debtRatioA.sub(debtRatioB)).div(2);
            _removeLpPercent(lpRemovePercent);
            swapExactFromTo(address(shortB), address(shortA), balanceShortB());
            _repayDebtA();
        }

        if (debtRatioB > debtRatioA.add(50)) {
            lpRemovePercent = (debtRatioB.sub(debtRatioA)).div(2);
            _removeLpPercent(lpRemovePercent);
            swapExactFromTo(address(shortA), address(shortB), balanceShortA());
            _repayDebtB();
        }


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
        uint256 newAmount = _amountNeeded;
        uint256 totalDebt = _getTotalDebt();
        if (totalDebt > totalAssets) {
            uint256 ratio = totalAssets.mul(STD_PRECISION).div(totalDebt);
            newAmount = _amountNeeded.mul(ratio).div(STD_PRECISION);
            _loss = _amountNeeded.sub(newAmount);
        }

        // Liquidate the amount needed
        (, uint256 _slippage) = _withdraw(newAmount);
        _loss = _loss.add(_slippage);

        // NOTE: Maintain invariant `want.balanceOf(this) >= _liquidatedAmount`
        // NOTE: Maintain invariant `_liquidatedAmount + _loss <= _amountNeeded`
        _liquidatedAmount = balanceOfWant();
        if (_liquidatedAmount.add(_loss) > _amountNeeded) {
            _liquidatedAmount = _amountNeeded.sub(_loss);
        } else {
            _loss = _amountNeeded.sub(_liquidatedAmount);
        }

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
        returns (uint256 _liquidatedAmount, uint256 _slippage)
    {
        require(_testPriceSource());
        uint256 totalDebt = _getTotalDebt();
        uint256 balanceWant = balanceOfWant();

        if (_amountNeeded <= balanceWant) {
            return (0, 0);
        }

        uint256 balanceDeployed = balanceDeployed();
        uint256 debtRatioA = calcDebtRatioA();
        uint256 debtRatioB = calcDebtRatioB();

        // stratPercent: Percentage of the deployed capital we want to liquidate.
        uint256 stratPercent =
            _amountNeeded.sub(balanceWant).mul(BASIS_PRECISION).div(
                balanceDeployed
            );
        if (stratPercent > 9500) {
            (_liquidatedAmount, _slippage) = liquidateAllPositionsInternal();
            _liquidatedAmount = Math.min(_liquidatedAmount, _amountNeeded);
        } else {

            _removeLpPercent(stratPercent);
            uint256 swapAmt;

            // only do a swap if % being withdrawn is > 5% 
            if (stratPercent > 500) {
                if (debtRatioA > debtRatioB){
                    swapAmt = shortB.balanceOf(address(this)).mul(debtRatioA.sub(debtRatioB)).mul(stratPercent).div(BASIS_PRECISION).div(BASIS_PRECISION);
                    _slippage = swapExactFromTo(address(shortB), address(shortA), swapAmt);
                } else {
                    swapAmt = shortA.balanceOf(address(this)).mul(debtRatioB.sub(debtRatioA)).mul(stratPercent).div(BASIS_PRECISION).div(BASIS_PRECISION);
                    _slippage = swapExactFromTo(address(shortA), address(shortB), swapAmt);
                }
            }

            _repayDebtA();
            _repayDebtB();
            _redeemWant(_amountNeeded.sub(_slippage));
            _liquidatedAmount = _amountNeeded;

        }


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

    function calcDebtRatio() public view returns( uint256, uint256) {
        return(calcDebtRatioA(), calcDebtRatioB());
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

    function getLpReservesWantShort()
        public
        view
        returns (uint256 _wantInLP, uint256 _shortAinLP)
    {
        (uint112 reserves0, uint112 reserves1, ) = wantShortALP.getReserves();
        if (wantShortALP.token0() == address(want)) {
            _wantInLP = uint256(reserves0);
            _shortAinLP = uint256(reserves1);
        } else {
            _wantInLP = uint256(reserves1);
            _shortAinLP = uint256(reserves0);
        }
    }

    function convertAtoB(address _tokenA, address _tokenB, uint256 _amountIn) 
        internal
        view
        returns (uint256 _amountOut)
    {
        (uint256 _shortAInLP, uint256 _shortBInLP) = getLpReserves();
        (uint256 _wantInLP, uint256 _shortAinLPWant) = getLpReservesWantShort();

        if (_tokenA == address(want) || _tokenB == address(want)){
            if (_tokenB == address(shortA)){
                _amountOut = _amountIn.mul(_shortAinLPWant).div(_wantInLP);
            }
            if (_tokenA == address(shortA)) {
                _amountOut = _amountIn.mul(_wantInLP).div(_shortAinLPWant);
            }
            if (_tokenB == address(shortB)) {
                _amountOut = _amountIn.mul(_shortAinLPWant).div(_wantInLP).mul(_shortBInLP).div(_shortAInLP);
            }
            if (_tokenA == address(shortB)) {
                _amountOut = _amountIn.mul(_shortAInLP).div(_shortBInLP).mul(_wantInLP).div(_shortAinLPWant);
            }

        } else {
            if(_tokenA == address(shortA)) { 
                _amountOut = _amountIn.mul(_shortBInLP).div(_shortAInLP);
            } else {
                _amountOut = _amountIn.mul(_shortAInLP).div(_shortBInLP);
            }

        }
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
        uint256 balA = convertAtoB(address(shortA), address(want), balanceShortAinLP());
        // as we are using UNI V2 can assume that short B will convert to want @ same value i.e. multiply by 2
        return (balA.mul(2));
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
        uint256 debtA = convertAtoB(address(shortA), address(want), balanceDebtInShortA());
        uint256 debtB = convertAtoB(address(shortB), address(want), balanceDebtInShortB());
        return (debtA.add(debtB));
    }

    function balanceDebt() public view returns (uint256) {
        return (
            convertShortAToWantOracle(balanceDebtInShortA()).add(
                convertShortBToWantOracle(balanceDebtInShortB())
            )
        );
    }

    function balanceDebtInShortA() public view returns (uint256) {
        return cTokenBorrowA.borrowBalanceStored(address(this));
    }

    function balanceDebtInShortB() public view returns (uint256) {
        return cTokenBorrowB.borrowBalanceStored(address(this));
    }

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
        
        (uint256 aLP, uint256 bLP) = getLpReserves();
        uint256 lpIssued = shortAshortBLP.totalSupply();

        uint256 amountAMin =
            _amount.mul(aLP).mul(slippageAdj).div(BASIS_PRECISION).div(
                lpIssued
            );
        uint256 amountBMin =
            _amount.mul(bLP).mul(slippageAdj).div(BASIS_PRECISION).div(
                lpIssued
            );

        if (amountAMin == 0 || amountBMin == 0) return();
        
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

    function swapHarvestsTo(
        address _swapFrom,
        address _swapTo,
        uint256 _amountShort
    ) internal {
        IERC20 fromToken = IERC20(_swapFrom);
        uint256 fromBalance = fromToken.balanceOf(address(this));
        if (fromBalance == 0) return;

        uint256 minOut = 0;
        router.swapExactTokensForTokens(
            _amountShort,
            minOut,
            getTokenOutPath(address(_swapFrom), address(_swapTo)),
            address(this),
            now
        );
    }


    function swapExactFromTo(
        address _swapFrom,
        address _swapTo,
        uint256 _amountIn
    )   internal 
        returns (uint256 slippageWant)
    {
        IERC20 fromToken = IERC20(_swapFrom);
        uint256 fromBalance = fromToken.balanceOf(address(this));
        uint256 expectedAmountOut = convertAtoB(_swapFrom, _swapTo, _amountIn);
        // do this to avoid small swaps that will fail
        if (fromBalance < 1 || expectedAmountOut < 1) return (0);
        uint256 minOut = 0;
        uint256[] memory amounts =
            router.swapExactTokensForTokens(
                _amountIn,
                minOut,
                getTokenOutPath(address(_swapFrom), address(_swapTo)),
                address(this),
                now
            );
        uint256 _slippage = expectedAmountOut.sub(amounts[amounts.length - 1]);
        if (_swapTo == address(want)){
            slippageWant = _slippage;
        } else {
            slippageWant = convertAtoB(_swapTo, address(want), _slippage);
        }
        
    }

    function swapExactOutFromTo(
        address _swapFrom,
        address _swapTo,
        uint256 _amountOut
    )   internal 
        returns (uint256 slippageWant)
    {
        IERC20 fromToken = IERC20(_swapFrom);
        uint256 fromBalance = fromToken.balanceOf(address(this));
        if (fromBalance == 0) return (0);
        uint256 expectedAmountIn = convertAtoB(_swapTo, _swapFrom, _amountOut);

        uint256 maxIn = fromBalance;
        uint256[] memory amounts =
            router.swapTokensForExactTokens(
                _amountOut,
                maxIn,
                getTokenOutPath(address(_swapFrom), address(_swapTo)),
                address(this),
                now
            );
        uint256 _slippage = amounts[0].sub(expectedAmountIn);
        if (_swapFrom == address(want)){
            slippageWant = _slippage;
        } else {
            slippageWant = convertAtoB(_swapFrom, address(want), _slippage);
        }


    }

    function protectedTokens()
        internal
        view
        override
        returns (address[] memory)
    {
        // TODO - Fit this into the contract somehow
        address[] memory protected = new address[](0);
        /*
        protected[0] = address(shortA);
        protected[1] = address(shortAshortBLP);
        protected[2] = address(farmToken);
        protected[3] = address(compToken);
        protected[4] = address(cTokenLend);
        protected[5] = address(shortB);
        */
        return protected;
    }
}
