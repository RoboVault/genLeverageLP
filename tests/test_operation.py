import brownie
from brownie import interface, Contract, accounts
import pytest

#CASE A = both debt ratios are less than 100%

def test_operation_case_A(
    chain, accounts, gov, token, vault, strategy, user, strategist, lp_token, Contract, amount, RELATIVE_APPROX, conf
):
    strategy.approveContracts({'from':gov})
    # Deposit to the vault
    user_balance_before = token.balanceOf(user)
    token.approve(vault.address, amount, {"from": user})
    vault.deposit(amount, {"from": user})
    assert token.balanceOf(vault.address) == amount
    
    # harvest
    chain.sleep(1)
    strategy.harvest()
    strat = strategy
    assert pytest.approx(strategy.estimatedTotalAssets(), rel=RELATIVE_APPROX) == amount

    tradingFeeWhale = '0xd061c6586670792331E14a80f3b3Bb267189C681'
    shortA = Contract(strategy.shortA())
    shortB = Contract(strategy.shortB())
    sendAmtA = shortA.balanceOf(lp_token)*0.002
    sendAmtB = shortB.balanceOf(lp_token)*0.002

    shortA.transfer(lp_token, sendAmtA, {'from': tradingFeeWhale})
    shortB.transfer(lp_token, sendAmtB, {'from': tradingFeeWhale})

    spookyRouter = Contract("0xF491e7B69E4244ad4002BC14e878a34207E38c29")

    shortA.approve(spookyRouter, 2**256-1, {"from": tradingFeeWhale})
    swapAmt = sendAmtA*0.01 
    # do tiny trade as this should make sure reserves are updated 
    spookyRouter.swapExactTokensForTokens(swapAmt, 0, [shortA, shortB], tradingFeeWhale, 2**256-1, {"from": tradingFeeWhale})

    chain.sleep(1)
    chain.mine(1)

    # check debt ratio
    debtRatioA = strategy.calcDebtRatioA()
    debtRatioB = strategy.calcDebtRatioB()

    collatRatio = strategy.calcCollateral()
    print('debtRatioA:   {0}'.format(debtRatioA))
    print('debtRatioB:   {0}'.format(debtRatioB))
    print('collatRatio: {0}'.format(collatRatio))
    #assert pytest.approx(10000, rel=1e-3) == debtRatioA
    #assert pytest.approx(10000, rel=1e-3) == debtRatioB
    assert pytest.approx(strategy.collatTarget(), rel=1e-2) == collatRatio

    # withdrawal
    tx = vault.withdraw(amount, {"from": user})
    assert (
        pytest.approx(token.balanceOf(user), rel=RELATIVE_APPROX) == user_balance_before
    )



def test_emergency_exit(
    chain, accounts, gov, token, vault, strategy, user, strategist, amount, RELATIVE_APPROX, conf
):
    strategy.approveContracts({'from':gov})
    # Deposit to the vault
    token.approve(vault.address, amount, {"from": user})
    vault.deposit(amount, {"from": user})
    chain.sleep(1)
    strategy.harvest()
    assert pytest.approx(strategy.estimatedTotalAssets(), rel=RELATIVE_APPROX) == amount

    # set emergency and exit
    strategy.setEmergencyExit()
    chain.sleep(1)
    strategy.harvest()
    assert strategy.estimatedTotalAssets() < 10 ** (token.decimals() - 3) # near zero
    assert pytest.approx(token.balanceOf(vault), rel=RELATIVE_APPROX) == amount


def test_change_debt(
    chain, gov, token, vault, strategy, user, strategist, amount, RELATIVE_APPROX, conf
):
    strategy.approveContracts({'from':gov})
    # Deposit to the vault and harvest
    token.approve(vault.address, amount, {"from": user})
    vault.deposit(amount, {"from": user})
    vault.updateStrategyDebtRatio(strategy.address, 50_00, {"from": gov})
    chain.sleep(1)
    strategy.harvest()
    half = int(amount / 2)
    assert pytest.approx(strategy.estimatedTotalAssets(), rel=RELATIVE_APPROX) == half

    vault.updateStrategyDebtRatio(strategy.address, 100_00, {"from": gov})
    chain.sleep(1)
    strategy.harvest()
    assert pytest.approx(strategy.estimatedTotalAssets(), rel=RELATIVE_APPROX) == amount

    vault.updateStrategyDebtRatio(strategy.address, 50_00, {"from": gov})
    chain.sleep(1)
    strategy.harvest()
    assert pytest.approx(strategy.estimatedTotalAssets(), rel=RELATIVE_APPROX) == half

    vault.updateStrategyDebtRatio(strategy.address, 0, {"from": gov})
    chain.sleep(1)
    strategy.harvest()
    assert strategy.estimatedTotalAssets() < 10 ** (token.decimals() - 3) # near zero

"""
def test_change_debt_lossy(
    chain, gov, token, vault, strategy, user, strategist, amount, RELATIVE_APPROX, conf
):
    strategy.approveContracts({'from':gov})
    # Deposit to the vault and harvest
    token.approve(vault.address, amount, {"from": user})
    vault.deposit(amount, {"from": user})

    vault.updateStrategyDebtRatio(strategy.address, 100_00, {"from": gov})
    chain.sleep(1)
    strategy.harvest()
    assert pytest.approx(strategy.estimatedTotalAssets(), rel=RELATIVE_APPROX) == amount

    # Steal from the strategy
    steal = round(strategy.estimatedTotalAssets() * 0.01)
    strategy.liquidatePositionAuth(steal, {'from': gov})
    token.transfer(user, strategy.balanceOfWant(), {"from": accounts.at(strategy, True)})
    vault.updateStrategyDebtRatio(strategy.address, 50_00, {"from": gov})
    chain.sleep(1)
    strategy.harvest()
    assert pytest.approx(strategy.estimatedTotalAssets(), rel=1e-2) == int(amount * 0.98 / 2) 

    vault.updateStrategyDebtRatio(strategy.address, 0, {"from": gov})
    chain.sleep(1)
    strategy.harvest()
    assert strategy.estimatedTotalAssets() < 10 ** (token.decimals() - 3) # near zero

def test_sweep(gov, vault, strategy, token, user, amount, conf):
    strategy.approveContracts({'from':gov})
    # Strategy want token doesn't work
    token.transfer(strategy, amount, {"from": user})
    assert token.address == strategy.want()
    assert token.balanceOf(strategy) > 0
    with brownie.reverts("!want"):
        strategy.sweep(token, {"from": gov})

    # Vault share token doesn't work
    with brownie.reverts("!shares"):
        strategy.sweep(vault.address, {"from": gov})

    # Protected token doesn't work
    with brownie.reverts("!protected"):
        strategy.sweep(strategy.short(), {"from": gov})
    # with brownie.reverts("!protected"):
    #     strategy.sweep(strategy.wantShortLP(), {"from": gov})
    with brownie.reverts("!protected"):
        strategy.sweep(conf['harvest_token'], {"from": gov})
"""

def test_triggers(
    chain, gov, vault, strategy, token, amount, user, conf
):
    strategy.approveContracts({'from':gov})
    # Deposit to the vault and harvest
    token.approve(vault.address, amount, {"from": user})
    vault.deposit(amount, {"from": user})
    vault.updateStrategyDebtRatio(strategy.address, 5_000, {"from": gov})
    chain.sleep(1)
    strategy.harvest()

    strategy.harvestTrigger(0)
    strategy.tendTrigger(0)


