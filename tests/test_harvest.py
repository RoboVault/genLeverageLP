
import pytest
from brownie import Contract, interface, accounts
import time 


def test_profitable_harvest(
    chain, accounts, gov, token, vault, strategy, user, strategist, amount, RELATIVE_APPROX, conf
):
    strategy.approveContracts({'from':gov})
    # Deposit to the vault
    token.approve(vault.address, amount, {"from": user})
    vault.deposit(amount, {"from": user})
    assert token.balanceOf(vault.address) == amount

    # Harvest 1: Send funds through the strategy
    chain.sleep(1)
    strategy.harvest()
    assert pytest.approx(strategy.estimatedTotalAssets(), rel=RELATIVE_APPROX) == amount
    before_pps = vault.pricePerShare()

    harvest = interface.ERC20(conf['harvest_token'])
    harvestWhale = accounts.at(conf['harvest_token_whale'], True)
    sendAmount = round((vault.totalAssets() / conf['harvest_token_price']) * 0.0125)


    for i in range(2):

        print('Harvest Number :  {0}'.format(i))
        # Use a whale of the harvest token to send
        #print('Send amount: {0}'.format(sendAmount))
        #print('harvestWhale balance: {0}'.format(harvest.balanceOf(harvestWhale)))
        harvest.transfer(strategy, sendAmount, {'from': harvestWhale})


        # Harvest 2: Realize profit
        chain.sleep(5)
        chain.mine(5)
        #give the RPC a breather pre harvest as spazzes out sometimes 
        #time.sleep(5)
        strategy.harvest({'from': gov})
        chain.sleep(3600 * 6)  # 6 hrs needed for profits to unlock
        chain.mine(1)
        profit = token.balanceOf(vault.address)  # Profits go to vault

        print('Price per Share :  {0}'.format(vault.pricePerShare()))
        print('Estimated Assets :  {0}'.format(strategy.estimatedTotalAssets()))

    assert strategy.estimatedTotalAssets() + profit > amount
    assert vault.pricePerShare() > before_pps


def test_profitable_harvest_trading_fees(
    chain, accounts, gov, token, vault, strategy, user, strategist, lp_token ,amount, RELATIVE_APPROX, Contract, conf
):
    strategy.approveContracts({'from':gov})
    # Deposit to the vault
    token.approve(vault.address, amount, {"from": user})
    vault.deposit(amount, {"from": user})
    assert token.balanceOf(vault.address) == amount

    # Harvest 1: Send funds through the strategy
    chain.sleep(1)
    strategy.harvest()
    assert pytest.approx(strategy.estimatedTotalAssets(), rel=RELATIVE_APPROX) == amount
    before_pps = vault.pricePerShare()

    # Use a whale of the shortA & shortB (other LP) token to send & simulate high trading fees being accrued
    print("Simulate accooomulation of trading fees within LP")

    tradingFeeWhale = '0xd061c6586670792331E14a80f3b3Bb267189C681'


    shortA = Contract(strategy.shortA())
    shortB = Contract(strategy.shortB())
    sendAmtA = shortA.balanceOf(lp_token)*0.025
    sendAmtB = shortB.balanceOf(lp_token)*0.025

    for i in range(2):

        shortA.transfer(lp_token, sendAmtA, {'from': tradingFeeWhale})
        shortB.transfer(lp_token, sendAmtB, {'from': tradingFeeWhale})

        spookyRouter = Contract("0xF491e7B69E4244ad4002BC14e878a34207E38c29")

        shortA.approve(spookyRouter, 2**256-1, {"from": tradingFeeWhale})
        swapAmt = sendAmtA*0.01 
        # do tiny trade as this should make sure reserves are updated 
        spookyRouter.swapExactTokensForTokens(swapAmt, 0, [shortA, shortB], tradingFeeWhale, 2**256-1, {"from": tradingFeeWhale})


        # Harvest 2: Realize profit
        chain.sleep(1)
        chain.mine(1)

        print('Pre Harvest')
        print('debt Ratio A :  {0}'.format(strategy.calcDebtRatioA()))
        print('debt Ratio B :  {0}'.format(strategy.calcDebtRatioB()))
        print('CollatRatio: {0}'.format(strategy.calcCollateral()))

        print("-----")
        print('Price per Share :  {0}'.format(vault.pricePerShare()))
        print('Estimated Assets :  {0}'.format(strategy.estimatedTotalAssets()))

        print("Sell Trading Fees & Complete Harvest")
        #strategy.sellTradingFees()
        strategy.harvest()
        
        chain.sleep(3600 * 6)  # 6 hrs needed for profits to unlock
        chain.mine(1)
        profit = token.balanceOf(vault.address)  # Profits go to vault

        print('After Harvest')
        print('debt Ratio A :  {0}'.format(strategy.calcDebtRatioA()))
        print('debt Ratio B :  {0}'.format(strategy.calcDebtRatioB()))
        print('CollatRatio: {0}'.format(strategy.calcCollateral()))
        print('Price per Share :  {0}'.format(vault.pricePerShare()))
        print('Estimated Assets :  {0}'.format(strategy.estimatedTotalAssets()))


    assert strategy.estimatedTotalAssets() + profit > amount
    assert vault.pricePerShare() > before_pps

