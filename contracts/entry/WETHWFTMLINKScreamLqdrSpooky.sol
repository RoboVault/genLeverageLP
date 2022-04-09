// SPDX-License-Identifier: MIT
pragma solidity ^0.6.12;
pragma experimental ABIEncoderV2;

import "../CoreStrategy.sol";
import "../interfaces/lqdrfarm.sol";
import "../screampriceoracle.sol";

contract WETHWFTMLINKScreamLqdrSpooky is CoreStrategy {
    constructor(address _vault)
        public
        CoreStrategy(
            _vault,
            CoreStrategyConfig(
                0x74b23882a30290451A17c44f4F05243b6b58C76d, // want
                0x21be370D5312f44cB42ce377BC9b8a0cEF1A4C83, // shortA = WFTM
                0xb3654dc3D10Ea7645f8319668E8F54d2574FBdC8, // LINK
                0xf0702249F4D3A25cD3DED7859a165693685Ab577, // wantShortLP
                0x89d9bC2F2d091CfBFc31e333D6Dc555dDBc2fd29, // shortAshortBLP
                0x10b620b2dbAC4Faa7D7FFD71Da486f5D44cd86f9, // farmToken
                0x4Fe6f19031239F105F753D1DF8A0d24857D0cAA2, // farmTokenLp
                0x6e2ad6527901c9664f016466b8DA1357a004db0f, // farmMasterChef
                14, // farmPid
                0xC772BA6C2c28859B7a0542FAa162a56115dDCE25, // cTokenLend
                0x5AA53f03197E08C4851CAD8C92c7922DA5857E5d, // cTokenBorrowA
                0x2359012ebE36cCa231203D78b914284947B58aa3, // cTokenBorrowB
                0xe0654C8e6fd4D733349ac7E09f6f23DA256bF475, // compToken
                0x30872e4fc4edbFD7a352bFC2463eb4fAe9C09086, // compTokenLP
                0x260E596DAbE3AFc463e75B6CC05d8c46aCAcFB09, // comptroller
                0xF491e7B69E4244ad4002BC14e878a34207E38c29, // router
                1e4
            )
        )
    {
        // create a default oracle and set it
        oracleA = new ScreamPriceOracle(
            address(comptroller),
            address(cTokenLend),
            address(cTokenBorrowA)
        );

        // create a default oracle and set it
        oracleB = new ScreamPriceOracle(
            address(comptroller),
            address(cTokenLend),
            address(cTokenBorrowB)
        );
    }

    function _farmPendingRewards(uint256 _pid, address _user)
        internal
        view
        override
        returns (uint256)
    {
        return LqdrFarm(address(farm)).pendingLqdr(_pid, _user);
    }

    function _depoistLp() internal override {
        uint256 lpBalance = shortAshortBLP.balanceOf(address(this));
        LqdrFarm(address(farm)).deposit(farmPid, lpBalance, address(this));
    }

    function _withdrawFarm(uint256 _amount) internal override {
        LqdrFarm(address(farm)).withdraw(farmPid, _amount, address(this));
    }

    function claimHarvest() internal override {
        LqdrFarm(address(farm)).harvest(farmPid, address(this));
    }


    /*
    function collateralCapReached(uint256 _amount)
        public
        view
        override
        returns (bool _capReached)
    {
        _capReached = false;
    }
    */
}
